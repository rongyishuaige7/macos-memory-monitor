import Foundation
import XCTest
@testable import MemoryMonitorCore

final class StorageBackupTests: XCTestCase {
    private var root: URL!
    private var output: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageBackupTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("data", isDirectory: true)
        output = base.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: output.path)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: output.appendingPathComponent("data").path
        )
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func writeV1() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = MemoryHistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.5,
            compressedBytes: 1,
            swapUsedBytes: 2,
            workloads: []
        )
        try encoder.encode(MemoryHistoryFile(records: [record]))
            .write(to: root.appendingPathComponent("history.json"))
        try Data().write(to: root.appendingPathComponent("history.json.journal"))
        try Data("{\"observedAt\":\"2026-10-22T00:00:00Z\"}".utf8)
            .write(to: root.appendingPathComponent("history.json.clock"))
        try Data().write(to: root.appendingPathComponent("actions.jsonl"))
        try Data("audit-clock".utf8).write(to: root.appendingPathComponent("actions.jsonl.clock"))
    }

    func testBackupCopiesKnownFilesAndMarksMissingSegments() throws {
        try writeV1()
        let manifest = try StorageBackup.create(root: root, output: output)

        XCTAssertTrue(manifest.restorable)
        XCTAssertEqual(manifest.historyStatus, .legacy)
        XCTAssertEqual(manifest.format, .legacyV1)
        XCTAssertTrue(manifest.files.contains { $0.role == "historyIndex" && $0.present })
        XCTAssertTrue(manifest.files.contains { $0.role == "audit" && $0.present })
        XCTAssertTrue(manifest.files.contains { $0.role == "historySegmentsDirectory" && !$0.present })
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("backup.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("data/history.json").path))
        let mode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o500)
    }

    func testBackupRefusesExistingOutputAndInsideRoot() throws {
        try writeV1()
        _ = try StorageBackup.create(root: root, output: output)
        XCTAssertThrowsError(try StorageBackup.create(root: root, output: output)) { error in
            guard case StorageBackupError.outputExists = error else {
                return XCTFail("expected outputExists, got \(error)")
            }
        }

        let inside = root.appendingPathComponent("inside", isDirectory: true)
        XCTAssertThrowsError(try StorageBackup.create(root: root, output: inside)) { error in
            guard case StorageBackupError.outputInsideRoot = error else {
                return XCTFail("expected outputInsideRoot, got \(error)")
            }
        }
    }

    func testCorruptHistoryIsBackedUpButNotRestorable() throws {
        try Data("not-json".utf8).write(to: root.appendingPathComponent("history.json"))
        let manifest = try StorageBackup.create(root: root, output: output)
        XCTAssertFalse(manifest.restorable)
        XCTAssertEqual(manifest.historyStatus, .invalidData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("data/history.json").path))
    }

    func testCorruptAuditIsBackedUpButNotRestorable() throws {
        try writeV1()
        try Data("not-json\n".utf8).write(to: root.appendingPathComponent("actions.jsonl"))
        let manifest = try StorageBackup.create(root: root, output: output)
        XCTAssertFalse(manifest.restorable)
        XCTAssertTrue(manifest.files.contains { $0.role == "audit" && $0.present })
    }

    func testMissingAuditIsStillRestorable() throws {
        try writeV1()
        try FileManager.default.removeItem(at: root.appendingPathComponent("actions.jsonl"))
        let manifest = try StorageBackup.create(root: root, output: output)
        XCTAssertTrue(manifest.restorable)
        XCTAssertTrue(manifest.files.contains { $0.role == "audit" && !$0.present })
    }

    func testOversizedAuditIsNotRestorable() throws {
        try writeV1()
        let auditURL = root.appendingPathComponent("actions.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auditURL.path)
        try Data(repeating: 0x0A, count: ProcessActionAuditStore.maximumFileBytes + 1)
            .write(to: auditURL)
        let manifest = try StorageBackup.create(root: root, output: output)
        XCTAssertFalse(manifest.restorable)
        XCTAssertTrue(manifest.files.contains { $0.role == "audit" && $0.present })
    }

    func testSymlinkedSegmentIsRejected() throws {
        try writeV1()
        let segments = root.appendingPathComponent("history.json.segments", isDirectory: true)
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let external = root.deletingLastPathComponent().appendingPathComponent("external.json")
        try Data("{}".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(
            at: segments.appendingPathComponent("segment.json"),
            withDestinationURL: external
        )
        XCTAssertThrowsError(try StorageBackup.create(root: root, output: output)) { error in
            guard case StorageBackupError.invalidPath = error else {
                return XCTFail("expected invalidPath, got \(error)")
            }
        }
    }

    func testBackupRefusesUnfinishedRestoreTransaction() throws {
        try writeV1()
        try Data("{}".utf8).write(to: MaintenanceTransaction.url(root: root))
        XCTAssertThrowsError(try StorageBackup.create(root: root, output: output)) { error in
            guard case StorageBackupError.unsupportedData = error else {
                return XCTFail("expected unsupportedData, got \(error)")
            }
        }
    }

    func testSourceDataIsNotChangedByBackup() throws {
        try writeV1()
        let historyBefore = try Data(contentsOf: root.appendingPathComponent("history.json"))
        let auditBefore = try Data(contentsOf: root.appendingPathComponent("actions.jsonl"))
        _ = try StorageBackup.create(root: root, output: output)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("history.json")), historyBefore)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("actions.jsonl")), auditBefore)
    }
}
