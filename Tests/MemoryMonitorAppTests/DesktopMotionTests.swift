import AppKit
import QuartzCore
import ScreenCaptureKit
import XCTest
@testable import MemoryMonitorApp

@MainActor
final class DesktopMotionTests: XCTestCase {
    func testParticleLifecycleAndBoundedBurst() throws {
        var result: Result<Void, Error>?
        Task { @MainActor in
            do { try await verifyParticleLifecycle(); result = .success(()) }
            catch { result = .failure(error) }
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: true)
            }
        }
        // AppKit's event loop is required for real activation and occlusion notifications.
        NSApplication.shared.run()
        try XCTUnwrap(result).get()
    }

    private func verifyParticleLifecycle() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = .floating
        let view = MonitorParticleView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = view
        defer { view.stop(); window.close() }
        view.configure(mode: .running, running: true, trigger: 0, allowed: true)
        XCTAssertNil(view.emitter, "Detached views must not animate")
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        try await activate(window)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(window.occlusionState.contains(.visible))
        view.configure(mode: .running, running: true, trigger: 0, allowed: false)
        XCTAssertNil(view.emitter, "Disabled, reduced-motion and pressure gates share the allowed input")
        XCTAssertNil(view.hitTest(.zero), "Effects cannot consume clicks")
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            view.configure(mode: .running, running: true, trigger: 0, allowed: true)
            XCTAssertNil(view.emitter)
            return
        }
        view.configure(mode: .running, running: true, trigger: 0, allowed: true)
        XCTAssertNotNil(view.emitter, view.suppressionReason ?? "no suppression")
        try await Task.sleep(for: .milliseconds(300))
        if let output = ProcessInfo.processInfo.environment["MEMORY_MONITOR_MOTION_CAPTURE_DIR"] {
            XCTAssertTrue(CGPreflightScreenCaptureAccess())
            let first = try await capture(window, name: "running-1", output: output)
            try await Task.sleep(for: .milliseconds(250))
            let second = try await capture(window, name: "running-2", output: output)
            XCTAssertGreaterThan(first.lit, 4)
            XCTAssertGreaterThan(second.lit, 4)
            XCTAssertTrue(first.pixels != second.pixels, "Compositor particles must actually move")
        }
        view.isHidden = true
        XCTAssertNil(view.emitter)
        view.isHidden = false
        XCTAssertNotNil(view.emitter)
        window.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(view.emitter)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        try await activate(window)
        try await Task.sleep(for: .milliseconds(400))
        view.configure(mode: .running, running: true, trigger: 0, allowed: true)
        XCTAssertNotNil(view.emitter)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertNil(view.emitter)
        view.configure(mode: .running, running: true, trigger: 0, allowed: true)
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(view.emitter)
        window.makeKeyAndOrderFront(nil)
        try await activate(window)
        try await Task.sleep(for: .milliseconds(100))
        view.configure(mode: .burst, running: false, trigger: 0, allowed: true)
        XCTAssertNil(view.emitter, "Merely entering the page cannot emit success particles")
        view.configure(mode: .burst, running: false, trigger: 1, allowed: true)
        XCTAssertNotNil(view.emitter)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(view.emitter?.birthRate, 0)
        if let output = ProcessInfo.processInfo.environment["MEMORY_MONITOR_MOTION_CAPTURE_DIR"] {
            let success = try await capture(window, name: "success", output: output)
            XCTAssertGreaterThan(success.lit, 4)
        }
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertNil(view.emitter)
        view.configure(mode: .burst, running: false, trigger: 1, allowed: true)
        XCTAssertNil(view.emitter, "One success must not replay on later updates")
        view.configure(mode: .burst, running: false, trigger: 2, allowed: false)
        view.configure(mode: .burst, running: false, trigger: 2, allowed: true)
        XCTAssertNil(view.emitter, "Suppressed effects must not replay when returning")

        let scroll = NSScrollView(frame: view.frame)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
        scroll.documentView = document
        window.contentView = scroll
        document.addSubview(view)
        view.configure(mode: .running, running: true, trigger: 2, allowed: true)
        XCTAssertNotNil(view.emitter)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertNil(view.emitter, "Scrolling the instrument offscreen must stop it")
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        view.configure(mode: .running, running: false, trigger: 2, allowed: true)

        if ProcessInfo.processInfo.environment["MEMORY_MONITOR_MOTION_CAPTURE_DIR"] != nil {
            let idleStart = cpuSeconds()
            try await Task.sleep(for: .seconds(3))
            let idle = cpuSeconds() - idleStart
            view.configure(mode: .running, running: true, trigger: 2, allowed: true)
            let runningStart = cpuSeconds()
            try await Task.sleep(for: .seconds(3))
            let running = cpuSeconds() - runningStart
            XCTAssertNotNil(view.emitter)
            print(String(format: "particle-cpu idle=%.3fs active=%.3fs over 3s each", idle, running))
        }
    }

    private func activate(_ window: NSWindow) async throws {
        for _ in 0..<20 {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(100))
            if NSRunningApplication.current.isActive { return }
        }
        XCTFail("The native motion test window could not become active")
    }

    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private func capture(_ window: NSWindow, name: String, output: String) async throws -> (lit: Int, pixels: [UInt8]) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let source = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = 400
        configuration.height = 444
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
        var lit = 0
        var pixels: [UInt8] = []
        for y in (bitmap.pixelsHigh / 4)..<(bitmap.pixelsHigh * 3 / 4) {
            for x in (bitmap.pixelsWide / 8)..<(bitmap.pixelsWide * 7 / 8) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    let green = UInt8(clamping: Int(color.greenComponent * 255))
                    pixels.append(green)
                    if green > 20 { lit += 1 }
                }
            }
        }
        return (lit, pixels)
    }
}
