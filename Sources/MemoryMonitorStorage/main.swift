import Darwin
import Foundation
import MemoryMonitorCore

private enum StorageCommandError: Error, CustomStringConvertible {
    case usage(String)
    case invalidPath(String)
    case outputExists(String)
    case outputInsideRoot(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        case .invalidPath(let message):
            return message
        case .outputExists(let path):
            return "Refusing to overwrite existing report: \(path)"
        case .outputInsideRoot(let path):
            return "Report must be outside the inspected storage root: \(path)"
        case .writeFailed(let message):
            return "Could not write inspection report: \(message)"
        }
    }
}

private struct StorageOptions {
    let root: URL
    let output: URL
}

private struct BackupOptions {
    let root: URL
    let output: URL
    let appBundle: URL?
}

private let usage = """
Usage:
  memory-monitor-storage inspect --root <absolute-storage-directory> --output <absolute-report.json>
  memory-monitor-storage backup  --root <absolute-storage-directory> --output <new-absolute-directory> [--app-bundle <app>]

The inspect command is read-only. The backup command requires the application
to be stopped, takes the exclusive maintenance lock, and never overwrites an
existing output directory.
"""

private func parseOptions(_ arguments: [String]) throws -> StorageOptions {
    guard arguments.first == "inspect" else {
        throw StorageCommandError.usage(usage)
    }
    var rootPath: String?
    var outputPath: String?
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--root", "--output":
            guard index + 1 < arguments.count else {
                throw StorageCommandError.usage("Missing value for \(argument)")
            }
            let value = arguments[index + 1]
            if argument == "--root" {
                guard rootPath == nil else {
                    throw StorageCommandError.usage("--root may be specified only once")
                }
                rootPath = value
            } else {
                guard outputPath == nil else {
                    throw StorageCommandError.usage("--output may be specified only once")
                }
                outputPath = value
            }
            index += 2
        case "--help", "-h":
            throw StorageCommandError.usage(usage)
        default:
            throw StorageCommandError.usage("Unknown argument: \(argument)\n\n\(usage)")
        }
    }
    guard let rootPath, let outputPath,
          !rootPath.isEmpty, !outputPath.isEmpty else {
        throw StorageCommandError.usage(usage)
    }
    guard rootPath.hasPrefix("/"), outputPath.hasPrefix("/") else {
        throw StorageCommandError.invalidPath("Both paths must be absolute")
    }

    let inputRoot = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
    var rootInfo = stat()
    guard lstat(inputRoot.path, &rootInfo) == 0,
          (rootInfo.st_mode & S_IFMT) == S_IFDIR,
          (rootInfo.st_mode & S_IFMT) != S_IFLNK else {
        throw StorageCommandError.invalidPath("Storage root is not a real directory: \(inputRoot.path)")
    }
    let root = URL(
        fileURLWithPath: canonicalPath(inputRoot.path) ?? inputRoot.path,
        isDirectory: true
    )

    let inputOutput = URL(fileURLWithPath: outputPath).standardizedFileURL
    let inputParent = inputOutput.deletingLastPathComponent()
    var parentInfo = stat()
    guard lstat(inputParent.path, &parentInfo) == 0,
          (parentInfo.st_mode & S_IFMT) == S_IFDIR,
          (parentInfo.st_mode & S_IFMT) != S_IFLNK else {
        throw StorageCommandError.invalidPath("Report parent is missing or is a symlink: \(inputParent.path)")
    }
    // Resolve every ancestor symlink before checking containment. A textual
    // prefix check would allow a path alias to place the report inside the
    // inspected root.
    let parent = URL(
        fileURLWithPath: canonicalPath(inputParent.path) ?? inputParent.path,
        isDirectory: true
    )
    let output = parent.appendingPathComponent(inputOutput.lastPathComponent)
    var outputInfo = stat()
    if lstat(output.path, &outputInfo) == 0 {
        throw StorageCommandError.outputExists(output.path)
    }
    guard !isContained(output.path, in: root.path) else {
        throw StorageCommandError.outputInsideRoot(output.path)
    }
    return StorageOptions(root: root, output: output)
}

private func parseBackupOptions(_ arguments: [String]) throws -> BackupOptions {
    guard arguments.first == "backup" else {
        throw StorageCommandError.usage(usage)
    }
    var rootPath: String?
    var outputPath: String?
    var appBundlePath: String?
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--root", "--output", "--app-bundle":
            guard index + 1 < arguments.count else {
                throw StorageCommandError.usage("Missing value for \(argument)")
            }
            let value = arguments[index + 1]
            switch argument {
            case "--root":
                guard rootPath == nil else {
                    throw StorageCommandError.usage("--root may be specified only once")
                }
                rootPath = value
            case "--output":
                guard outputPath == nil else {
                    throw StorageCommandError.usage("--output may be specified only once")
                }
                outputPath = value
            default:
                guard appBundlePath == nil else {
                    throw StorageCommandError.usage("--app-bundle may be specified only once")
                }
                appBundlePath = value
            }
            index += 2
        case "--help", "-h":
            throw StorageCommandError.usage(usage)
        default:
            throw StorageCommandError.usage("Unknown argument: \(argument)\n\n\(usage)")
        }
    }
    guard let rootPath, let outputPath,
          !rootPath.isEmpty, !outputPath.isEmpty else {
        throw StorageCommandError.usage(usage)
    }
    guard rootPath.hasPrefix("/"), outputPath.hasPrefix("/") else {
        throw StorageCommandError.invalidPath("Both paths must be absolute")
    }
    if let appBundlePath, !appBundlePath.hasPrefix("/") {
        throw StorageCommandError.invalidPath("--app-bundle must be absolute")
    }

    let inputRoot = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
    var rootInfo = stat()
    guard lstat(inputRoot.path, &rootInfo) == 0,
          (rootInfo.st_mode & S_IFMT) == S_IFDIR,
          (rootInfo.st_mode & S_IFMT) != S_IFLNK else {
        throw StorageCommandError.invalidPath("Storage root is not a real directory: \(inputRoot.path)")
    }
    let root = URL(
        fileURLWithPath: canonicalPath(inputRoot.path) ?? inputRoot.path,
        isDirectory: true
    )

    let inputOutput = URL(fileURLWithPath: outputPath).standardizedFileURL
    let inputParent = inputOutput.deletingLastPathComponent()
    var parentInfo = stat()
    guard lstat(inputParent.path, &parentInfo) == 0,
          (parentInfo.st_mode & S_IFMT) == S_IFDIR,
          (parentInfo.st_mode & S_IFMT) != S_IFLNK else {
        throw StorageCommandError.invalidPath("Backup parent is missing or is a symlink: \(inputParent.path)")
    }
    let parent = URL(
        fileURLWithPath: canonicalPath(inputParent.path) ?? inputParent.path,
        isDirectory: true
    )
    let output = parent.appendingPathComponent(inputOutput.lastPathComponent)
    var outputInfo = stat()
    if lstat(output.path, &outputInfo) == 0 {
        throw StorageCommandError.outputExists(output.path)
    }
    guard !isContained(output.path, in: root.path) else {
        throw StorageCommandError.outputInsideRoot(output.path)
    }

    let appBundle: URL?
    if let appBundlePath {
        let bundle = URL(
            fileURLWithPath: canonicalPath(appBundlePath) ?? appBundlePath,
            isDirectory: true
        ).standardizedFileURL
        var bundleInfo = stat()
        guard lstat(bundle.path, &bundleInfo) == 0,
              (bundleInfo.st_mode & S_IFMT) == S_IFDIR,
              (bundleInfo.st_mode & S_IFMT) != S_IFLNK else {
            throw StorageCommandError.invalidPath("Application bundle is not a real directory: \(bundle.path)")
        }
        appBundle = bundle
    } else {
        appBundle = nil
    }
    return BackupOptions(root: root, output: output, appBundle: appBundle)
}

private func canonicalPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func isContained(_ path: String, in root: String) -> Bool {
    let rootComponents = URL(fileURLWithPath: root).pathComponents
    let pathComponents = URL(fileURLWithPath: path).pathComponents
    guard pathComponents.count >= rootComponents.count else { return false }
    return zip(rootComponents, pathComponents).allSatisfy { $0 == $1 }
}

private func writeReport(_ report: HistoryInspectionReport, to output: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    do {
        try data.write(to: output, options: [.withoutOverwriting])
    } catch {
        throw StorageCommandError.writeFailed(error.localizedDescription)
    }
    do {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: output.path
        )
    } catch {
        try? FileManager.default.removeItem(at: output)
        throw StorageCommandError.writeFailed(error.localizedDescription)
    }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    switch arguments.first {
    case "inspect":
        let options = try parseOptions(arguments)
        let report = HistoryInspector.inspect(root: options.root)
        try writeReport(report, to: options.output)
        print("History inspection: \(report.status.rawValue)")
        print("Format: \(report.format.rawValue)")
        print("Records: \(report.recordCount) (+ journal \(report.journalRecordCount))")
        print("Segments: \(report.segmentCount); bytes: \(report.totalBytes)")
        print("Report: \(options.output.path)")
        let acceptable: [HistoryInspectionStatus] = [.healthy, .legacy, .empty]
        exit(acceptable.contains(report.status) ? 0 : 1)
    case "backup":
        let options = try parseBackupOptions(arguments)
        let manifest = try StorageBackup.create(
            root: options.root,
            output: options.output,
            appBundle: options.appBundle
        )
        print("Backup created: \(options.output.path)")
        print("Restorable: \(manifest.restorable ? "yes" : "no")")
        print("History status: \(manifest.historyStatus.rawValue)")
        print("Files: \(manifest.files.filter(\.present).count) present, \(manifest.files.filter { !$0.present }.count) missing")
        exit(0)
    default:
        throw StorageCommandError.usage(usage)
    }
} catch let error as StorageCommandError {
    fputs("memory-monitor-storage: \(error)\n", stderr)
    exit(error.description == usage ? 0 : 2)
} catch let error as StorageBackupError {
    fputs("memory-monitor-storage: \(error)\n", stderr)
    exit(2)
} catch {
    fputs("memory-monitor-storage: \(error.localizedDescription)\n", stderr)
    exit(2)
}
