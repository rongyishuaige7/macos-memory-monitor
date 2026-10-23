import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import MemoryMonitorCore
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

    func testDesktopPresentationPolicyRejectsNonReadableSurfaces() {
        XCTAssertTrue(DesktopPresentationPolicy.isPresented(
            windowExists: true,
            windowVisible: true,
            isMiniaturized: false,
            isOccluded: false,
            appHidden: false
        ))
        XCTAssertFalse(DesktopPresentationPolicy.isPresented(
            windowExists: false,
            windowVisible: true,
            isMiniaturized: false,
            isOccluded: false,
            appHidden: false
        ))
        XCTAssertFalse(DesktopPresentationPolicy.isPresented(
            windowExists: true,
            windowVisible: false,
            isMiniaturized: false,
            isOccluded: false,
            appHidden: false
        ))
        XCTAssertFalse(DesktopPresentationPolicy.isPresented(
            windowExists: true,
            windowVisible: true,
            isMiniaturized: true,
            isOccluded: false,
            appHidden: false
        ))
        XCTAssertFalse(DesktopPresentationPolicy.isPresented(
            windowExists: true,
            windowVisible: true,
            isMiniaturized: false,
            isOccluded: true,
            appHidden: false
        ))
        XCTAssertFalse(DesktopPresentationPolicy.isPresented(
            windowExists: true,
            windowVisible: true,
            isMiniaturized: false,
            isOccluded: false,
            appHidden: true
        ))
    }

    func testProcessListDoesNotRecenterWhileScrolling() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let apps = (1...30).map { cleanupApp($0) }
        let processes = apps.map(\.process)
        let groups = processes.enumerated().map { index, process in
            WorkloadGroupSnapshot(
                id: "scroll-group-\(index)",
                title: "Scroll \(index)",
                processCount: 1,
                physicalFootprintBytes: process.physicalFootprintBytes,
                residentBytes: process.residentBytes,
                isSystem: false,
                representativeProcess: process.name,
                memberProcessIdentities: [process.identity]
            )
        }
        let snapshot = MonitorSnapshot(
            timestamp: timestamp,
            system: cleanupMemory(bytes: 8 * 1024 * 1024 * 1024, timestamp: timestamp.timeIntervalSince1970),
            systemStatus: .available(at: timestamp),
            cpuTime: nil,
            cpuStatus: .unavailable(message: "test"),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(message: "test"),
            processes: processes,
            processStatus: .available(at: timestamp),
            listedProcessCount: processes.count,
            sampledProcessCount: processes.count,
            groups: groups
        )
        let model = MonitorViewModel(
            sampler: DesktopScrollSamplingSource(snapshot: snapshot),
            historyStore: makeTemporaryHistoryStore("desktop-scroll-history"),
            processActions: makeTemporaryProcessActions("desktop-scroll-actions"),
            startRefreshTask: false
        )
        await model.refreshOnce(at: timestamp)
        let navigation = DesktopNavigation()
        let hosting = NSHostingView(
            rootView: DesktopProcesses(model: model, navigation: navigation)
                .frame(width: 760, height: 520)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 760, height: 520)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(findScrollView(in: hosting))
        scrollView.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil as Any?)
        window.makeFirstResponder(scrollView)
        let start = scrollView.contentView.bounds.origin.y
        for _ in 0..<20 {
            let cgEvent = try XCTUnwrap(CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: -26,
                wheel2: 0,
                wheel3: 0
            ))
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            scrollView.scrollWheel(with: event)
        }
        try await Task.sleep(for: .milliseconds(200))
        let moved = scrollView.contentView.bounds.origin.y - start
        XCTAssertEqual(
            moved,
            520,
            accuracy: 2,
            "continuous scroll must not be recentered"
        )
        hosting.removeFromSuperview()
        window.contentView = nil
        window.orderOut(nil)
        window.close()
        await model.shutdown()
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
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
        coordinator.show(.processes)
        XCTAssertTrue(window === coordinator.window)
        XCTAssertTrue(model.isPanelPresented)
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


@MainActor
private final class DesktopScrollSamplingSource: MonitorSamplingSource {
    let snapshot: MonitorSnapshot

    init(snapshot: MonitorSnapshot) {
        self.snapshot = snapshot
    }

    func sample(mode: SamplingMode, at timestamp: Date) async -> MonitorSnapshot {
        snapshot
    }
}
