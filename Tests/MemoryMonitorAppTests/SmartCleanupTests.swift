import AppKit
import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

@MainActor
final class SmartCleanupTests: XCTestCase {
    private func setup(_ observations: [CleanupObservation] = []) -> (SmartCleanupController, FakeCleanupRuntime, UserDefaults) {
        let suite = "cleanup-tests-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let runtime = FakeCleanupRuntime()
        runtime.observations = observations
        return (SmartCleanupController(runtime: runtime, defaults: defaults), runtime, defaults)
    }

    func testDefaultDenyAndBoundAuthorizationPersistence() async {
        let app = cleanupApp(1)
        let (controller, runtime, defaults) = setup([observation(app)])
        controller.start()
        await controller.waitUntilFinished()
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertEqual(controller.result?.exitedCount, 0)
        controller.setAuthorized(app, true)
        let restored = SmartCleanupController(runtime: runtime, defaults: defaults)
        XCTAssertTrue(restored.isAuthorized(app))
        let moved = CleanupApplication(process: app.process, authorization: .init(bundleIdentifier: app.authorization.bundleIdentifier,
            bundlePath: "/Applications/Moved.app", executablePath: "/Applications/Moved.app/Contents/MacOS/Test"))
        XCTAssertFalse(restored.isAuthorized(moved))
        restored.revokeAll()
        XCTAssertTrue(SmartCleanupController(runtime: runtime, defaults: defaults).authorizations.isEmpty)
    }

    func testProtectsForegroundRecentBusyAndUnknownApps() async {
        let apps = (1...5).map { cleanupApp($0) }
        let (controller, runtime, _) = setup([
            observation(apps[0], frontmost: true), observation(apps[1], recent: 119),
            observation(apps[2], cpu: 5), observation(apps[3], cpu: nil), observation(apps[4], cpu: .nan)
        ])
        for app in apps { controller.setAuthorized(app, true) }
        controller.start()
        await controller.waitUntilFinished()
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertEqual(controller.entries.count, 5)
        XCTAssertTrue(controller.entries.allSatisfy { $0.outcome == .skipped })
    }

    func testSequentialQuitsMeasureObservedChangeNotFootprints() async {
        let apps = [cleanupApp(1), cleanupApp(2)]
        let (controller, runtime, _) = setup(apps.map { observation($0) })
        apps.forEach { controller.setAuthorized($0, true) }
        runtime.afterBytes = runtime.beforeBytes + 64 * 1024 * 1024
        runtime.onRequest = { _ in XCTAssertEqual(runtime.requests.count, controller.completedCount + 1) }
        controller.start()
        controller.start()
        await controller.waitUntilFinished()
        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertEqual(controller.result?.exitedCount, 2)
        XCTAssertEqual(controller.result?.observedChangeBytes, 64 * 1024 * 1024)
        XCTAssertEqual(controller.completionPulse, 2)
        XCTAssertTrue(controller.result?.hasMeasuredBenefit == true)
        XCTAssertNil(controller.operationGate.owner)
        controller.start()
        XCTAssertFalse(controller.isBusy, "Repeated cleaning is cooled down")
    }

    func testRevalidatesActivityIdentityAndRevocationBeforeRequest() async {
        for scenario in 0..<4 {
            let app = cleanupApp(1)
            let (controller, runtime, _) = setup([observation(app)])
            controller.setAuthorized(app, true)
            runtime.onInspect = { _ in
                if scenario == 0 { return observation(app, frontmost: true) }
                if scenario == 1 { return observation(cleanupApp(1, start: 2000)) }
                if scenario == 2 { controller.setAuthorized(app, false) }
                if scenario == 3 { return nil }
                return observation(app)
            }
            controller.start()
            await controller.waitUntilFinished()
            XCTAssertTrue(runtime.requests.isEmpty, "scenario \(scenario)")
            XCTAssertEqual(controller.entries.first?.outcome, .skipped)
        }
    }

    func testRefusalAndTimeoutNeverBecomeSuccess() async {
        let app = cleanupApp(1)
        for refusal in [true, false] {
            let (controller, runtime, _) = setup([observation(app)])
            controller.setAuthorized(app, true)
            runtime.quitResult = refusal ? .refused : .sent
            runtime.exitResult = .running
            controller.start()
            await controller.waitUntilFinished()
            XCTAssertEqual(controller.result?.exitedCount, 0)
            XCTAssertEqual(controller.completionPulse, 0)
            XCTAssertEqual(controller.entries.first?.outcome, refusal ? .refused : .timedOut)
        }
    }

    func testCancellationStopsFutureAppsAndReportsSentRequest() async {
        let apps = [cleanupApp(1), cleanupApp(2)]
        let (controller, runtime, _) = setup(apps.map { observation($0) })
        apps.forEach { controller.setAuthorized($0, true) }
        runtime.exitResult = .running
        runtime.onSleep = {
            if controller.phase == .waiting { controller.cancel() }
        }
        controller.start()
        await controller.waitUntilFinished()
        XCTAssertEqual(runtime.requests.count, 1)
        XCTAssertTrue(controller.result?.cancelled == true)
        XCTAssertTrue(controller.entries.contains { $0.detail.contains("退出请求已发出") })
        XCTAssertTrue(controller.entries.contains { $0.detail == "尚未发送退出请求" })
        XCTAssertNil(controller.operationGate.owner)
    }

    func testSkipDoesNotResendAndAllowsNextApp() async {
        let apps = [cleanupApp(1), cleanupApp(2)]
        let (controller, runtime, _) = setup(apps.map { observation($0) })
        apps.forEach { controller.setAuthorized($0, true) }
        runtime.exitResult = .running
        runtime.onSleep = { if controller.phase == .waiting { controller.skipCurrent() } }
        controller.start()
        await controller.waitUntilFinished()
        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertEqual(controller.entries.filter { $0.outcome == .skipped }.count, 2)
        XCTAssertEqual(controller.completionPulse, 0)
    }

    func testRelaunchAndNoBenefitDoNotCelebrate() async {
        let app = cleanupApp(1)
        let (controller, runtime, _) = setup([observation(app)])
        controller.setAuthorized(app, true)
        runtime.onExitState = { _ in runtime.memoryReads > 3 ? .relaunched : .exited }
        controller.start()
        await controller.waitUntilFinished()
        XCTAssertEqual(controller.result?.exitedCount, 0)
        XCTAssertEqual(controller.entries.first?.outcome, .relaunched)
        XCTAssertFalse(controller.result?.hasMeasuredBenefit == true)
    }

    func testNegativeMemoryChangeAndFailedMeasurementsRemainHonest() async {
        let app = cleanupApp(1)
        for failure in [0, 1, 4] {
            let (controller, runtime, _) = setup([observation(app)])
            controller.setAuthorized(app, true)
            runtime.afterBytes = runtime.beforeBytes - 64 * 1024 * 1024
            runtime.failMemoryRead = failure
            controller.start()
            await controller.waitUntilFinished()
            if failure == 0 {
                XCTAssertEqual(controller.result?.observedChangeBytes, -64 * 1024 * 1024)
            } else {
                XCTAssertNil(controller.result?.observedChangeBytes)
                XCTAssertTrue(controller.result?.measurementFailed == true)
            }
            if failure == 1 { XCTAssertTrue(runtime.requests.isEmpty) }
            XCTAssertFalse(controller.result?.hasMeasuredBenefit == true)
        }
    }

    func testBatchBoundAndRevocationDuringEarlierQuit() async {
        let apps = (1...10).map { cleanupApp($0) }
        let (controller, runtime, _) = setup(apps.map { observation($0) })
        apps.forEach { controller.setAuthorized($0, true) }
        runtime.onRequest = { _ in if runtime.requests.count == 1 { controller.revokeAll() } }
        controller.start()
        await controller.waitUntilFinished()
        XCTAssertEqual(runtime.requests.count, 1)
        XCTAssertEqual(controller.plannedCount, 8)
        XCTAssertEqual(controller.entries.count, 10)
        XCTAssertEqual(Set(controller.entries.map(\.id)).count, 10)
    }

    func testCancellationDuringScanDoesNotPerformActions() async {
        let app = cleanupApp(1)
        let (controller, runtime, _) = setup([observation(app)])
        controller.setAuthorized(app, true)
        runtime.onSleep = { controller.cancel() }
        controller.start()
        await controller.waitUntilFinished()
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertEqual(runtime.reliefCalls, 0)
        XCTAssertTrue(controller.result?.cancelled == true)
    }

    func testOperationGateBlocksManualAndMemoryTest() async {
        let (controller, _, _) = setup()
        XCTAssertTrue(controller.operationGate.acquire(.memoryTest))
        controller.start()
        XCTAssertFalse(controller.isBusy)
        controller.operationGate.release(.memoryTest)

        let auditURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let actions = ProcessActionController(auditStore: ProcessActionAuditStore(fileURL: auditURL))
        XCTAssertTrue(actions.operationGate.acquire(.cleanup))
        actions.requestGracefulExit(for: cleanupApp(1).process)
        guard case .denied = actions.state else { return XCTFail("Manual requests must be denied during cleanup") }
        let test = MemoryTestController(operationGate: actions.operationGate)
        test.start(system: cleanupMemory(bytes: 4 * 1024 * 1024 * 1024, timestamp: 1), usable: true, pressure: .normal, intensity: .light)
        XCTAssertFalse(test.isRunning)
        XCTAssertTrue(test.message?.contains("等待") == true)
        actions.operationGate.release(.cleanup)
        await actions.shutdown()
    }

    func testManualBusyAndShutdownBlockCleanup() async {
        let (_, runtime, defaults) = setup()
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults, manualActionIsBusy: { true })
        controller.start()
        XCTAssertFalse(controller.isBusy)
        let second = SmartCleanupController(runtime: runtime, defaults: defaults)
        await second.shutdown()
        second.start()
        XCTAssertFalse(second.isBusy)
    }
}

@MainActor
final class FakeCleanupRuntime: SmartCleanupRuntime {
    var now: TimeInterval = 1000
    var observations: [CleanupObservation] = []
    var requests: [CleanupApplication] = []
    var quitResult: CleanupQuitRequest = .sent
    var exitResult: CleanupExitState = .exited
    var onInspect: ((CleanupApplication) -> CleanupObservation?)?
    var onRequest: ((CleanupApplication) -> Void)?
    var onExitState: ((CleanupApplication) -> CleanupExitState)?
    var onSleep: (() -> Void)?
    var beforeBytes: UInt64 = 2 * 1024 * 1024 * 1024
    var afterBytes: UInt64 = 2 * 1024 * 1024 * 1024
    var memoryReads = 0
    var failMemoryRead = 0
    var reliefCalls = 0
    func inventory() async -> [CleanupObservation] { observations }
    func inspect(_ app: CleanupApplication) async -> CleanupObservation? {
        if let onInspect { return onInspect(app) }
        return observations.first { $0.id == app.id }
    }
    func requestQuit(_ app: CleanupApplication) -> CleanupQuitRequest {
        requests.append(app)
        onRequest?(app)
        return quitResult
    }
    func exitState(_ app: CleanupApplication) -> CleanupExitState { onExitState?(app) ?? exitResult }
    func sampleMemory() async -> SystemMemorySnapshot? {
        memoryReads += 1
        if memoryReads == failMemoryRead { return nil }
        return cleanupMemory(bytes: memoryReads > 3 ? afterBytes : beforeBytes, timestamp: Double(memoryReads))
    }
    func relieveOwnMemory() async { reliefCalls += 1 }
    func sleep(seconds: TimeInterval) async throws {
        now += seconds
        onSleep?()
        await Task.yield()
        try Task.checkCancellation()
    }
}

func cleanupApp(_ number: Int, start: UInt64 = 1000) -> CleanupApplication {
    let path = "/Applications/Cleanup Test \(number).app"
    let executable = path + "/Contents/MacOS/Test"
    let identifier = "test.cleanup.\(number)"
    return CleanupApplication(process: ProcessSnapshot(identity: .init(pid: Int32(8000 + number), startTimeSeconds: start,
        startTimeMicroseconds: 0), parentPID: 1, userID: UInt32(getuid()), isSystem: false, name: "Test",
        executablePath: executable, applicationName: "测试应用 \(number)", bundleIdentifier: identifier,
        residentBytes: UInt64(number) * 100 * 1024 * 1024, physicalFootprintBytes: UInt64(number) * 100 * 1024 * 1024,
        virtualBytes: 0, userTimeNanos: 0, systemTimeNanos: 0, threadCount: 1),
        authorization: .init(bundleIdentifier: identifier, bundlePath: path, executablePath: executable))
}

func observation(_ app: CleanupApplication, frontmost: Bool = false, recent: TimeInterval = 300,
                 cpu: Double? = 0) -> CleanupObservation {
    .init(application: app, isFrontmost: frontmost, secondsSinceActivity: recent, cpuPercent: cpu)
}

func cleanupMemory(bytes: UInt64, timestamp: TimeInterval) -> SystemMemorySnapshot {
    .init(timestamp: Date(timeIntervalSince1970: timestamp), totalBytes: 16 * 1024 * 1024 * 1024, pageSize: 16384,
          freeBytes: bytes, activeBytes: 0, inactiveBytes: 0, speculativeBytes: 0, wiredBytes: 0,
          purgeableBytes: 0, compressedBytes: 0, throttledPages: 0, swapTotalBytes: 0, swapUsedBytes: 0, swapFreeBytes: 0)
}
