import Foundation
import XCTest
@testable import MemoryMonitorCore

final class MaintenanceLockTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MaintenanceLockTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSharedLocksCoexistAndExclusiveBlocks() throws {
        let shared = try MaintenanceLock.acquire(root: root, mode: .shared, timeoutSeconds: 0.1)
        defer { MaintenanceLock.release(shared) }
        XCTAssertThrowsError(
            try MaintenanceLock.acquire(root: root, mode: .exclusive, timeoutSeconds: 0.05)
        ) { error in
            guard case MaintenanceLockError.timedOut = error else {
                return XCTFail("expected timedOut, got \(error)")
            }
        }
    }

    func testHistoryStoreWaitsForMaintenanceLock() async throws {
        let historyURL = root.appendingPathComponent("history.json")
        let exclusive = try MaintenanceLock.acquire(root: root, mode: .exclusive, timeoutSeconds: 0.1)
        let store = HistoryStore(fileURL: historyURL, lockTimeoutSeconds: 0.05)
        do {
            _ = try await store.load()
            XCTFail("expected lockTimedOut")
        } catch {
            XCTAssertEqual(error as? HistoryStoreError, .lockTimedOut)
        }
        MaintenanceLock.release(exclusive)
        _ = try await store.load()
    }

    func testAuditStoreWaitsForMaintenanceLock() async throws {
        let auditURL = root.appendingPathComponent("actions.jsonl")
        let exclusive = try MaintenanceLock.acquire(root: root, mode: .exclusive, timeoutSeconds: 0.1)
        let store = ProcessActionAuditStore(fileURL: auditURL, lockTimeoutSeconds: 0.05)
        do {
            _ = try await store.load()
            XCTFail("expected lockTimedOut")
        } catch {
            XCTAssertEqual(error as? ProcessActionAuditStoreError, .lockTimedOut)
        }
        MaintenanceLock.release(exclusive)
        _ = try await store.load()
    }

    func testUnfinishedTransactionBlocksStores() async throws {
        let marker = MaintenanceTransaction.url(root: root)
        try Data("{}".utf8).write(to: marker)
        let history = HistoryStore(
            fileURL: root.appendingPathComponent("history.json"),
            lockTimeoutSeconds: 0.05
        )
        do {
            _ = try await history.load()
            XCTFail("expected history recoveryRequired")
        } catch {
            XCTAssertEqual(error as? HistoryStoreError, .recoveryRequired)
        }
        let audit = ProcessActionAuditStore(
            fileURL: root.appendingPathComponent("actions.jsonl"),
            lockTimeoutSeconds: 0.05
        )
        do {
            _ = try await audit.load()
            XCTFail("expected audit recoveryRequired")
        } catch {
            XCTAssertEqual(error as? ProcessActionAuditStoreError, .recoveryRequired)
        }
    }
}
