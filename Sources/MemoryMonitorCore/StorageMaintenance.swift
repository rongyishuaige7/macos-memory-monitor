import CryptoKit
import Darwin
import Foundation

public enum StorageBackupError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case invalidPath(String)
    case outputExists(String)
    case outputInsideRoot(String)
    case permissionDenied
    case unsupportedData
    case readFailed
    case writeFailed
    case lockTimedOut

    public var description: String {
        switch self {
        case .invalidPath(let message): return message
        case .outputExists(let path): return "备份目录已存在：\(path)"
        case .outputInsideRoot(let path): return "备份目录不能位于数据根内：\(path)"
        case .permissionDenied: return "没有权限读取或写入备份数据"
        case .unsupportedData: return "数据集合不支持安全备份"
        case .readFailed: return "无法读取源数据"
        case .writeFailed: return "无法写入备份"
        case .lockTimedOut: return "等待维护锁超时，应用可能仍在运行"
        }
    }
}

public struct StorageBackupFile: Codable, Sendable, Equatable {
    public let relativePath: String
    public let role: String
    public let present: Bool
    public let byteCount: Int
    public let sha256: String?
    public let mode: Int?

    public init(
        relativePath: String,
        role: String,
        present: Bool,
        byteCount: Int = 0,
        sha256: String? = nil,
        mode: Int? = nil
    ) {
        self.relativePath = relativePath
        self.role = role
        self.present = present
        self.byteCount = max(byteCount, 0)
        self.sha256 = sha256
        self.mode = mode
    }
}

public struct StorageBackupManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let createdAt: Date
    public let restorable: Bool
    public let historyStatus: HistoryInspectionStatus
    public let format: HistoryStorageFormat
    public let files: [StorageBackupFile]
    public let buildProvenance: BuildProvenance?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        createdAt: Date,
        restorable: Bool,
        historyStatus: HistoryInspectionStatus,
        format: HistoryStorageFormat,
        files: [StorageBackupFile],
        buildProvenance: BuildProvenance?
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.restorable = restorable
        self.historyStatus = historyStatus
        self.format = format
        self.files = files
        self.buildProvenance = buildProvenance
    }
}

/// Creates an immutable offline backup. The caller must not be running the
/// application. A dedicated maintenance lock excludes production stores, and
/// the backup directory is created only after all path checks pass.
public enum StorageBackup {
    public static let dataDirectoryName = "data"
    public static let manifestFileName = "backup.json"

    private static let knownFiles: [(path: String, role: String)] = [
        ("history.json", "historyIndex"),
        ("history.json.journal", "historyJournal"),
        ("history.json.clock", "historyClock"),
        ("actions.jsonl", "audit"),
        ("actions.jsonl.clock", "auditClock")
    ]

    public static func create(
        root: URL,
        output: URL,
        appBundle: URL? = nil,
        now: Date = Date()
    ) throws -> StorageBackupManifest {
        let sourceRoot = URL(
            fileURLWithPath: canonicalPath(root.path) ?? root.standardizedFileURL.path,
            isDirectory: true
        )
        let sourceInfo = try directoryInfo(sourceRoot.path)
        guard sourceInfo.isDirectory, !sourceInfo.isSymlink else {
            throw StorageBackupError.invalidPath("数据根必须是真实目录")
        }
        try validateOutput(output, outside: sourceRoot)
        let provenance: BuildProvenance?
        if let appBundle {
            guard let loaded = BuildProvenance.load(from: appBundle) else {
                throw StorageBackupError.invalidPath("无法读取应用构建来源")
            }
            provenance = loaded
        } else {
            provenance = nil
        }

        let maintenance: Int32
        do {
            maintenance = try MaintenanceLock.acquire(
                root: sourceRoot,
                mode: .exclusive,
                timeoutSeconds: 2
            )
        } catch MaintenanceLockError.timedOut {
            throw StorageBackupError.lockTimedOut
        } catch {
            throw StorageBackupError.writeFailed
        }
        defer { MaintenanceLock.release(maintenance) }

        let inspection = HistoryInspector.inspect(root: sourceRoot)
        let restorable: Bool
        switch inspection.status {
        case .healthy, .legacy, .empty:
            restorable = true
        default:
            restorable = false
        }

        let fileManager = FileManager.default
        let outputExisted = fileManager.fileExists(atPath: output.path)
        guard !outputExisted else {
            throw StorageBackupError.outputExists(output.path)
        }
        do {
            try fileManager.createDirectory(
                at: output,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StorageBackupError.writeFailed
        }
        var completed = false
        defer {
            if !completed {
                try? fileManager.removeItem(at: output)
            }
        }

        let dataDirectory = output.appendingPathComponent(dataDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw StorageBackupError.writeFailed
        }

        var files: [StorageBackupFile] = []
        for known in knownFiles {
            let source = sourceRoot.appendingPathComponent(known.path)
            if let info = try? fileInfo(source.path), !info.isSymlink, info.isRegular {
                let destination = dataDirectory.appendingPathComponent(known.path)
                let result = try copyRegularFile(from: source, to: destination)
                files.append(StorageBackupFile(
                    relativePath: known.path,
                    role: known.role,
                    present: true,
                    byteCount: result.byteCount,
                    sha256: result.sha256,
                    mode: result.mode
                ))
            } else {
                files.append(StorageBackupFile(
                    relativePath: known.path,
                    role: known.role,
                    present: false
                ))
            }
        }

        let segmentsSource = sourceRoot.appendingPathComponent("history.json.segments", isDirectory: true)
        var segmentsInfo: FileInfo?
        if let info = try? fileInfo(segmentsSource.path) {
            segmentsInfo = info
        }
        if let segmentsInfo, segmentsInfo.isSymlink || !segmentsInfo.isDirectory {
            throw StorageBackupError.invalidPath("历史分段目录必须是真实目录")
        }
        if segmentsInfo != nil {
            let segmentFiles = try listRegularFiles(in: segmentsSource)
            for segment in segmentFiles {
                let relative = "history.json.segments/" + segment.lastPathComponent
                let destination = dataDirectory.appendingPathComponent(relative)
                let result = try copyRegularFile(from: segment, to: destination)
                files.append(StorageBackupFile(
                    relativePath: relative,
                    role: "historySegment",
                    present: true,
                    byteCount: result.byteCount,
                    sha256: result.sha256,
                    mode: result.mode
                ))
            }
        } else {
            files.append(StorageBackupFile(
                relativePath: "history.json.segments",
                role: "historySegmentsDirectory",
                present: false
            ))
        }

        let manifest = StorageBackupManifest(
            createdAt: now,
            restorable: restorable,
            historyStatus: inspection.status,
            format: inspection.format,
            files: files.sorted { $0.relativePath < $1.relativePath },
            buildProvenance: provenance
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let manifestData = try encoder.encode(manifest)
            let manifestURL = output.appendingPathComponent(manifestFileName)
            try manifestData.write(to: manifestURL, options: [.withoutOverwriting])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: manifestURL.path
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: dataDirectory.path
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: output.path
            )
        } catch {
            throw StorageBackupError.writeFailed
        }
        completed = true
        return manifest
    }

    private struct FileInfo {
        let isSymlink: Bool
        let isRegular: Bool
        let isDirectory: Bool
    }

    private struct CopyResult {
        let byteCount: Int
        let sha256: String
        let mode: Int
    }

    private static func fileInfo(_ path: String) throws -> FileInfo {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw StorageBackupError.readFailed
        }
        let type = info.st_mode & S_IFMT
        return FileInfo(
            isSymlink: type == S_IFLNK,
            isRegular: type == S_IFREG,
            isDirectory: type == S_IFDIR
        )
    }

    private static func directoryInfo(_ path: String) throws -> FileInfo {
        try fileInfo(path)
    }

    private static func validateOutput(_ output: URL, outside root: URL) throws {
        let outputURL = URL(fileURLWithPath: output.path)
        guard outputURL.path.hasPrefix("/") else {
            throw StorageBackupError.invalidPath("备份目录必须是绝对路径")
        }
        let parent = outputURL.deletingLastPathComponent()
        let parentInfo = try fileInfo(parent.path)
        guard parentInfo.isDirectory, !parentInfo.isSymlink else {
            throw StorageBackupError.invalidPath("备份父目录必须是真实目录")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            throw StorageBackupError.outputExists(outputURL.path)
        }
        let realParentPath = canonicalPath(parent.path) ?? parent.path
        let realOutputPath = URL(fileURLWithPath: realParentPath, isDirectory: true)
            .appendingPathComponent(outputURL.lastPathComponent)
            .path
        let rootComponents = root.pathComponents
        let outputComponents = URL(fileURLWithPath: realOutputPath).pathComponents
        if outputComponents.count >= rootComponents.count,
           zip(rootComponents, outputComponents).allSatisfy({ $0 == $1 }) {
            throw StorageBackupError.outputInsideRoot(realOutputPath)
        }
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func listRegularFiles(in directory: URL) throws -> [URL] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw StorageBackupError.readFailed
        }
        var result: [URL] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let info = try fileInfo(url.path)
            guard !info.isSymlink, info.isRegular else {
                throw StorageBackupError.invalidPath("历史分段目录包含非普通文件")
            }
            result.append(url)
        }
        return result
    }

    private static func copyRegularFile(
        from source: URL,
        to destination: URL
    ) throws -> CopyResult {
        let sourceDescriptor = source.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0 else {
            throw StorageBackupError.readFailed
        }
        defer { close(sourceDescriptor) }
        var sourceInfo = stat()
        guard fstat(sourceDescriptor, &sourceInfo) == 0,
              (sourceInfo.st_mode & S_IFMT) == S_IFREG else {
            throw StorageBackupError.readFailed
        }

        let destinationDescriptor = destination.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard destinationDescriptor >= 0 else {
            throw StorageBackupError.writeFailed
        }
        defer { close(destinationDescriptor) }

        var hasher = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(sourceDescriptor, base, raw.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw StorageBackupError.readFailed
            }
            let chunk = Data(buffer.prefix(count))
            hasher.update(data: chunk)
            var written = 0
            while written < chunk.count {
                let result = chunk.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.write(destinationDescriptor, base.advanced(by: written), chunk.count - written)
                }
                if result <= 0 {
                    if errno == EINTR { continue }
                    throw StorageBackupError.writeFailed
                }
                written += result
            }
            total += count
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return CopyResult(
            byteCount: total,
            sha256: digest,
            mode: Int(sourceInfo.st_mode & 0o777)
        )
    }
}
