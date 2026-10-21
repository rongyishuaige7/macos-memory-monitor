import Foundation
import MemoryMonitorCore
import XCTest
@testable import MemoryMonitorApp

/// Shared test-only storage helpers.
///
/// `MonitorViewModel` deliberately requires explicit stores so a test cannot
/// accidentally append to the user's real Application Support history or
/// action audit. Every model created in this test target must use one of these
/// helpers (or its own temporary URL).
@MainActor
extension XCTestCase {
    func makeTemporaryHistoryStore(
        _ label: String = "history"
    ) -> HistoryStore {
        let root = makeTemporaryStoreRoot(label)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return HistoryStore(fileURL: root.appendingPathComponent("history.json"))
    }

    func makeTemporaryProcessActions(
        _ label: String = "actions"
    ) -> ProcessActionController {
        let root = makeTemporaryStoreRoot(label)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return ProcessActionController(
            auditStore: ProcessActionAuditStore(
                fileURL: root.appendingPathComponent("actions.jsonl")
            )
        )
    }

    private func makeTemporaryStoreRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "memory-monitor-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
