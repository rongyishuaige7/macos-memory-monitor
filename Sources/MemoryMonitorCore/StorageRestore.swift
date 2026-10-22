import CryptoKit
import Darwin
import Foundation

public enum StorageRestoreError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case invalidBackup(String)
    case transactionPending
    case nothingToRecover
    case lockTimedOut
    case permissionDenied
    case readFailed
    case writeFailed
    case rollbackFailed

    public var description: String {
        switch self {
        case .invalidBackup(let message): return message
        case .transactionPending: return "检测到未完成的恢复事务，请先运行 storage recover"
        case .nothingToRecover: return "没有可恢复的未完成事务"
        case .lockTimedOut: return "等待维护锁超时，应用可能仍在运行"
        case .permissionDenied: return "没有权限恢复数据"
        case .readFailed: return "无法读取备份或当前数据"
        case .writeFailed: return "无法写入恢复数据"
        case .rollbackFailed: return "恢复失败且回滚未完成，请保留现场并运行 storage recover"
        }
    }
}

public struct StorageRestoreResult: Sendable, Equatable {
    public let restoredFiles: Int
    public let previousDataRetained: Bool
}

/// Offline restore. The current set is copied aside before any target file is
/// removed; a marker blocks production stores until the transaction completes
/// or `recover` rolls it back.
public enum StorageRestore {
    private static let knownFiles = [
        "history.json",
        "history.json.journal",
        "history.json.clock",
        "actions.jsonl",
        "actions.jsonl.clock"
    ]
    private static let segmentsDirectory = "history.json.segments"
    private static let markerSchemaVersion = 1

    private struct Marker: Codable {
        let schemaVersion: Int
        let id: String
        let createdAt: Date
        let phase: String
        let currentBackup: String
        let stage: String
    }

    private struct FileInfo {
        let isSymlink: Bool
        let isRegular: Bool
        let isDirectory: Bool
    }

    private struct CopyResult {
        let byteCount: Int
        let sha256: String
    }

    public static func restore(
        backupDirectory: URL,
        root: URL,
        now: Date = Date()
    ) throws -> StorageRestoreResult {
        let backupRoot = canonicalURL(backupDirectory)
        let dataRoot = canonicalURL(root)
        let dataInfo = try fileInfo(dataRoot.path)
        guard dataInfo.isDirectory, !dataInfo.isSymlink else {
            throw StorageRestoreError.invalidBackup("数据根必须是真实目录")
        }
        guard backupRoot.path != dataRoot.path else {
            throw StorageRestoreError.invalidBackup("备份目录不能是数据根")
        }
        guard !isInside(backupRoot.path, root: dataRoot.path) else {
            throw StorageRestoreError.invalidBackup("备份目录不能位于数据根内")
        }
        let manifestURL = backupRoot.appendingPathComponent(StorageBackup.manifestFileName)
        let manifest: StorageBackupManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(StorageBackupManifest.self, from: data)
        } catch {
            throw StorageRestoreError.invalidBackup("无法读取 backup.json")
        }
        guard manifest.schemaVersion == StorageBackupManifest.currentSchemaVersion,
              manifest.restorable else {
            throw StorageRestoreError.invalidBackup("备份清单标记为不可直接恢复")
        }
        let backupData = backupRoot.appendingPathComponent(StorageBackup.dataDirectoryName, isDirectory: true)
        let backupDataInfo = try fileInfo(backupData.path)
        guard backupDataInfo.isDirectory, !backupDataInfo.isSymlink else {
            throw StorageRestoreError.invalidBackup("备份数据目录无效")
        }
        try validateManifestFiles(manifest, backupData: backupData)

        let maintenance: Int32
        do {
            maintenance = try MaintenanceLock.acquire(
                root: dataRoot,
                mode: .exclusive,
                timeoutSeconds: 2
            )
        } catch MaintenanceLockError.timedOut {
            throw StorageRestoreError.lockTimedOut
        } catch {
            throw StorageRestoreError.writeFailed
        }
        defer { MaintenanceLock.release(maintenance) }
        guard !MaintenanceTransaction.exists(root: dataRoot) else {
            throw StorageRestoreError.transactionPending
        }
        let historyLock = try StoreFileLock.acquire(
            at: dataRoot.appendingPathComponent("history.json.lock")
        )
        defer { StoreFileLock.release(historyLock) }
        let auditLock = try StoreFileLock.acquire(
            at: dataRoot.appendingPathComponent("actions.jsonl.lock")
        )
        defer { StoreFileLock.release(auditLock) }

        let identifier = UUID().uuidString
        let currentBackup = dataRoot.appendingPathComponent(
            ".memory-monitor-restore-current-" + identifier,
            isDirectory: true
        )
        let stage = dataRoot.appendingPathComponent(
            ".memory-monitor-restore-stage-" + identifier,
            isDirectory: true
        )
        let marker = Marker(
            schemaVersion: markerSchemaVersion,
            id: identifier,
            createdAt: now,
            phase: "prepared",
            currentBackup: currentBackup.path,
            stage: stage.path
        )

        var transactionStarted = false
        do {
            try copyCurrentData(from: dataRoot, to: currentBackup)
            try copyBackupData(manifest: manifest, from: backupData, to: stage)
            try writeMarker(marker, root: dataRoot, replacing: false)
            transactionStarted = true
            try removeCurrentData(from: dataRoot)
            try installStagedData(from: stage, to: dataRoot)
        } catch {
            guard transactionStarted else {
                // The target was not modified yet; keep the current set intact.
                try? removeIfExists(MaintenanceTransaction.url(root: dataRoot))
                if let restoreError = error as? StorageRestoreError {
                    throw restoreError
                }
                throw StorageRestoreError.writeFailed
            }
            do {
                try rollback(marker: marker, root: dataRoot)
                // Keep both forensic copies on failure, but remove the marker
                // so normal stores are not blocked after a successful rollback.
                try removeIfExists(MaintenanceTransaction.url(root: dataRoot))
            } catch {
                throw StorageRestoreError.rollbackFailed
            }
            if let restoreError = error as? StorageRestoreError {
                throw restoreError
            }
            throw StorageRestoreError.writeFailed
        }

        var committed = marker
        committed = Marker(
            schemaVersion: committed.schemaVersion,
            id: committed.id,
            createdAt: committed.createdAt,
            phase: "committed",
            currentBackup: committed.currentBackup,
            stage: committed.stage
        )
        try writeMarker(committed, root: dataRoot, replacing: true)
        try removeIfExists(MaintenanceTransaction.url(root: dataRoot))
        try removeIfExists(stage)
        try removeIfExists(currentBackup)
        return StorageRestoreResult(
            restoredFiles: manifest.files.filter(\.present).count,
            previousDataRetained: false
        )
    }

    /// Rolls back a prepared restore transaction. This is intentionally
    /// idempotent: if the marker is already gone, nothing is changed.
    public static func recover(root: URL) throws -> StorageRestoreResult {
        let dataRoot = canonicalURL(root)
        let dataInfo = try fileInfo(dataRoot.path)
        guard dataInfo.isDirectory, !dataInfo.isSymlink else {
            throw StorageRestoreError.invalidBackup("数据根必须是真实目录")
        }
        let markerURL = MaintenanceTransaction.url(root: dataRoot)
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            throw StorageRestoreError.nothingToRecover
        }
        let marker: Marker
        do {
            let data = try Data(contentsOf: markerURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            marker = try decoder.decode(Marker.self, from: data)
        } catch {
            throw StorageRestoreError.invalidBackup("恢复事务标记无效")
        }
        guard marker.schemaVersion == markerSchemaVersion else {
            throw StorageRestoreError.invalidBackup("恢复事务版本不受支持")
        }
        let currentBackupURL = canonicalURL(URL(fileURLWithPath: marker.currentBackup))
        let stageURL = canonicalURL(URL(fileURLWithPath: marker.stage))
        guard isInside(currentBackupURL.path, root: dataRoot.path),
              isInside(stageURL.path, root: dataRoot.path) else {
            throw StorageRestoreError.invalidBackup("恢复事务路径越界")
        }

        let maintenance: Int32
        do {
            maintenance = try MaintenanceLock.acquire(
                root: dataRoot,
                mode: .exclusive,
                timeoutSeconds: 2
            )
        } catch MaintenanceLockError.timedOut {
            throw StorageRestoreError.lockTimedOut
        } catch {
            throw StorageRestoreError.writeFailed
        }
        defer { MaintenanceLock.release(maintenance) }
        let historyLock = try StoreFileLock.acquire(
            at: dataRoot.appendingPathComponent("history.json.lock")
        )
        defer { StoreFileLock.release(historyLock) }
        let auditLock = try StoreFileLock.acquire(
            at: dataRoot.appendingPathComponent("actions.jsonl.lock")
        )
        defer { StoreFileLock.release(auditLock) }

        if marker.phase == "committed" {
            try removeIfExists(stageURL)
            try removeIfExists(currentBackupURL)
            try removeIfExists(markerURL)
            return StorageRestoreResult(restoredFiles: 0, previousDataRetained: false)
        }
        try rollback(marker: marker, root: dataRoot)
        try removeIfExists(stageURL)
        try removeIfExists(currentBackupURL)
        try removeIfExists(markerURL)
        return StorageRestoreResult(restoredFiles: 0, previousDataRetained: true)
    }

    private static func validateManifestFiles(
        _ manifest: StorageBackupManifest,
        backupData: URL
    ) throws {
        var presentPaths = Set<String>()
        for file in manifest.files where file.present {
            guard isSafeRelativePath(file.relativePath) else {
                throw StorageRestoreError.invalidBackup("备份包含不安全路径")
            }
            guard knownFiles.contains(file.relativePath)
                || file.relativePath.hasPrefix(segmentsDirectory + "/")
                || (file.relativePath == segmentsDirectory
                    && file.role == "historySegmentsDirectory") else {
                throw StorageRestoreError.invalidBackup("备份包含未知数据文件")
            }
            guard presentPaths.insert(file.relativePath).inserted else {
                throw StorageRestoreError.invalidBackup("备份包含重复文件")
            }
            if file.role == "historySegmentsDirectory",
               file.relativePath == segmentsDirectory {
                continue
            }
            let source = backupData.appendingPathComponent(file.relativePath)
            let info = try fileInfo(source.path)
            guard info.isRegular, !info.isSymlink else {
                throw StorageRestoreError.invalidBackup("备份文件不是普通文件")
            }
            let result = try hashFile(source)
            guard result.byteCount == file.byteCount, result.sha256 == file.sha256 else {
                throw StorageRestoreError.invalidBackup("备份文件校验失败")
            }
        }
        if manifest.historyStatus != .empty {
            guard presentPaths.contains("history.json") else {
                throw StorageRestoreError.invalidBackup("备份缺少历史索引")
            }
        }
        guard presentPaths.contains("actions.jsonl") else {
            throw StorageRestoreError.invalidBackup("备份缺少审计文件")
        }
        for path in presentPaths where path.hasPrefix(segmentsDirectory + "/") {
            let remainder = String(path.dropFirst(segmentsDirectory.count + 1))
            guard !remainder.contains("/"), !remainder.isEmpty else {
                throw StorageRestoreError.invalidBackup("备份分段路径无效")
            }
        }
    }

    private static func copyCurrentData(from root: URL, to destination: URL) throws {
        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        for path in knownFiles {
            let source = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            _ = try copyFile(from: source, to: destination.appendingPathComponent(path))
        }
        let segments = root.appendingPathComponent(segmentsDirectory, isDirectory: true)
        if let info = try? fileInfo(segments.path), info.isDirectory, !info.isSymlink {
            let target = destination.appendingPathComponent(segmentsDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            for file in try listRegularFiles(in: segments) {
                _ = try copyFile(
                    from: file,
                    to: target.appendingPathComponent(file.lastPathComponent)
                )
            }
        }
    }

    private static func copyBackupData(
        manifest: StorageBackupManifest,
        from backupData: URL,
        to stage: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: stage,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        for file in manifest.files where file.present {
            let destination = stage.appendingPathComponent(file.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if file.role == "historySegmentsDirectory",
               file.relativePath == segmentsDirectory {
                try FileManager.default.createDirectory(
                    at: destination,
                    withIntermediateDirectories: true
                )
                continue
            }
            let result = try copyFile(
                from: backupData.appendingPathComponent(file.relativePath),
                to: destination
            )
            guard result.byteCount == file.byteCount, result.sha256 == file.sha256 else {
                throw StorageRestoreError.invalidBackup("备份文件复制校验失败")
            }
        }
    }

    private static func installStagedData(from stage: URL, to root: URL) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: stage,
            includingPropertiesForKeys: nil,
            options: []
        )
        for url in urls {
            let relative = url.pathComponents.dropFirst(stage.pathComponents.count).joined(separator: "/")
            guard isSafeRelativePath(relative) else {
                throw StorageRestoreError.invalidBackup("暂存路径无效")
            }
            let destination = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: url, to: destination)
        }
    }

    private static func rollback(marker: Marker, root: URL) throws {
        let currentBackup = canonicalURL(URL(fileURLWithPath: marker.currentBackup))
        guard isInside(currentBackup.path, root: root.path) else {
            throw StorageRestoreError.invalidBackup("恢复事务备份路径越界")
        }
        try removeCurrentData(from: root)
        try copyCurrentData(from: currentBackup, to: root)
    }

    private static func removeCurrentData(from root: URL) throws {
        for path in knownFiles {
            try removeIfExists(root.appendingPathComponent(path))
        }
        let segments = root.appendingPathComponent(segmentsDirectory, isDirectory: true)
        if let info = try? fileInfo(segments.path) {
            guard info.isDirectory, !info.isSymlink else {
                throw StorageRestoreError.invalidBackup("当前分段路径不是真实目录")
            }
            try FileManager.default.removeItem(at: segments)
        }
    }

    private static func writeMarker(
        _ marker: Marker,
        root: URL,
        replacing: Bool
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(marker)
        let url = MaintenanceTransaction.url(root: root)
        try data.write(to: url, options: replacing ? [.atomic] : [.withoutOverwriting])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func listRegularFiles(in directory: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var result: [URL] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let info = try fileInfo(url.path)
            guard info.isRegular, !info.isSymlink else {
                throw StorageRestoreError.invalidBackup("当前数据包含非普通文件")
            }
            result.append(url)
        }
        return result
    }

    private static func copyFile(from source: URL, to destination: URL) throws -> CopyResult {
        let sourceDescriptor = source.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard sourceDescriptor >= 0 else {
            throw StorageRestoreError.readFailed
        }
        defer { close(sourceDescriptor) }
        let destinationDescriptor = destination.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard destinationDescriptor >= 0 else {
            throw StorageRestoreError.writeFailed
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
                throw StorageRestoreError.readFailed
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
                    throw StorageRestoreError.writeFailed
                }
                written += result
            }
            total += count
        }
        return CopyResult(
            byteCount: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func hashFile(_ url: URL) throws -> CopyResult {
        let descriptor = url.path.withCString {
            open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw StorageRestoreError.readFailed
        }
        defer { close(descriptor) }
        var hasher = SHA256()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, raw.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw StorageRestoreError.readFailed
            }
            hasher.update(data: Data(buffer.prefix(count)))
            total += count
        }
        return CopyResult(
            byteCount: total,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func fileInfo(_ path: String) throws -> FileInfo {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw StorageRestoreError.readFailed
        }
        let type = info.st_mode & S_IFMT
        return FileInfo(
            isSymlink: type == S_IFLNK,
            isRegular: type == S_IFREG,
            isDirectory: type == S_IFDIR
        )
    }

    private static func canonicalURL(_ url: URL) -> URL {
        URL(
            fileURLWithPath: canonicalPath(url.path) ?? url.path,
            isDirectory: true
        )
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        let rootComponents = URL(fileURLWithPath: root).pathComponents
        let pathComponents = URL(fileURLWithPath: path).pathComponents
        guard pathComponents.count > rootComponents.count else { return false }
        return zip(rootComponents, pathComponents).allSatisfy { $0 == $1 }
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return true
    }

    private static func removeIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw StorageRestoreError.readFailed
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw StorageRestoreError.invalidBackup("恢复路径包含符号链接")
        }
        try FileManager.default.removeItem(at: url)
    }
}
