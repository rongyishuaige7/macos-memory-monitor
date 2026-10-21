import AppKit
import XCTest
@testable import MemoryMonitorApp

@MainActor
final class DesktopWindowTests: XCTestCase {
    func testClosingPopoverKeepsDesktopSamplingActive() async {
        let model = MonitorViewModel(
            historyStore: makeTemporaryHistoryStore("desktop-window-history"),
            processActions: makeTemporaryProcessActions("desktop-window-actions"),
            startRefreshTask: false
        )
        model.setDesktopPresented(true)
        model.setPanelPresented(true)
        model.setPanelPresented(false)
        XCTAssertTrue(model.isPanelPresented)
        model.setDesktopPresented(false)
        XCTAssertFalse(model.isPanelPresented)
        model.setPanelPresented(true)
        model.setDesktopPresented(true)
        model.setDesktopPresented(false)
        XCTAssertTrue(model.isPanelPresented)
        await model.shutdown()
    }

    func testSettingsWindowSurvivesPopoverDismissalAndReusesWindow() async throws {
        let model = MonitorViewModel(
            historyStore: makeTemporaryHistoryStore("desktop-window-settings-history"),
            processActions: makeTemporaryProcessActions("desktop-window-settings-actions"),
            startRefreshTask: false
        )
        let coordinator = DesktopWindowCoordinator(model: model)
        coordinator.show(.settings)
        let window = try XCTUnwrap(coordinator.window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.hidesOnDeactivate)
        XCTAssertNil(window.sheetParent)
        model.setPanelPresented(false)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(model.isPanelPresented)
        coordinator.show(.processes)
        XCTAssertTrue(window === coordinator.window)
        XCTAssertEqual(coordinator.navigation.page, .processes)
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(model.isPanelPresented)
        coordinator.show(.settings)
        XCTAssertTrue(window === coordinator.window)
        XCTAssertTrue(window.isVisible)
        window.close()
        await model.shutdown()
    }
}
