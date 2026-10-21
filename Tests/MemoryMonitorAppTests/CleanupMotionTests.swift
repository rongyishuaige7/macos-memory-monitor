import AppKit
import QuartzCore
@preconcurrency import ScreenCaptureKit
import XCTest
@testable import MemoryMonitorApp

@MainActor
final class CleanupMotionTests: XCTestCase {
    func testPressureTiers() {
        XCTAssertEqual(CleanupMotionTier.resolve(enabled: true, reduceMotion: false, pressure: .normal), .full)
        XCTAssertEqual(CleanupMotionTier.resolve(enabled: true, reduceMotion: false, pressure: .attention), .reduced)
        XCTAssertEqual(CleanupMotionTier.resolve(enabled: true, reduceMotion: false, pressure: .critical), .off)
        XCTAssertEqual(CleanupMotionTier.resolve(enabled: true, reduceMotion: false, pressure: nil), .off)
        XCTAssertEqual(CleanupMotionTier.resolve(enabled: true, reduceMotion: true, pressure: .normal), .off)
        XCTAssertEqual(CleanupMotionTier.resolve(enabled: false, reduceMotion: false, pressure: .normal), .off)
    }

    func testStageMotionIsBoundedAndStopsWithWindowLifecycle() throws {
        var result: Result<Void, Error>?
        Task { @MainActor in
            do { try await verifyMotion(); result = .success(()) }
            catch { result = .failure(error) }
            NSApp.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: true)
            }
        }
        NSApplication.shared.run()
        try XCTUnwrap(result).get()
    }

    private func verifyMotion() async throws {
        let rect = NSRect(x: 0, y: 0, width: 600, height: 240)
        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = .floating
        let view = CleanupParticleView(frame: rect)
        defer { view.stop(); window.close() }
        view.configure(phase: .scanning, tier: .full, pulse: 0, measuredBenefit: false)
        XCTAssertNil(view.emitter)
        window.contentView = view
        NSApp.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if NSRunningApplication.current.isActive { break }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        XCTAssertNil(view.hitTest(.zero))
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNil(view.emitter)
            return
        }
        view.configure(phase: .scanning, tier: .full, pulse: 0, measuredBenefit: false)
        _ = try XCTUnwrap(view.emitter, view.suppressionReason ?? "no suppression")
        XCTAssertLessThanOrEqual(view.layer?.sublayers?.count ?? 0, 45)
        let output = ProcessInfo.processInfo.environment["MEMORY_MONITOR_CLEANUP_CAPTURE_DIR"]
        if let output {
            XCTAssertTrue(CGPreflightScreenCaptureAccess())
            try await Task.sleep(for: .milliseconds(700))
            let first = try await capture(window, name: "cleanup-scanning-1", output: output)
            try await Task.sleep(for: .milliseconds(300))
            let second = try await capture(window, name: "cleanup-scanning-2", output: output)
            XCTAssertGreaterThan(first.lit, 100)
            XCTAssertGreaterThan(second.lit, 100)
            XCTAssertTrue(first.pixels != second.pixels, "Captured particles must move")
        }
        view.configure(phase: .waiting, tier: .full, pulse: 1, measuredBenefit: false)
        let fullCount = view.layer?.sublayers?.count ?? 0
        XCTAssertLessThanOrEqual(fullCount, 45)
        if let output {
            try await Task.sleep(for: .milliseconds(600))
            _ = try await capture(window, name: "cleanup-waiting", output: output)
        }
        view.configure(phase: .waiting, tier: .reduced, pulse: 1, measuredBenefit: false)
        XCTAssertLessThan(view.layer?.sublayers?.count ?? 0, fullCount)
        XCTAssertEqual(view.emitter?.emitterCells?.first?.birthRate, 8)
        if let output {
            try await Task.sleep(for: .milliseconds(600))
            _ = try await capture(window, name: "cleanup-reduced", output: output)
        }
        view.isHidden = true
        XCTAssertNil(view.emitter)
        view.isHidden = false
        XCTAssertNotNil(view.emitter)
        window.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(view.emitter)
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        try await activate(window)
        try await Task.sleep(for: .milliseconds(300))
        view.configure(phase: .quitting, tier: .full, pulse: 1, measuredBenefit: false)
        XCTAssertNotNil(view.emitter)
        view.configure(phase: .quitting, tier: .off, pulse: 2, measuredBenefit: false)
        XCTAssertNil(view.emitter)
        XCTAssertTrue(view.layer?.sublayers?.isEmpty != false)
        view.configure(phase: .measuring, tier: .full, pulse: 2, measuredBenefit: false)
        XCTAssertNil(view.emitter)
        XCTAssertEqual(view.layer?.sublayers?.count, 1)
        view.configure(phase: .finished, tier: .full, pulse: 2, measuredBenefit: false)
        XCTAssertTrue(view.layer?.sublayers?.isEmpty != false, "No success effect without measured benefit")
        view.configure(phase: .measuring, tier: .full, pulse: 2, measuredBenefit: false)
        view.configure(phase: .finished, tier: .full, pulse: 2, measuredBenefit: true)
        XCTAssertNotNil(view.emitter)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(view.emitter?.birthRate, 0)
        if let output { _ = try await capture(window, name: "cleanup-success", output: output) }
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(view.emitter)
        view.configure(phase: .finished, tier: .full, pulse: 2, measuredBenefit: true)
        XCTAssertNil(view.emitter, "Success cannot replay on refresh")
        view.configure(phase: .scanning, tier: .full, pulse: 2, measuredBenefit: false)
        window.orderOut(nil)
        try await Task.sleep(for: .milliseconds(100))
        view.configure(phase: .finished, tier: .full, pulse: 3, measuredBenefit: true)
        XCTAssertNil(view.emitter)
        window.makeKeyAndOrderFront(nil)
        try await activate(window)
        try await Task.sleep(for: .milliseconds(100))
        view.configure(phase: .finished, tier: .full, pulse: 3, measuredBenefit: true)
        XCTAssertNil(view.emitter, "A hidden success must not replay on return")

        let scroll = NSScrollView(frame: rect)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
        scroll.documentView = document
        window.contentView = scroll
        document.addSubview(view)
        view.configure(phase: .scanning, tier: .full, pulse: 3, measuredBenefit: false)
        XCTAssertNotNil(view.emitter)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertNil(view.emitter)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        view.configure(phase: .idle, tier: .full, pulse: 3, measuredBenefit: false)
        if output != nil {
            let idleStart = cpuSeconds()
            try await Task.sleep(for: .seconds(3))
            let idle = cpuSeconds() - idleStart
            view.configure(phase: .scanning, tier: .full, pulse: 3, measuredBenefit: false)
            let activeStart = cpuSeconds()
            try await Task.sleep(for: .seconds(3))
            print(String(format: "cleanup-motion-cpu idle=%.3fs active=%.3fs over 3s each", idle, cpuSeconds() - activeStart))
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
        configuration.width = 1200
        configuration.height = 524
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name + ".png"))
        var pixels: [UInt8] = []
        for y in stride(from: 80, to: bitmap.pixelsHigh - 10, by: 2) {
            for x in stride(from: 20, to: bitmap.pixelsWide - 20, by: 2) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    pixels.append(UInt8(clamping: Int(color.greenComponent * 255)))
                }
            }
        }
        return (pixels.filter { $0 > 20 }.count, pixels)
    }
}
