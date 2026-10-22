import XCTest
@testable import MemoryMonitorCore

final class ProcessScanBudgetTests: XCTestCase {
    func testExpiredBudgetIsRejectedBeforeScanning() {
        let budget = ProcessScanBudget(
            deadline: ContinuousClock.now.advanced(by: .seconds(-1)),
            maximumMembers: 100
        )
        XCTAssertThrowsError(try ProcessSampler().sampleDetailed(budget: budget)) { error in
            XCTAssertEqual(error as? ProcessScanBudgetError, .budgetExhausted)
        }
    }

    func testMemberLimitIsEnforcedBeforeProcessReads() {
        let budget = ProcessScanBudget(
            deadline: ContinuousClock.now.advanced(by: .seconds(5)),
            maximumMembers: 1
        )
        XCTAssertThrowsError(try ProcessSampler().sampleDetailed(budget: budget)) { error in
            XCTAssertEqual(error as? ProcessScanBudgetError, .memberLimit)
        }
    }

    func testExpiredBudgetStopsDescendantEnumeration() {
        let budget = ProcessScanBudget(
            deadline: ContinuousClock.now.advanced(by: .seconds(-1)),
            maximumMembers: 10
        )
        XCTAssertThrowsError(
            try ProcessSampler().descendantProcessIDs(of: Int32(getpid()), budget: budget)
        ) { error in
            XCTAssertEqual(error as? ProcessScanBudgetError, .budgetExhausted)
        }
    }
}
