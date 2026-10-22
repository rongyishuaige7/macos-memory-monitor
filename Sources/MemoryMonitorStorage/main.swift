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

private let usage = """
Usage:
  memory-monitor-storage inspect --root <absolute-storage-directory> --output <absolute-report.json>

The inspect command is read-only. It does not create locks, repair journals,
prune history, or call the production HistoryStore load/flush paths.
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
    let root = inputRoot.resolvingSymlinksInPath().standardizedFileURL

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
    let parent = inputParent.resolvingSymlinksInPath().standardizedFileURL
    let output = parent.appendingPathComponent(inputOutput.lastPathComponent).standardizedFileURL
    var outputInfo = stat()
    if lstat(output.path, &outputInfo) == 0 {
        throw StorageCommandError.outputExists(output.path)
    }
    guard !isContained(output.path, in: root.path) else {
        throw StorageCommandError.outputInsideRoot(output.path)
    }
    return StorageOptions(root: root, output: output)
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
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    let report = HistoryInspector.inspect(root: options.root)
    try writeReport(report, to: options.output)
    print("History inspection: \(report.status.rawValue)")
    print("Format: \(report.format.rawValue)")
    print("Records: \(report.recordCount) (+ journal \(report.journalRecordCount))")
    print("Segments: \(report.segmentCount); bytes: \(report.totalBytes)")
    print("Report: \(options.output.path)")
    let acceptable: [HistoryInspectionStatus] = [.healthy, .legacy, .empty]
    exit(acceptable.contains(report.status) ? 0 : 1)
} catch let error as StorageCommandError {
    fputs("memory-monitor-storage: \(error)\n", stderr)
    exit(error.description == usage ? 0 : 2)
} catch {
    fputs("memory-monitor-storage: \(error.localizedDescription)\n", stderr)
    exit(2)
}
