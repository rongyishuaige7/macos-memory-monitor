import AppKit
import XCTest
@testable import MemoryMonitorApp

@MainActor
final class SmartCleanupNativeTests: XCTestCase {
    func testNormalQuitDeliversDelegateRequestAndAllowsRefusal() throws {
        var result: Result<Void, Error>?
        Task { @MainActor in
            do { try await verifyNormalQuit(); result = .success(()) }
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

    private func verifyNormalQuit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-quit-fixture-" + UUID().uuidString)
        let appURL = root.appendingPathComponent("Cleanup Quit Fixture.app")
        let binaryURL = appURL.appendingPathComponent("Contents/MacOS/CleanupQuitFixture")
        try FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Fixture.swift")
        try Self.fixtureSource.write(to: source, atomically: true, encoding: .utf8)
        let identifier = "test.memorymonitor.cleanup." + UUID().uuidString.lowercased()
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "CleanupQuitFixture",
            "CFBundleName": "Cleanup Quit Fixture", "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try await Task.detached(priority: .utility) {
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            compiler.arguments = [source.path, "-o", binaryURL.path]
            try compiler.run()
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        }.value

        var ownedApps: [NSRunningApplication] = []
        defer {
            // Only the uniquely named fixture can receive this cleanup request.
            for app in ownedApps where app.bundleIdentifier == identifier && app.bundleURL?.standardizedFileURL == appURL.standardizedFileURL {
                try? Data().write(to: root.appendingPathComponent("allow-exit"))
                if !app.isTerminated { _ = app.terminate() }
            }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for refusal in [false, true] {
            let marker = root.appendingPathComponent(refusal ? "refused.txt" : "accepted.txt")
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.createsNewApplicationInstance = true
            config.arguments = [marker.path, root.appendingPathComponent("allow-exit").path, refusal ? "refuse" : "accept"]
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            ownedApps.append(app)
            try await Task.sleep(for: .seconds(1))
            NSApp.activate(ignoringOtherApps: true)
            let clock = FixtureClock()
            let runtime = LiveSmartCleanupRuntime(timeProvider: { ProcessInfo.processInfo.systemUptime + clock.offset })
            let initial = await runtime.inventory()
            let observed = try XCTUnwrap(initial.first { $0.application.authorization.bundleIdentifier == identifier })
            XCTAssertNotNil(observed.protection, "Newly observed apps are protected by default")
            XCTAssertEqual(runtime.requestQuit(observed.application), .changed)
            clock.offset += 121
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didDeactivateApplicationNotification,
                object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: app])
            let justLeftForeground = await runtime.inspect(observed.application)
            XCTAssertEqual(justLeftForeground?.protection, "近期使用或仍在观察")
            XCTAssertEqual(runtime.requestQuit(observed.application), .changed)
            clock.offset += 121
            _ = await runtime.inspect(observed.application)
            try await Task.sleep(for: .seconds(0.8))
            let inspected = await runtime.inspect(observed.application)
            let ready = try XCTUnwrap(inspected)
            XCTAssertNil(ready.protection)
            XCTAssertEqual(runtime.requestQuit(ready.application), .sent)
            for _ in 0..<30 {
                if FileManager.default.fileExists(atPath: marker.path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "normal-quit-request")
            try await Task.sleep(for: .milliseconds(300))
            if refusal {
                XCTAssertFalse(app.isTerminated)
                XCTAssertEqual(runtime.exitState(ready.application), .running)
                try Data().write(to: root.appendingPathComponent("allow-exit"))
                XCTAssertTrue(app.terminate())
            } else {
                XCTAssertTrue(app.isTerminated)
                XCTAssertEqual(runtime.exitState(ready.application), .exited)
            }
            for _ in 0..<30 {
                if app.isTerminated { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(app.isTerminated, "Owned fixture must exit before finishing the test")
        }
        if ownedApps.allSatisfy(\.isTerminated) { try FileManager.default.removeItem(at: root) }
    }

    private static let fixtureSource = """
    import AppKit
    final class Delegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            let args = CommandLine.arguments
            try? "normal-quit-request".write(toFile: args[1], atomically: true, encoding: .utf8)
            if args[3] == "refuse" && !FileManager.default.fileExists(atPath: args[2]) { return .terminateCancel }
            return .terminateNow
        }
    }
    let app = NSApplication.shared
    let delegate = Delegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
    """
}

@MainActor
private final class FixtureClock { var offset: TimeInterval = 0 }
