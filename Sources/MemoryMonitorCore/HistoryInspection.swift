import CryptoKit
import Darwin
import Foundation

public enum HistoryInspectionStatus: String, Codable, Sendable, Equatable {
    case healthy
    case legacy
    case empty
    case unsupportedVersion
    case missingIndex
    case missingSegment
    case checksumMismatch
    case tornJournal
    case permissionDenied
    case busy
    case changedDuringInspection
    case unsafePath
    case invalidData
    case fileTooLarge
}

public enum HistoryStorageFormat: String, Codable, Sendable, Equatable {
    case empty
    case legacyV1
    case segmentedV2
    case journalOnly
    case unknown
}

public struct HistoryInspectionIssue: Codable, Sendable, Equatable {
    public let code: String
    public let count: Int

    public init(code: String, count: Int = 1) {
        self.code = code
        self.count = max(count, 1)
    }
}

public struct HistoryInspectionReport: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let status: HistoryInspectionStatus
    public let format: HistoryStorageFormat
    public let inspectedAt: Date
    public let durationMilliseconds: Double
    public let recordCount: Int
    public let segmentCount: Int
    public let journalRecordCount: Int
    public let earliestTimestamp: Date?
    public let latestTimestamp: Date?
    public let totalBytes: Int
    public let indexBytes: Int
    public let segmentBytes: Int
    public let journalBytes: Int
    public let clockBytes: Int
    public let issues: [HistoryInspectionIssue]

    public init(
        status: HistoryInspectionStatus,
        format: HistoryStorageFormat,
        inspectedAt: Date = Date(),
        durationMilliseconds: Double = 0,
        recordCount: Int = 0,
        segmentCount: Int = 0,
        journalRecordCount: Int = 0,
        earliestTimestamp: Date? = nil,
        latestTimestamp: Date? = nil,
        totalBytes: Int = 0,
        indexBytes: Int = 0,
        segmentBytes: Int = 0,
        journalBytes: Int = 0,
        clockBytes: Int = 0,
        issues: [HistoryInspectionIssue] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.status = status
        self.format = format
        self.inspectedAt = inspectedAt
        self.durationMilliseconds = durationMilliseconds.isFinite
            ? max(durationMilliseconds, 0)
            : 0
        self.recordCount = max(recordCount, 0)
        self.segmentCount = max(segmentCount, 0)
        self.journalRecordCount = max(journalRecordCount, 0)
        self.earliestTimestamp = earliestTimestamp
        self.latestTimestamp = latestTimestamp
        self.totalBytes = max(totalBytes, 0)
        self.indexBytes = max(indexBytes, 0)
        self.segmentBytes = max(segmentBytes, 0)
        self.journalBytes = max(journalBytes, 0)
        self.clockBytes = max(clockBytes, 0)
        self.issues = issues
    }
}

/// Read-only history inspection. This deliberately does not call
/// `HistoryStore.load`, `flush`, `merge`, or any production recovery path:
/// opening the store can prune, repair, or create files, which would make the
/// evidence self-modifying.
public enum HistoryInspector {
    private static let maximumIndexBytes = HistoryStore.maximumSnapshotFileBytes
    private static let maximumSegmentBytes = HistoryStore.maximumSnapshotFileBytes
    private static let maximumJournalBytes = HistoryStore.maximumJournalFileBytes
    private static let maximumJournalLineBytes = HistoryStore.maximumJournalLineBytes
    private static let maximumClockBytes = HistoryStore.maximumClockFileBytes
    private static let maximumSegmentCount = 16_384

    public static func inspect(root: URL) -> HistoryInspectionReport {
        let started = Date()
        let clock = ContinuousClock()
        let start = clock.now
        var state = InspectionState()

        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.path
        var rootInfo = stat()
        if lstat(rootPath, &rootInfo) != 0 {
            state.mark(errno == EACCES || errno == EPERM ? .permissionDenied : .invalidData,
                       code: "rootUnavailable")
            return state.report(started: started, start: start, clock: clock)
        }
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            state.mark(.unsafePath, code: "rootNotDirectory")
            return state.report(started: started, start: start, clock: clock)
        }
        if (rootInfo.st_mode & S_IFMT) == S_IFLNK {
            state.mark(.unsafePath, code: "rootSymlink")
            return state.report(started: started, start: start, clock: clock)
        }

        let historyURL = MemoryMonitorStoragePaths.historyFileURL(root: rootURL)
        let segmentsURL = URL(fileURLWithPath: historyURL.path + ".segments", isDirectory: true)
        let journalURL = URL(fileURLWithPath: historyURL.path + ".journal")
        let clockURL = URL(fileURLWithPath: historyURL.path + ".clock")
        let lockURL = URL(fileURLWithPath: historyURL.path + ".lock")

        state.fingerprint(path: rootPath)
        state.fingerprint(path: historyURL.path)
        state.fingerprint(path: segmentsURL.path)
        state.fingerprint(path: journalURL.path)
        state.fingerprint(path: clockURL.path)

        var lockFD: Int32 = -1
        if let lockInfo = state.fileInfo(lockURL.path) {
            if lockInfo.isSymlink {
                state.mark(.unsafePath, code: "lockSymlink")
            } else if !lockInfo.isRegular {
                state.mark(.unsafePath, code: "lockNotRegular")
            } else {
                lockFD = open(lockURL.path, O_RDONLY | O_CLOEXEC)
                if lockFD < 0 {
                    state.mark(errno == EACCES || errno == EPERM ? .permissionDenied : .invalidData,
                               code: "lockUnreadable")
                } else if flock(lockFD, LOCK_SH | LOCK_NB) != 0 {
                    let code = errno
                    close(lockFD)
                    lockFD = -1
                    if code == EWOULDBLOCK || code == EAGAIN {
                        state.mark(.busy, code: "lockBusy")
                    } else {
                        state.mark(.invalidData, code: "lockUnavailable")
                    }
                }
            }
        }
        defer {
            if lockFD >= 0 {
                _ = flock(lockFD, LOCK_UN)
                close(lockFD)
            }
        }

        if state.status == .busy {
            return state.report(started: started, start: start, clock: clock)
        }

        let hasIndex = state.fileInfo(historyURL.path) != nil
        let segmentsInfo = state.fileInfo(segmentsURL.path)
        let hasSegmentsDirectory = segmentsInfo != nil
        if let segmentsInfo, segmentsInfo.isSymlink || !segmentsInfo.isDirectory {
            state.mark(.unsafePath, code: "segmentsDirectory")
        }
        let journalInfo = state.fileInfo(journalURL.path)
        let journalRecords: [MemoryHistoryRecord]
        if let journalInfo {
            if journalInfo.isSymlink {
                state.mark(.unsafePath, code: "journalSymlink")
                journalRecords = []
            } else if !journalInfo.isRegular {
                state.mark(.unsafePath, code: "journalNotRegular")
                journalRecords = []
            } else if let data = state.readData(journalURL.path, maximum: maximumJournalBytes, code: "journalRead") {
                let result = decodeJournal(data)
                journalRecords = result.records
                state.journalBytes = data.count
                state.journalRecordCount = result.records.count
                if result.tornTail {
                    state.mark(.tornJournal, code: "journalTornTail")
                }
                if result.invalidLine {
                    state.mark(.invalidData, code: "journalInvalidLine")
                }
            } else {
                journalRecords = []
            }
        } else {
            journalRecords = []
        }

        var indexRecords: [MemoryHistoryRecord] = []
        var segmentRecords: [MemoryHistoryRecord] = []
        if !hasIndex {
            state.format = hasSegmentsDirectory ? .unknown : (journalRecords.isEmpty ? .empty : .journalOnly)
            if hasSegmentsDirectory {
                state.mark(.missingIndex, code: "segmentsWithoutIndex")
            } else if !journalRecords.isEmpty {
                state.mark(.legacy, code: "journalOnly")
            } else {
                state.mark(.empty, code: "emptyStore")
            }
        } else if let indexInfo = state.fileInfo(historyURL.path) {
            if indexInfo.isSymlink {
                state.mark(.unsafePath, code: "indexSymlink")
            } else if !indexInfo.isRegular {
                state.mark(.unsafePath, code: "indexNotRegular")
            } else if let data = state.readData(historyURL.path, maximum: maximumIndexBytes, code: "indexRead") {
                state.indexBytes = data.count
                let decoded = decodeIndex(data, segmentsURL: segmentsURL, state: &state)
                indexRecords = decoded.records
                segmentRecords = decoded.segmentRecords
            }
        }

        if state.format == .empty {
            if !indexRecords.isEmpty || !segmentRecords.isEmpty {
                state.format = .unknown
            } else if !hasIndex && hasSegmentsDirectory {
                state.format = .unknown
            } else if !hasIndex && !journalRecords.isEmpty {
                state.format = .journalOnly
            } else if hasIndex {
                state.format = .unknown
            }
        }

        let allRecords = indexRecords + segmentRecords + journalRecords
        state.recordCount = indexRecords.count + segmentRecords.count
        state.earliestTimestamp = allRecords.map(\.timestamp).min()
        state.latestTimestamp = allRecords.map(\.timestamp).max()
        if let clockInfo = state.fileInfo(clockURL.path) {
            if clockInfo.isSymlink {
                state.mark(.unsafePath, code: "clockSymlink")
            } else if !clockInfo.isRegular {
                state.mark(.unsafePath, code: "clockNotRegular")
            } else if let data = state.readData(clockURL.path, maximum: maximumClockBytes, code: "clockRead") {
                state.clockBytes = data.count
                if (try? inspectionDecoder().decode(InspectionClockAnchor.self, from: data)) == nil {
                    state.mark(.invalidData, code: "clockInvalid")
                }
            }
        }

        state.totalBytes = state.indexBytes + state.segmentBytes + state.journalBytes + state.clockBytes
        state.checkFingerprints()
        return state.report(started: started, start: start, clock: clock)
    }

    private static func decodeIndex(
        _ data: Data,
        segmentsURL: URL,
        state: inout InspectionState
    ) -> (records: [MemoryHistoryRecord], segmentRecords: [MemoryHistoryRecord]) {
        let decoder = inspectionDecoder()
        if let index = try? decoder.decode(InspectionSegmentIndex.self, from: data) {
            guard index.version == 2 else {
                state.mark(index.version > 2 ? .unsupportedVersion : .invalidData,
                           code: "indexVersion")
                return ([], [])
            }
            guard index.records?.isEmpty == true,
                  index.segments.count <= maximumSegmentCount,
                  Set(index.segments.map(\.bucket)).count == index.segments.count else {
                state.mark(.invalidData, code: "indexStructure")
                return ([], [])
            }
            guard validateSegmentsDirectory(segmentsURL, state: &state) else {
                return ([], [])
            }
            state.format = .segmentedV2
            var records: [MemoryHistoryRecord] = []
            var totalSegmentBytes = 0
            var segmentCount = 0
            var remainingBytes = max(maximumIndexBytes - state.indexBytes, 0)
            for reference in index.segments {
                guard reference.isValid else {
                    state.mark(.invalidData, code: "segmentReference")
                    continue
                }
                guard remainingBytes > 0 else {
                    state.mark(.fileTooLarge, code: "segmentBudget")
                    break
                }
                let fileURL = segmentsURL.appendingPathComponent(reference.fileName)
                state.fingerprint(path: fileURL.path)
                guard let info = state.fileInfo(fileURL.path) else {
                    state.mark(.missingSegment, code: "segmentMissing")
                    continue
                }
                if info.isSymlink {
                    state.mark(.unsafePath, code: "segmentSymlink")
                    continue
                }
                guard info.isRegular else {
                    state.mark(.unsafePath, code: "segmentNotRegular")
                    continue
                }
                guard let payload = state.readData(
                    fileURL.path,
                    maximum: min(maximumSegmentBytes, remainingBytes),
                    code: "segmentRead"
                ) else {
                    continue
                }
                remainingBytes -= payload.count
                totalSegmentBytes += payload.count
                guard sha256(payload) == reference.digest else {
                    state.mark(.checksumMismatch, code: "segmentChecksum")
                    continue
                }
                guard let file = try? decoder.decode(MemoryHistoryFile.self, from: payload),
                      file.version == 1,
                      !file.records.isEmpty,
                      file.records.allSatisfy({ bucket(for: $0.timestamp) == reference.bucket }) else {
                    state.mark(.invalidData, code: "segmentStructure")
                    continue
                }
                records.append(contentsOf: file.records)
                segmentCount += 1
            }
            state.segmentBytes = totalSegmentBytes
            state.segmentCount = segmentCount
            return ([], records)
        }

        if let file = try? decoder.decode(MemoryHistoryFile.self, from: data) {
            guard file.version == 1 else {
                state.mark(file.version > 1 ? .unsupportedVersion : .invalidData,
                           code: "historyVersion")
                return ([], [])
            }
            state.format = .legacyV1
            state.mark(.legacy, code: "legacyV1")
            return (file.records, [])
        }

        state.mark(.invalidData, code: "indexDecode")
        return ([], [])
    }

    private static func validateSegmentsDirectory(
        _ segmentsURL: URL,
        state: inout InspectionState
    ) -> Bool {
        guard let info = state.fileInfo(segmentsURL.path) else {
            state.mark(.missingSegment, code: "segmentsDirectoryMissing")
            return false
        }
        if info.isSymlink {
            state.mark(.unsafePath, code: "segmentsDirectorySymlink")
            return false
        }
        guard info.isDirectory else {
            state.mark(.unsafePath, code: "segmentsDirectoryNotDirectory")
            return false
        }
        return true
    }

    private static func decodeJournal(_ data: Data) -> (
        records: [MemoryHistoryRecord],
        tornTail: Bool,
        invalidLine: Bool
    ) {
        guard !data.isEmpty else { return ([], false, false) }
        let decoder = inspectionDecoder()
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var records: [MemoryHistoryRecord] = []
        var tornTail = false
        var invalidLine = false
        for (index, line) in lines.enumerated() {
            let terminalEmpty = line.isEmpty
                && index == lines.count - 1
                && data.last == 0x0A
            if line.isEmpty {
                if terminalEmpty { continue }
                invalidLine = true
                continue
            }
            guard line.count <= maximumJournalLineBytes else {
                invalidLine = true
                continue
            }
            let lineData = Data(line)
            do {
                records.append(try decoder.decode(MemoryHistoryRecord.self, from: lineData))
            } catch {
                let isLast = index == lines.count - 1
                if isLast, data.last != 0x0A, isIncompleteJSONPrefix(lineData) {
                    tornTail = true
                } else {
                    invalidLine = true
                }
            }
        }
        return (records, tornTail, invalidLine)
    }

    private static func inspectionDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let legacy = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = try? fractional.parse(value) { return date }
            if let date = try? legacy.parse(value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid RFC 3339 timestamp"
            )
        }
        return decoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / (15 * 60)))
    }

    private static func isIncompleteJSONPrefix(_ data: Data) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false; continue }
                if byte == 0x5C { escaped = true; continue }
                if byte == 0x22 { inString = false }
                continue
            }
            if byte == 0x22 { inString = true; continue }
            if byte == 0x7B || byte == 0x5B { depth += 1 }
            if byte == 0x7D || byte == 0x5D { depth -= 1 }
        }
        return inString || depth > 0
    }

    private struct InspectionSegmentIndex: Codable {
        let version: Int
        let records: [MemoryHistoryRecord]?
        let segments: [InspectionSegmentReference]
    }

    private struct InspectionSegmentReference: Codable {
        let bucket: Int64
        let digest: String
        var fileName: String { "segment-\(bucket)-\(digest).json" }
        var isValid: Bool {
            digest.count == 64 && digest.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
    }

    private struct InspectionClockAnchor: Codable {
        let observedAt: Date
    }

    private struct InspectionFileInfo {
        let isSymlink: Bool
        let isRegular: Bool
        let isDirectory: Bool
        let size: Int
        let mode: mode_t
        let inode: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct InspectionFingerprint: Equatable {
        let mode: mode_t
        let inode: UInt64
        let size: Int
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct InspectionState {
        var status: HistoryInspectionStatus = .healthy
        var format: HistoryStorageFormat = .empty
        var issues: [String: Int] = [:]
        var recordCount = 0
        var segmentCount = 0
        var journalRecordCount = 0
        var earliestTimestamp: Date?
        var latestTimestamp: Date?
        var indexBytes = 0
        var segmentBytes = 0
        var journalBytes = 0
        var clockBytes = 0
        var totalBytes = 0
        private var fingerprints: [String: InspectionFingerprint?] = [:]

        mutating func mark(_ newStatus: HistoryInspectionStatus, code: String) {
            if rank(newStatus) > rank(status) {
                status = newStatus
            }
            issues[code, default: 0] += 1
        }

        mutating func fingerprint(path: String) {
            guard fingerprints[path] == nil else { return }
            fingerprints[path] = fingerprintValue(path)
        }

        mutating func checkFingerprints() {
            for (path, expected) in fingerprints where fingerprintValue(path) != expected {
                mark(.changedDuringInspection, code: "changedDuringInspection")
                return
            }
        }

        mutating func fileInfo(_ path: String) -> InspectionFileInfo? {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == EACCES || errno == EPERM {
                    mark(.permissionDenied, code: "permissionDenied")
                }
                return nil
            }
            let type = info.st_mode & S_IFMT
            return InspectionFileInfo(
                isSymlink: type == S_IFLNK,
                isRegular: type == S_IFREG,
                isDirectory: type == S_IFDIR,
                size: Int(max(info.st_size, 0)),
                mode: info.st_mode,
                inode: UInt64(info.st_ino),
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
            )
        }

        mutating func readData(_ path: String, maximum: Int, code: String) -> Data? {
            guard let info = fileInfo(path) else { return nil }
            guard info.size <= maximum else {
                mark(.fileTooLarge, code: code)
                return nil
            }
            let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                if errno == ELOOP {
                    mark(.unsafePath, code: code)
                } else if errno == EACCES || errno == EPERM {
                    mark(.permissionDenied, code: code)
                } else {
                    mark(.invalidData, code: code)
                }
                return nil
            }
            defer { close(fd) }
            var openedInfo = stat()
            guard fstat(fd, &openedInfo) == 0,
                  (openedInfo.st_mode & S_IFMT) == S_IFREG,
                  openedInfo.st_size >= 0,
                  openedInfo.st_size <= maximum else {
                mark(.invalidData, code: code)
                return nil
            }
            var data = Data()
            data.reserveCapacity(Int(openedInfo.st_size))
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.read(fd, base, raw.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EACCES || errno == EPERM {
                        mark(.permissionDenied, code: code)
                    } else {
                        mark(.invalidData, code: code)
                    }
                    return nil
                }
                if count == 0 { break }
                data.append(buffer, count: count)
                if data.count > maximum {
                    mark(.fileTooLarge, code: code)
                    return nil
                }
            }
            return data
        }

        func report(started: Date, start: ContinuousClock.Instant, clock: ContinuousClock) -> HistoryInspectionReport {
            let duration = start.duration(to: clock.now)
            let components = duration.components
            let milliseconds = Double(components.seconds) * 1000
                + Double(components.attoseconds) / 1_000_000_000_000_000
            let issueList = issues
                .sorted { $0.key < $1.key }
                .map { HistoryInspectionIssue(code: $0.key, count: $0.value) }
            return HistoryInspectionReport(
                status: status,
                format: format,
                inspectedAt: started,
                durationMilliseconds: milliseconds,
                recordCount: recordCount,
                segmentCount: segmentCount,
                journalRecordCount: journalRecordCount,
                earliestTimestamp: earliestTimestamp,
                latestTimestamp: latestTimestamp,
                totalBytes: totalBytes,
                indexBytes: indexBytes,
                segmentBytes: segmentBytes,
                journalBytes: journalBytes,
                clockBytes: clockBytes,
                issues: issueList
            )
        }

        private func fingerprintValue(_ path: String) -> InspectionFingerprint? {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return InspectionFingerprint(
                mode: info.st_mode,
                inode: UInt64(info.st_ino),
                size: Int(max(info.st_size, 0)),
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec)
            )
        }

        private func rank(_ value: HistoryInspectionStatus) -> Int {
            switch value {
            case .permissionDenied: return 12
            case .busy: return 11
            case .changedDuringInspection: return 10
            case .unsafePath: return 9
            case .unsupportedVersion: return 8
            case .missingIndex: return 7
            case .missingSegment: return 7
            case .checksumMismatch: return 7
            case .tornJournal: return 6
            case .invalidData: return 6
            case .fileTooLarge: return 6
            case .legacy: return 4
            case .empty: return 3
            case .healthy: return 2
            }
        }
    }
}
