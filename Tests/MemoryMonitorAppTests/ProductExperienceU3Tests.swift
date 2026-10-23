import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

@MainActor
final class ProductExperienceU3Tests: XCTestCase {
    func testPreviewFreezesAtMostEightAndNeverRefills() {
        let apps = (1...10).map { cleanupApp($0) }
        let inventory = CleanupInventory(observations: apps.map { observation($0) }, metrics: completeMetrics())
        let preview = CleanupPreview(candidates: apps, inventory: inventory, now: 100)

        XCTAssertEqual(preview.candidates.count, 8)
        XCTAssertEqual(preview.selectedApplications.count, 8)
        let removed = preview.candidates[0].id
        let afterRemoval = preview.toggling(removed, at: 110)
        XCTAssertFalse(afterRemoval.selectedIDs.contains(removed))
        XCTAssertEqual(afterRemoval.candidates.count, 8)
        XCTAssertEqual(afterRemoval.selectedApplications.count, 7)
        XCTAssertEqual(afterRemoval.id, preview.id)
    }

    func testPreviewExpiresWithoutBeingTreatedAsAuthorization() {
        let app = cleanupApp(1)
        let preview = CleanupPreview(
            candidates: [app],
            inventory: CleanupInventory(observations: [observation(app)]),
            now: 100
        )
        XCTAssertTrue(preview.isValid(at: 129.9))
        XCTAssertFalse(preview.isValid(at: 130))
        XCTAssertFalse(preview.toggling(app.id, at: 130).selectedIDs.isEmpty)
    }

    func testIncompleteInventoryCannotCreatePreview() async {
        let runtime = FakeCleanupRuntime()
        runtime.inventoryReportValue = CleanupInventory(
            observations: [observation(cleanupApp(1))],
            metrics: CleanupInventoryMetrics(
                generation: 1, scanCount: 1, memberCount: 1, complete: false,
                durationMilliseconds: 10, cancellationLatencyMilliseconds: nil,
                budgetExhausted: true
            )
        )
        let suite = "u3-preview-" + UUID().uuidString
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults)
        controller.refreshApplications()
        await controller.waitUntilRefreshed()
        XCTAssertNil(controller.makePreview())
    }

    func testCompleteInventoryCanCreatePreview() async {
        let runtime = FakeCleanupRuntime()
        let app = cleanupApp(1)
        runtime.inventoryReportValue = CleanupInventory(
            observations: [observation(app)],
            metrics: completeMetrics()
        )
        let suite = "u3-preview-complete-" + UUID().uuidString
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults)
        controller.setAuthorized(app, true)
        controller.refreshApplications()
        await controller.waitUntilRefreshed()
        let preview = controller.makePreview(now: 100)
        XCTAssertEqual(preview?.candidates.map(\.id), [app.id])
    }

    func testExpiredPreviewCannotStartAtControllerBoundary() async {
        let runtime = FakeCleanupRuntime()
        let app = cleanupApp(1)
        runtime.observations = [observation(app)]
        runtime.inventoryReportValue = CleanupInventory(
            observations: [observation(app)],
            metrics: completeMetrics()
        )
        let suite = "u3-preview-expiry-" + UUID().uuidString
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults)
        controller.setAuthorized(app, true)
        controller.refreshApplications()
        await controller.waitUntilRefreshed()
        let preview = try! XCTUnwrap(controller.makePreview(now: 100))
        runtime.now = 131
        controller.start(preview: preview)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertTrue(controller.notice?.contains("过期") == true)
    }

    func testCancelInvalidatesPreviewBeforeConfirmation() async {
        let runtime = FakeCleanupRuntime()
        let app = cleanupApp(1)
        runtime.observations = [observation(app)]
        runtime.inventoryReportValue = CleanupInventory(
            observations: [observation(app)],
            metrics: completeMetrics()
        )
        let suite = "u3-preview-cancel-" + UUID().uuidString
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults)
        controller.setAuthorized(app, true)
        controller.refreshApplications()
        await controller.waitUntilRefreshed()
        let preview = try! XCTUnwrap(controller.makePreview(now: 100))
        controller.cancel()
        controller.start(preview: preview)
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertTrue(controller.notice?.contains("失效") == true)
    }

    private func completeMetrics() -> CleanupInventoryMetrics {
        CleanupInventoryMetrics(
            generation: 1, scanCount: 1, memberCount: 1, complete: true,
            durationMilliseconds: 10, cancellationLatencyMilliseconds: nil,
            budgetExhausted: false
        )
    }
}
