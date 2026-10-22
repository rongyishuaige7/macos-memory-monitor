import CryptoKit
import Darwin
import XCTest
@testable import MemoryMonitorCore

final class HistoryInspectionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryInspectionTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private var historyURL: URL { root.appendingPathComponent("history.json") }
    private var segmentsURL: URL { root.appendingPathComponent("history.json.segments") }
    private var journalURL: URL { root.appendingPathComponent("history.json.journal") }

    private func record(at seconds: TimeInterval = 1_700_000_000) -> MemoryHistoryRecord {
        MemoryHistoryRecord(
            timestamp: Date(timeIntervalSince1970: seconds),
            availableFraction: 0.42,
            compressedBytes: 1_024,
            swapUsedBytes: 2_048,
            workloads: []
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(format.format(date))
        }
        return encoder
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func writeV2Index(
        records: [MemoryHistoryRecord],
        references: [(bucket: Int64, digest: String)]
    ) throws {
        struct Reference: Codable {
            let bucket: Int64
            let digest: String
        }
        struct Index: Codable {
            let version: Int
            let records: [MemoryHistoryRecord]
            let segments: [Reference]
        }
        let index = Index(
            version: 2,
            records: records,
            segments: references.map { Reference(bucket: $0.bucket, digest: $0.digest) }
        )
        try write(try encoder().encode(index), to: historyURL)
    }

    private func writeSegment(
        _ record: MemoryHistoryRecord,
        bucket: Int64
    ) throws -> (bucket: Int64, digest: String) {
        let data = try encoder().encode(MemoryHistoryFile(records: [record]))
        let digestValue = sha256Hex(data)
        try write(data, to: segmentsURL.appendingPathComponent("segment-\(bucket)-\(digestValue).json"))
        return (bucket, digestValue)
    }

    func testEmptyStoreIsClassifiedWithoutMutation() throws {
        let before = try snapshot()
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .empty)
        XCTAssertEqual(report.format, .empty)
        XCTAssertEqual(report.recordCount, 0)
        XCTAssertEqual(try snapshot(), before)
    }

    func testLegacyV1StoreIsReadable() throws {
        let record = record()
        try write(try encoder().encode(MemoryHistoryFile(records: [record])), to: historyURL)
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .legacy)
        XCTAssertEqual(report.format, .legacyV1)
        XCTAssertEqual(report.recordCount, 1)
        XCTAssertEqual(report.earliestTimestamp, record.timestamp)
        XCTAssertEqual(report.latestTimestamp, record.timestamp)
    }

    func testSegmentedV2StoreIsHealthy() throws {
        let record = record()
        let bucket = Int64(floor(record.timestamp.timeIntervalSince1970 / 900))
        let reference = try writeSegment(record, bucket: bucket)
        try writeV2Index(records: [], references: [reference])

        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .healthy)
        XCTAssertEqual(report.format, .segmentedV2)
        XCTAssertEqual(report.recordCount, 1)
        XCTAssertEqual(report.segmentCount, 1)
        XCTAssertEqual(report.earliestTimestamp, record.timestamp)
        XCTAssertEqual(report.latestTimestamp, record.timestamp)
    }

    func testMissingIndexWithSegmentsIsClassified() throws {
        try FileManager.default.createDirectory(at: segmentsURL, withIntermediateDirectories: true)
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .missingIndex)
    }

    func testEmptyV2WithoutSegmentsDirectoryIsNotHealthy() throws {
        try writeV2Index(records: [], references: [])
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .missingSegment)
    }

    func testSymlinkedSegmentsDirectoryIsUnsafe() throws {
        let external = root.deletingLastPathComponent()
            .appendingPathComponent("HistoryInspectionExternal-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(at: segmentsURL, withDestinationURL: external)
        try writeV2Index(records: [], references: [])
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .unsafePath)
    }

    func testMissingSegmentIsClassified() throws {
        let record = record()
        let bucket = Int64(floor(record.timestamp.timeIntervalSince1970 / 900))
        try writeV2Index(records: [], references: [(bucket, String(repeating: "a", count: 64))])
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .missingSegment)
        XCTAssertEqual(report.segmentCount, 0)
    }

    func testChecksumMismatchIsClassified() throws {
        let record = record()
        let bucket = Int64(floor(record.timestamp.timeIntervalSince1970 / 900))
        let reference = try writeSegment(record, bucket: bucket)
        try writeV2Index(records: [], references: [reference])
        let segmentURL = segmentsURL.appendingPathComponent("segment-\(reference.bucket)-\(reference.digest).json")
        try write(Data("{}".utf8), to: segmentURL)

        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .checksumMismatch)
        XCTAssertEqual(report.segmentCount, 0)
    }

    func testTornJournalIsClassified() throws {
        try write(Data("{\"timestamp\":\"2026-".utf8), to: journalURL)
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .tornJournal)
        XCTAssertEqual(report.journalRecordCount, 0)
    }

    func testUnsupportedVersionIsClassified() throws {
        try write(Data("{\"version\":3,\"records\":[]}".utf8), to: historyURL)
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .unsupportedVersion)
    }

    func testSymlinkRootIsRejected() throws {
        let link = root.appendingPathComponent("linked-history")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let report = HistoryInspector.inspect(root: link)
        XCTAssertEqual(report.status, .unsafePath)
    }

    func testUnreadableIndexIsClassifiedAsPermissionDenied() throws {
        try write(try encoder().encode(MemoryHistoryFile(records: [record()])), to: historyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: historyURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: historyURL.path)
        }
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .permissionDenied)
    }

    func testBusyLockIsClassified() throws {
        let lockURL = root.appendingPathComponent("history.json.lock")
        try Data().write(to: lockURL)
        let fd = open(lockURL.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer {
            if fd >= 0 {
                _ = flock(fd, LOCK_UN)
                close(fd)
            }
        }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let report = HistoryInspector.inspect(root: root)
        XCTAssertEqual(report.status, .busy)
    }

    private func snapshot() throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let values = [
                String(describing: attributes[.size] ?? ""),
                String(describing: attributes[.modificationDate] ?? ""),
                String(describing: attributes[.posixPermissions] ?? "")
            ].joined(separator: "|")
            result[url.path] = values
        }
        return result
    }
}
