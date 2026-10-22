import CryptoKit
import Foundation
import XCTest
@testable import MemoryMonitorCore

final class StorageRestoreTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var backup: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageRestoreTests-" + UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("data", isDirectory: true)
        backup = base.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for directory in [backup, root] {
            guard let directory else { continue }
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.appendingPathComponent("data").path
            )
        }
        try? FileManager.default.removeItem(at: base)
    }

    private func write(_ value: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    private func makeBackup() throws {
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
        try Data("audit".utf8).write(to: root.appendingPathComponent("actions.jsonl"))
        try Data("audit-clock".utf8).write(to: root.appendingPathComponent("actions.jsonl.clock"))
        _ = try StorageBackup.create(root: root, output: backup)
    }

    func testRestoreReplacesV1SetAndRemovesSegments() throws {
        try makeBackup()
        let historyBefore = try Data(contentsOf: backup.appendingPathComponent("data/history.json"))

        try write("mutated", to: "history.json")
        try write("mutated-audit", to: "actions.jsonl")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("history.json.segments"),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(
            to: root.appendingPathComponent("history.json.segments/segment-stale.json")
        )

        let result = try StorageRestore.restore(backupDirectory: backup, root: root)
        XCTAssertEqual(result.restoredFiles, 5)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("history.json")),
            historyBefore
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("actions.jsonl")),
            Data("audit".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("history.json.segments").path)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: MaintenanceTransaction.url(root: root).path))
    }

    func testRestoreV2SetReplacesV1AndInstallsSegments() throws {
        let record = MemoryHistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.5,
            compressedBytes: 1,
            swapUsedBytes: 2,
            workloads: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let segmentData = try encoder.encode(MemoryHistoryFile(records: [record]))
        let digest = SHA256.hash(data: segmentData).map { String(format: "%02x", $0) }.joined()
        let bucket = Int64(floor(record.timestamp.timeIntervalSince1970 / 900))
        let segmentName = "segment-\(bucket)-\(digest).json"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("history.json.segments"),
            withIntermediateDirectories: true
        )
        try segmentData.write(
            to: root.appendingPathComponent("history.json.segments/" + segmentName)
        )
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
            records: [],
            segments: [Reference(bucket: bucket, digest: digest)]
        )
        try encoder.encode(index).write(to: root.appendingPathComponent("history.json"))
        try Data("audit".utf8).write(to: root.appendingPathComponent("actions.jsonl"))
        _ = try StorageBackup.create(root: root, output: backup)
        let indexBefore = try Data(contentsOf: backup.appendingPathComponent("data/history.json"))

        try write("v1-after-backup", to: "history.json")
        try FileManager.default.removeItem(at: root.appendingPathComponent("history.json.segments"))

        let result = try StorageRestore.restore(backupDirectory: backup, root: root)
        XCTAssertGreaterThanOrEqual(result.restoredFiles, 2)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("history.json")),
            indexBefore
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("history.json.segments/" + segmentName).path
            )
        )
    }

    func testRestoreRejectsTamperedBackupWithoutChangingRoot() throws {
        try makeBackup()
        try write("current", to: "history.json")
        let tampered = backup.appendingPathComponent("data/actions.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tampered.path)
        try Data("tampered".utf8).write(to: tampered)

        XCTAssertThrowsError(try StorageRestore.restore(backupDirectory: backup, root: root)) { error in
            guard case StorageRestoreError.invalidBackup = error else {
                return XCTFail("expected invalidBackup, got \(error)")
            }
        }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("history.json"), encoding: .utf8),
            "current"
        )
    }

    func testRecoverRollsBackPreparedTransaction() throws {
        try write("current", to: "history.json")
        let currentBackup = root.appendingPathComponent(".restore-current", isDirectory: true)
        let stage = root.appendingPathComponent(".restore-stage", isDirectory: true)
        try FileManager.default.createDirectory(at: currentBackup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("previous".utf8).write(to: currentBackup.appendingPathComponent("history.json"))

        struct Marker: Codable {
            let schemaVersion: Int
            let id: String
            let createdAt: Date
            let phase: String
            let currentBackup: String
            let stage: String
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let marker = Marker(
            schemaVersion: 1,
            id: "test",
            createdAt: Date(timeIntervalSince1970: 1),
            phase: "prepared",
            currentBackup: currentBackup.path,
            stage: stage.path
        )
        try encoder.encode(marker).write(to: MaintenanceTransaction.url(root: root))

        let result = try StorageRestore.recover(root: root)
        XCTAssertTrue(result.previousDataRetained)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("history.json"), encoding: .utf8),
            "previous"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: MaintenanceTransaction.url(root: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: currentBackup.path))
    }

    func testRestoreRefusesPendingTransaction() throws {
        try makeBackup()
        try Data("{}".utf8).write(to: MaintenanceTransaction.url(root: root))
        XCTAssertThrowsError(try StorageRestore.restore(backupDirectory: backup, root: root)) { error in
            guard case StorageRestoreError.transactionPending = error else {
                return XCTFail("expected transactionPending, got \(error)")
            }
        }
    }
}
