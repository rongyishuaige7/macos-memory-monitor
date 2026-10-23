import XCTest
@testable import MemoryMonitorCore

final class AuditOperationProjectionTests: XCTestCase {
    private func event(
        _ id: String,
        operationID: String,
        phase: ProcessActionAuditPhase,
        outcome: ProcessActionOutcome,
        timestamp: TimeInterval,
        label: String = "worker"
    ) -> ProcessActionAuditEvent {
        ProcessActionAuditEvent(
            id: id,
            operationID: operationID,
            timestamp: Date(timeIntervalSince1970: timestamp),
            action: .gracefulExit,
            phase: phase,
            outcome: outcome,
            processLabel: label,
            detail: "detail"
        )
    }

    func testIntentOnlyIsNotReportedAsSuccess() {
        let projection = AuditOperationProjector.project(
            events: [event("i", operationID: "op", phase: .intent, outcome: .completed, timestamp: 1)],
            activeOperationIDs: []
        ).first

        XCTAssertEqual(projection?.state, .intentRecorded)
        XCTAssertFalse(projection?.hasTerminal == true)
        XCTAssertFalse(projection?.isIncomplete == true)
    }

    func testActiveIntentIsInProgress() {
        let projection = AuditOperationProjector.project(
            events: [event("i", operationID: "op", phase: .intent, outcome: .completed, timestamp: 1)],
            activeOperationIDs: ["op"]
        ).first

        XCTAssertEqual(projection?.state, .inProgress)
    }

    func testSignalWithoutIntentIsIncompleteAndUnconfirmed() {
        let projection = AuditOperationProjector.project(
            events: [event("s", operationID: "op", phase: .signalSent, outcome: .completed, timestamp: 2)],
            activeOperationIDs: []
        ).first

        XCTAssertEqual(projection?.state, .requestSentUnconfirmed)
        XCTAssertTrue(projection?.isIncomplete == true)
        XCTAssertFalse(projection?.hasTerminal == true)
    }

    func testIntentAndSignalWithoutTerminalRemainUnconfirmed() {
        let projection = AuditOperationProjector.project(
            events: [
                event("i", operationID: "op", phase: .intent, outcome: .completed, timestamp: 1),
                event("s", operationID: "op", phase: .signalSent, outcome: .completed, timestamp: 2)
            ],
            activeOperationIDs: []
        ).first

        XCTAssertEqual(projection?.state, .requestSentUnconfirmed)
        XCTAssertFalse(projection?.isIncomplete == true)
        XCTAssertFalse(projection?.hasTerminal == true)
    }

    func testTerminalOnlyLegacyRecordIsNotIncomplete() {
        let projection = AuditOperationProjector.project(
            events: [event("t", operationID: "t", phase: .terminal, outcome: .completed, timestamp: 3)],
            activeOperationIDs: []
        ).first

        XCTAssertEqual(projection?.state, .completed)
        XCTAssertTrue(projection?.isLegacyTerminalOnly == true)
        XCTAssertFalse(projection?.isIncomplete == true)
    }

    func testTerminalOnlyNewOperationIsIncompleteNotLegacy() {
        let projection = AuditOperationProjector.project(
            events: [event("terminal-new", operationID: "op-new", phase: .terminal, outcome: .completed, timestamp: 3)],
            activeOperationIDs: []
        ).first

        XCTAssertEqual(projection?.state, .completed)
        XCTAssertFalse(projection?.isLegacyTerminalOnly == true)
        XCTAssertTrue(projection?.isIncomplete == true)
    }

    func testTerminalWithTrimmedIntentIsIncompleteButDecisive() {
        let projection = AuditOperationProjector.project(
            events: [
                event("s", operationID: "op", phase: .signalSent, outcome: .completed, timestamp: 2),
                event("t", operationID: "op", phase: .terminal, outcome: .completed, timestamp: 3)
            ],
            activeOperationIDs: []
        ).first

        XCTAssertEqual(projection?.state, .completed)
        XCTAssertTrue(projection?.isIncomplete == true)
        XCTAssertFalse(projection?.isLegacyTerminalOnly == true)
    }

    func testDuplicateEventsAreCountedWithoutChangingState() {
        let duplicate = event("i", operationID: "op", phase: .intent, outcome: .completed, timestamp: 1)
        let projection = AuditOperationProjector.project(
            events: [duplicate, duplicate],
            activeOperationIDs: []
        ).first

        XCTAssertEqual(projection?.eventCount, 2)
        XCTAssertEqual(projection?.state, .intentRecorded)
    }

    func testProjectionSortsNewestFirstAndKeepsPrivacyFields() {
        let older = event("i1", operationID: "older", phase: .intent, outcome: .completed, timestamp: 1)
        let newer = event("t2", operationID: "newer", phase: .terminal, outcome: .completed, timestamp: 2)
        let projections = AuditOperationProjector.project(
            events: [older, newer],
            activeOperationIDs: []
        )

        XCTAssertEqual(projections.map(\.id), ["newer", "older"])
        XCTAssertEqual(projections.first?.processLabel, "worker")
        XCTAssertNil(projections.first?.applicationName)
    }
}
