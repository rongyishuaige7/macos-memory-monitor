import Darwin
import Foundation
import MemoryMonitorCore

private enum FixtureToolError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidRoot(String)
    case nonEmptyRoot
    case missingOutput(String)
    case verificationFailed(String)

    var description: String {
        switch self {
        case .invalidArguments:
            return "用法：memory-monitor-fixture --storage-root <临时目录>"
        case let .invalidRoot(path):
            return "storage root 必须是系统临时目录（/tmp 或 Darwin 用户临时目录）下的绝对目录：\(path)"
        case .nonEmptyRoot:
            return "storage root 必须为空，以避免复用旧 fixture 数据"
        case let .missingOutput(path):
            return "fixture 输出缺失：\(path)"
        case let .verificationFailed(message):
            return "fixture 校验失败：\(message)"
        }
    }
}

@main
struct MemoryMonitorFixtureTool {
    static func main() async {
        do {
            let root = try parseRoot(arguments: Array(CommandLine.arguments.dropFirst()))
            try validateRoot(root)
            let dataset = MemoryMonitorUIFixture.makeDataset(now: Date())
            let historyURL = MemoryMonitorStoragePaths.historyFileURL(root: root)
            let auditURL = MemoryMonitorStoragePaths.auditFileURL(root: root)

            // Keep thresholds above the fixture size so the pre-launch state
            // retains a journal. App startup then exercises journal merge and
            // canonical compaction through the normal load path.
            let historyStore = HistoryStore(
                fileURL: historyURL,
                compactionRecordThreshold: 1_000,
                compactionByteThreshold: 64 * 1024 * 1024
            )
            for record in dataset.historyRecords {
                _ = try await historyStore.append(record, now: dataset.referenceDate)
            }
            let preFlushHistoryDiagnostics = await historyStore.diagnostics()
            guard preFlushHistoryDiagnostics.journalRecordCount == dataset.historyRecords.count - 1,
                  preFlushHistoryDiagnostics.journalBytes > 0 else {
                throw FixtureToolError.verificationFailed(
                    "history journal 未保留完整的增量记录"
                )
            }

            // Read the journal through a new actor without compacting it. This
            // is the same recovery path used by a newly launched app process.
            let replayStore = HistoryStore(
                fileURL: historyURL,
                compactionRecordThreshold: 1_000,
                compactionByteThreshold: 64 * 1024 * 1024
            )
            let replayedHistory = try await replayStore.load(now: dataset.referenceDate)
            try verifyHistory(
                replayedHistory,
                expected: dataset.historyRecords
            )
            let auditStore = ProcessActionAuditStore(fileURL: auditURL)
            for event in dataset.auditEvents {
                _ = try await auditStore.append(event, now: dataset.referenceDate)
            }

            // Verify the files with fresh actors as well; this catches date
            // encoding, journal replay and JSONL repair regressions that an
            // in-memory assertion would miss. The history journal is kept
            // intentionally so the launched app exercises its recovery path.
            let finalHistoryStore = HistoryStore(
                fileURL: historyURL,
                compactionRecordThreshold: 1_000,
                compactionByteThreshold: 64 * 1024 * 1024
            )
            let finalHistory = try await finalHistoryStore.load(now: dataset.referenceDate)
            try verifyHistory(finalHistory, expected: dataset.historyRecords)
            let finalAuditStore = ProcessActionAuditStore(fileURL: auditURL)
            let finalAudit = try await finalAuditStore.load(now: dataset.referenceDate)
            try verifyAudit(finalAudit, expected: dataset.auditEvents)

            try verifyOutput(
                root: root,
                historyURL: historyURL,
                auditURL: auditURL,
                expectedHistoryCount: dataset.historyRecords.count,
                expectedAuditCount: dataset.auditEvents.count,
                historyDiagnostics: await historyStore.diagnostics()
            )

            print("FIXTURE_REFERENCE_DATE=\(dataset.referenceDate.timeIntervalSince1970)")
            print("FIXTURE_HISTORY_RECORDS=\(dataset.historyRecords.count)")
            print("FIXTURE_AUDIT_EVENTS=\(dataset.auditEvents.count)")
            print("FIXTURE_HISTORY_JOURNAL_RECORDS=\(preFlushHistoryDiagnostics.journalRecordCount)")
            print("FIXTURE_STORAGE_ROOT=\(root.path)")
            print("FIXTURE_HISTORY_FILE=\(historyURL.path)")
            print("FIXTURE_AUDIT_FILE=\(auditURL.path)")
        } catch {
            fputs("memory-monitor-fixture: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func parseRoot(arguments: [String]) throws -> URL {
        guard arguments.count == 2, arguments[0] == "--storage-root" else {
            throw FixtureToolError.invalidArguments
        }
        let path = arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              path.hasPrefix("/"),
              !path.contains(where: { $0 == "\n" || $0 == "\r" }),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw FixtureToolError.invalidRoot(path)
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func validateRoot(_ root: URL) throws {
        let requestedPath = root.standardizedFileURL.path
        let resolvedPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard requestedPath != "/" else {
            throw FixtureToolError.invalidRoot(root.path)
        }

        // Keep the CLI and app on the same trust boundary. The Core resolver
        // uses the host-provided Darwin temporary root and /tmp; TMPDIR is
        // intentionally not treated as a trust anchor because callers can
        // point it at the project or another persistent directory.
        var validationEnvironment = ProcessInfo.processInfo.environment
        validationEnvironment[MemoryMonitorStoragePaths.overrideEnvironmentKey] = requestedPath
        guard let isolatedRoot = MemoryMonitorStoragePaths.isolatedRootURL(
            environment: validationEnvironment
        ), URL(fileURLWithPath: isolatedRoot.path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path
            == URL(fileURLWithPath: resolvedPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path else {
            throw FixtureToolError.invalidRoot(root.path)
        }

        let fileManager = FileManager.default
        guard !hasUnsafeExistingAncestor(atPath: requestedPath) else {
            throw FixtureToolError.invalidRoot(root.path)
        }
        if isSymbolicLink(atPath: requestedPath) {
            throw FixtureToolError.invalidRoot(root.path)
        }
        if fileManager.fileExists(atPath: requestedPath) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: requestedPath, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !isSymbolicLink(atPath: requestedPath) else {
                throw FixtureToolError.invalidRoot(requestedPath)
            }
            guard try fileManager.contentsOfDirectory(atPath: requestedPath).isEmpty else {
                throw FixtureToolError.nonEmptyRoot
            }
        } else {
            try fileManager.createDirectory(
                at: URL(fileURLWithPath: requestedPath, isDirectory: true),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: requestedPath
        )
        let resolvedPathAfterCreation = URL(fileURLWithPath: requestedPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let canonicalIsolatedPath = URL(fileURLWithPath: isolatedRoot.path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard !isSymbolicLink(atPath: requestedPath),
              resolvedPathAfterCreation == canonicalIsolatedPath else {
            throw FixtureToolError.invalidRoot(requestedPath)
        }
    }

    /// Inspect every path component that already exists before creating the
    /// requested directory. Foundation's symlink resolver can leave a
    /// dangling link followed by a missing suffix unresolved; `mkdir` would
    /// then follow that link when creating the suffix. Stop at the first
    /// missing component because `withIntermediateDirectories: false` can
    /// create only the final component and no later component exists yet.
    private static func hasUnsafeExistingAncestor(atPath path: String) -> Bool {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return true }

        var currentPath = ""
        for (index, component) in components.enumerated() {
            currentPath += "/" + component

            var information = stat()
            guard lstat(currentPath, &information) == 0 else {
                // An absent component ends the existing ancestor chain. Any
                // other error means the path cannot be trusted or inspected.
                return errno == ENOENT ? false : true
            }

            let fileType = information.st_mode & S_IFMT
            var isTraversableDirectory = fileType == S_IFDIR
            if fileType == S_IFLNK {
                guard isAllowedSystemAlias(atPath: currentPath) else {
                    return true
                }
                isTraversableDirectory = true
            }
            if index < components.count - 1 && !isTraversableDirectory {
                return true
            }
        }
        return false
    }

    /// macOS exposes `/tmp` and `/var` as stable aliases to `/private/tmp`
    /// and `/private/var`. They are the only symlink components permitted in
    /// an otherwise trusted path, and the link target is checked explicitly
    /// so a replaced system alias cannot widen this exception.
    private static func isAllowedSystemAlias(atPath path: String) -> Bool {
        let allowedTargets: [String: [String]] = [
            "/tmp": ["private/tmp", "/private/tmp"],
            "/var": ["private/var", "/private/var"]
        ]
        guard let expectedTargets = allowedTargets[path] else { return false }

        var targetBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let targetLength = path.withCString { pathPointer in
            targetBuffer.withUnsafeMutableBufferPointer { buffer in
                readlink(pathPointer, buffer.baseAddress, buffer.count)
            }
        }
        guard targetLength > 0,
              targetLength < targetBuffer.count,
              let target = String(
                  bytes: targetBuffer.prefix(Int(targetLength)).map {
                      UInt8(bitPattern: $0)
                  },
                  encoding: .utf8
              ) else {
            return false
        }
        guard expectedTargets.contains(target) else { return false }

        let expectedPath: String
        switch path {
        case "/tmp":
            expectedPath = "/private/tmp"
        case "/var":
            expectedPath = "/private/var"
        default:
            return false
        }
        var targetInformation = stat()
        guard lstat(expectedPath, &targetInformation) == 0 else { return false }
        return (targetInformation.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isSymbolicLink(atPath path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func verifyHistory(
        _ actual: [MemoryHistoryRecord],
        expected: [MemoryHistoryRecord]
    ) throws {
        guard actual.count == expected.count,
              actual.map(\.timestamp) == expected.map(\.timestamp),
              actual.allSatisfy({ $0.sourceSampledAt != nil }) else {
            throw FixtureToolError.verificationFailed(
                "history reload 数量、顺序或 freshness marker 不匹配"
            )
        }
    }

    private static func verifyAudit(
        _ actual: [ProcessActionAuditEvent],
        expected: [ProcessActionAuditEvent]
    ) throws {
        let actualIDs = Set(actual.map(\.id))
        let expectedIDs = Set(expected.map(\.id))
        guard actual.count == expected.count, actualIDs == expectedIDs else {
            throw FixtureToolError.verificationFailed(
                "audit JSONL reload 数量或事件 ID 不匹配"
            )
        }
    }

    private static func verifyOutput(
        root: URL,
        historyURL: URL,
        auditURL: URL,
        expectedHistoryCount: Int,
        expectedAuditCount: Int,
        historyDiagnostics: HistoryStoreDiagnostics
    ) throws {
        let fileManager = FileManager.default
        let expectedPaths = [
            historyURL.path,
            historyURL.path + ".clock",
            historyURL.path + ".journal",
            historyURL.path + ".lock",
            auditURL.path,
            auditURL.path + ".clock",
            auditURL.path + ".lock"
        ]
        for path in expectedPaths {
            guard fileManager.fileExists(atPath: path) else {
                throw FixtureToolError.missingOutput(path)
            }
        }
        guard historyDiagnostics.journalRecordCount == expectedHistoryCount - 1,
              historyDiagnostics.journalBytes > 0 else {
            throw FixtureToolError.verificationFailed(
                "启动前 history journal 未保留完整的增量记录"
            )
        }
        let auditData = try Data(contentsOf: auditURL)
        let auditLineCount = auditData
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .count
        guard auditLineCount == expectedAuditCount else {
            throw FixtureToolError.missingOutput(auditURL.path)
        }
        let expectedNames = Set(expectedPaths.map {
            URL(fileURLWithPath: $0).lastPathComponent
        })
        let actualNames = Set(try fileManager.contentsOfDirectory(atPath: root.path))
        guard actualNames == expectedNames else {
            throw FixtureToolError.verificationFailed(
                "storage root 包含非预期文件"
            )
        }
        guard permissions(atPath: root.path) == 0o700 else {
            throw FixtureToolError.verificationFailed(
                "storage root 权限不是 0700"
            )
        }
        for path in expectedPaths {
            guard !isSymbolicLink(atPath: path),
                  permissions(atPath: path) == 0o600 else {
                throw FixtureToolError.missingOutput(path)
            }
        }
    }

    private static func permissions(atPath path: String) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let value = attributes[.posixPermissions] as? NSNumber else {
            return 0
        }
        return value.intValue & 0o777
    }
}
