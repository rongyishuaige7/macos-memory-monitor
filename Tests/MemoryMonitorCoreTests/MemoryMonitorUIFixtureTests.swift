import Foundation
import XCTest
@testable import MemoryMonitorCore

final class MemoryMonitorUIFixtureTests: XCTestCase {
    func testFixtureEnvironmentRequiresExplicitOne() {
        XCTAssertTrue(
            MemoryMonitorUIFixture.isEnabled(
                environment: [MemoryMonitorUIFixture.environmentKey: "1"]
            )
        )
        for value in [nil, "", "0", "true", " 1 "] as [String?] {
            var environment: [String: String] = [:]
            if let value {
                environment[MemoryMonitorUIFixture.environmentKey] = value
            }
            XCTAssertFalse(MemoryMonitorUIFixture.isEnabled(environment: environment))
        }
    }

    func testFixtureContainsStableMultipleMembersAndSafeTargets() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)
        let dataset = MemoryMonitorUIFixture.makeDataset(now: referenceDate)

        XCTAssertEqual(dataset.snapshot.groups.count, 2)
        XCTAssertEqual(dataset.snapshot.processes.count, 7)
        XCTAssertEqual(dataset.historyRecords.count, 240)
        XCTAssertEqual(dataset.auditEvents.count, 12)

        let processIDs = Set(dataset.snapshot.processes.map(\.identity))
        for group in dataset.snapshot.groups {
            XCTAssertGreaterThanOrEqual(group.processCount, 3)
            XCTAssertEqual(group.memberProcessIdentities.count, group.processCount)
            XCTAssertTrue(Set(group.memberProcessIdentities).isSubset(of: processIDs))
        }
        XCTAssertTrue(dataset.snapshot.processDataIsUsable)
        XCTAssertTrue(dataset.snapshot.processes.allSatisfy { $0.executablePath == nil })
        XCTAssertTrue(dataset.snapshot.processes.allSatisfy {
            $0.name.count <= WorkingDirectoryLabelSanitizer.maxLength
        })
    }

    func testFixtureRetimestampsWithoutChangingSelectionIdentities() throws {
        let dataset = MemoryMonitorUIFixture.makeDataset(
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let later = Date(timeIntervalSince1970: 1_750_000_123)
        let first = dataset.snapshot(at: later)

        XCTAssertEqual(first.timestamp, later)
        XCTAssertEqual(first.system?.timestamp, later)
        XCTAssertEqual(first.systemStatus.sampledAt, later)
        XCTAssertEqual(first.processStatus.sampledAt, later)
        XCTAssertEqual(
            first.processes.map(\.identity),
            dataset.snapshot.processes.map(\.identity)
        )
        XCTAssertEqual(first.groups, dataset.snapshot.groups)
        XCTAssertTrue(first.processDataIsUsable)
    }

    func testFixtureHistoryProducesMultipleExplainableEvents() {
        let dataset = MemoryMonitorUIFixture.makeDataset(
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let analysis = MemoryHistoryAnalyzer().analyze(dataset.historyRecords)
        let kinds = Set(analysis.events.map(\.kind))

        XCTAssertTrue(kinds.contains(.workloadAppeared))
        XCTAssertTrue(kinds.contains(.workloadDisappeared))
        XCTAssertTrue(kinds.contains(.workloadGrowth))
        XCTAssertTrue(kinds.contains(.pressureTransition))
        XCTAssertGreaterThan(analysis.events.count, 3)
    }

    func testFixtureAuditEventsStayWithinPersistedLimits() {
        let dataset = MemoryMonitorUIFixture.makeDataset(
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )
        XCTAssertTrue(dataset.auditEvents.allSatisfy { $0.id.count <= 80 })
        XCTAssertTrue(dataset.auditEvents.allSatisfy { $0.detail.count <= 240 })
        XCTAssertEqual(
            Set(dataset.auditEvents.map(\.id)).count,
            dataset.auditEvents.count
        )
        XCTAssertTrue(dataset.auditEvents.allSatisfy { $0.hasValidFixtureFields })
    }
}

private extension ProcessActionAuditEvent {
    /// Tests cannot access the store's fileprivate validation helper; these
    /// checks cover the public invariants that the fixture writer relies on.
    var hasValidFixtureFields: Bool {
        !id.isEmpty
            && !operationID.isEmpty
            && timestamp.timeIntervalSince1970.isFinite
            && !processLabel.isEmpty
            && !detail.isEmpty
    }
}
