import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

final class ProductExperienceU2Tests: XCTestCase {
    func testNormalPressureKeepsInspectionPrimary() {
        let decision = MonitorStatusProjection.overview(
            usable: true,
            level: .normal,
            sampleAt: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(decision.status.tone, .normal)
        XCTAssertEqual(decision.primaryDestination, .processes)
        XCTAssertEqual(decision.secondaryDestination, .cleanup)
        XCTAssertTrue(decision.sampleTime.contains("有效时间"))
    }

    func testPressureAndUnavailableStatesShareDecisionWithMenu() {
        for level in [MemoryPressureLevel.attention, .critical] {
            let decision = MonitorStatusProjection.overview(
                usable: true, level: level, sampleAt: Date(timeIntervalSince1970: 100)
            )
            XCTAssertEqual(decision.primaryDestination, .processes)
            XCTAssertEqual(decision.secondaryDestination, .cleanup)
            XCTAssertNotEqual(decision.status.tone, .normal)
        }
        let unavailable = MonitorStatusProjection.overview(
            usable: false, level: .normal, sampleAt: nil
        )
        XCTAssertEqual(unavailable.primaryDestination, .retry)
        XCTAssertNil(unavailable.secondaryDestination)
        XCTAssertEqual(unavailable.status.tone, .loading)
        XCTAssertEqual(unavailable.sampleTime, "尚未获得有效样本")
    }

    func testSampleTimeIsAbsentRatherThanInvented() {
        XCTAssertEqual(MonitorStatusProjection.sampleTimeText(nil), "尚未获得有效样本")
        XCTAssertEqual(
            MonitorStatusProjection.sampleTimeText(Date(timeIntervalSince1970: .nan)),
            "尚未获得有效样本"
        )
    }
}
