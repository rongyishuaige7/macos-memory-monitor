import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

final class ProductExperienceU7Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testVisibleSurfacesMergeToFastestDemand() {
        let policy = AdaptiveSamplingPolicy()
        XCTAssertEqual(
            policy.intervalSeconds(surfaces: [.processes, .history], pressureActive: false),
            3
        )
        XCTAssertEqual(
            policy.intervalSeconds(surfaces: [.overview, .history], pressureActive: false),
            3
        )
        XCTAssertEqual(
            policy.intervalSeconds(surfaces: [.menu, .history], pressureActive: false),
            3
        )
        XCTAssertEqual(
            policy.intervalSeconds(surfaces: [.history], pressureActive: false),
            20
        )
        XCTAssertEqual(
            policy.intervalSeconds(surfaces: [], pressureActive: false),
            20
        )
    }

    func testPressureMergesWithVisibleDemandWithoutRaisingIt() {
        let policy = AdaptiveSamplingPolicy()
        XCTAssertEqual(
            policy.intervalSeconds(surfaces: [.history], pressureActive: true),
            5
        )
        XCTAssertEqual(
            policy.intervalSeconds(surfaces: [.processes], pressureActive: true),
            3
        )
        XCTAssertEqual(
            policy.samplingMode(
                surfaces: [.processes], pressureActive: true,
                now: now, lastProcessSampleAt: now
            ),
            .panel
        )
    }

    func testSparseSurfacesDoNotScanProcessesEveryThreeSeconds() {
        let policy = AdaptiveSamplingPolicy()
        XCTAssertEqual(
            policy.samplingMode(
                surfaces: [.history], pressureActive: false,
                now: now, lastProcessSampleAt: now.addingTimeInterval(-10)
            ),
            .background
        )
        XCTAssertEqual(
            policy.samplingMode(
                surfaces: [.history], pressureActive: false,
                now: now, lastProcessSampleAt: now.addingTimeInterval(-61)
            ),
            .backgroundProcess
        )
        XCTAssertEqual(
            policy.samplingMode(
                surfaces: [.menu], pressureActive: false,
                now: now, lastProcessSampleAt: now.addingTimeInterval(-16)
            ),
            .backgroundProcess
        )
    }

    @MainActor
    func testClosingOneSurfaceKeepsAnotherConsumerRegistered() async {
        let model = MonitorViewModel(
            historyStore: makeTemporaryHistoryStore("u7-surface-history"),
            processActions: makeTemporaryProcessActions("u7-surface-actions"),
            startRefreshTask: false
        )
        model.setDesktopPresented(true)
        model.setDesktopSurface(.history, detail: false)
        model.setPanelPresented(true)
        XCTAssertTrue(model.isPanelPresented)
        model.setPanelPresented(false)
        XCTAssertTrue(model.isPanelPresented)
        model.setDesktopPresented(false)
        XCTAssertFalse(model.isPanelPresented)
        await model.shutdown()
    }
}
