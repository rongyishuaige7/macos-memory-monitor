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
        controller.start(confirmedApplications: runtime.confirmationApplications)
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

    func testAuthorizationIdentityIncludesBundleAndExecutableInodes() {
        let app = cleanupApp(1)
        let (controller, _, _) = setup()
        controller.setAuthorized(app, true)
        XCTAssertTrue(controller.isAuthorized(app))

        let replaced = CleanupApplication(
            process: app.process,
            authorization: .init(
                bundleIdentifier: app.authorization.bundleIdentifier,
                bundlePath: app.authorization.bundlePath,
                executablePath: app.authorization.executablePath,
                bundleInode: app.authorization.bundleInode.map { $0 + 1 },
                executableInode: app.authorization.executableInode
            )
        )
        XCTAssertFalse(controller.isAuthorized(replaced))
    }

    func testLegacyAuthorizationWithoutInodesIsDiscarded() throws {
        let suite = "cleanup-legacy-auth-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let legacy = CleanupAuthorization(
            bundleIdentifier: "legacy.app",
            bundlePath: "/Applications/Legacy.app",
            executablePath: "/Applications/Legacy.app/Contents/MacOS/Legacy"
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "smartCleanup.authorizedApplications.v1")

        let controller = SmartCleanupController(runtime: FakeCleanupRuntime(), defaults: defaults)
        XCTAssertTrue(controller.authorizations.isEmpty)
        XCTAssertTrue(controller.notice?.contains("身份校验") == true)
    }

    func testProtectsForegroundRecentBusyAndUnknownApps() async {
        let apps = (1...5).map { cleanupApp($0) }
        let (controller, runtime, _) = setup([
            observation(apps[0], frontmost: true), observation(apps[1], recent: 119),
            observation(apps[2], cpu: 5), observation(apps[3], cpu: nil), observation(apps[4], cpu: .nan)
        ])
        for app in apps { controller.setAuthorized(app, true) }
        controller.start(confirmedApplications: runtime.confirmationApplications)
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
        controller.start(confirmedApplications: runtime.confirmationApplications)
        controller.start(confirmedApplications: runtime.confirmationApplications)
        await controller.waitUntilFinished()
        XCTAssertEqual(runtime.requests.count, 2)
        XCTAssertEqual(controller.result?.exitedCount, 2)
        XCTAssertEqual(controller.result?.observedChangeBytes, 64 * 1024 * 1024)
        XCTAssertEqual(controller.completionPulse, 2)
        XCTAssertTrue(controller.result?.hasMeasuredBenefit == true)
        XCTAssertNil(controller.operationGate.owner)
        controller.start(confirmedApplications: runtime.confirmationApplications)
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
            controller.start(confirmedApplications: runtime.confirmationApplications)
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
            controller.start(confirmedApplications: runtime.confirmationApplications)
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
        controller.start(confirmedApplications: runtime.confirmationApplications)
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
        controller.start(confirmedApplications: runtime.confirmationApplications)
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
        controller.start(confirmedApplications: runtime.confirmationApplications)
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
            controller.start(confirmedApplications: runtime.confirmationApplications)
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
        controller.start(confirmedApplications: runtime.confirmationApplications)
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
        controller.start(confirmedApplications: runtime.confirmationApplications)
        await controller.waitUntilFinished()
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertEqual(runtime.reliefCalls, 0)
        XCTAssertTrue(controller.result?.cancelled == true)
    }

    func testCancellationDuringFinalMeasurementCannotCelebrate() async {
        let app = cleanupApp(1)
        let (controller, runtime, _) = setup([observation(app)])
        controller.setAuthorized(app, true)
        runtime.afterBytes = runtime.beforeBytes + 64 * 1024 * 1024
        runtime.onMemoryRead = { if runtime.memoryReads == 6 { controller.cancel() } }
        controller.start(confirmedApplications: runtime.confirmationApplications)
        await controller.waitUntilFinished()
        XCTAssertTrue(controller.result?.cancelled == true)
        XCTAssertNil(controller.result?.observedChangeBytes)
        XCTAssertFalse(controller.result?.hasMeasuredBenefit == true)
    }

    func testCleanupEligibilityPolicyUsesConfiguredThresholds() {
        let app = cleanupApp(1)
        let policy = CleanupEligibilityPolicy(
            policyID: "test.policy",
            recentActivitySeconds: 10,
            busyCPUPercent: 20
        )

        XCTAssertEqual(
            policy.decision(for: observation(app, recent: 15, cpu: 10)).reason,
            .allowed
        )
        XCTAssertEqual(
            policy.decision(for: observation(app, recent: 5, cpu: 10)).reason,
            .recentActivity
        )
        XCTAssertEqual(
            policy.decision(for: observation(app, recent: 15, cpu: 25)).reason,
            .busyCPU
        )
        XCTAssertEqual(
            policy.decision(for: observation(app, frontmost: true)).reason,
            .frontmost
        )
        XCTAssertEqual(
            policy.decision(for: observation(app, recent: 15, cpu: nil)).reason,
            .missingCPUSample
        )
    }

    func testAuditRecordsIntentSignalAndTerminalOutcome() async {
        let suite = "cleanup-audit-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let runtime = FakeCleanupRuntime()
        let app = cleanupApp(1)
        runtime.observations = [observation(app)]
        var events: [ProcessActionAuditEvent] = []
        let controller = SmartCleanupController(
            runtime: runtime,
            defaults: defaults,
            audit: { event in
                events.append(event)
                return true
            }
        )
        controller.setAuthorized(app, true)
        controller.start(confirmedApplications: runtime.confirmationApplications)
        await controller.waitUntilFinished()

        XCTAssertEqual(events.map(\.phase), [.intent, .signalSent, .terminal])
        XCTAssertEqual(events.map(\.outcome), [.completed, .completed, .completed])
        XCTAssertEqual(Set(events.map(\.operationID)).count, 1)
        XCTAssertEqual(controller.entries.first?.outcome, .exited)
        XCTAssertNil(controller.notice)
    }

    func testAuditFailureBlocksQuitBeforeSendingRequest() async {
        let suite = "cleanup-audit-failure-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let runtime = FakeCleanupRuntime()
        let app = cleanupApp(1)
        runtime.observations = [observation(app)]
        let controller = SmartCleanupController(
            runtime: runtime,
            defaults: defaults,
            audit: { _ in false }
        )
        controller.setAuthorized(app, true)
        controller.start(confirmedApplications: runtime.confirmationApplications)
        await controller.waitUntilFinished()

        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertEqual(controller.entries.first?.outcome, .skipped)
        XCTAssertTrue(controller.notice?.contains("审计") == true)
    }

    func testInventoryDiagnosticsExposeSkippedApplications() async {
        let suite = "cleanup-inventory-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let runtime = FakeCleanupRuntime()
        let app = cleanupApp(1)
        runtime.inventoryReportValue = CleanupInventory(
            observations: [observation(app)],
            skipped: [
                CleanupSkip(name: "No Bundle", reason: .missingBundle),
                CleanupSkip(name: "Protected", reason: .protectedProcess),
                CleanupSkip(name: "No Path", reason: .missingExecutable)
            ]
        )
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults)
        controller.refreshApplications()
        await controller.waitUntilRefreshed()

        XCTAssertEqual(controller.applications.count, 1)
        XCTAssertEqual(controller.inventory.evaluatedCount, 4)
        XCTAssertEqual(controller.inventory.skippedCount, 3)
        XCTAssertTrue(controller.inventory.skippedSummary?.contains("1 个缺少 bundle 标识") == true)
        XCTAssertTrue(controller.inventory.skippedSummary?.contains("1 个受系统保护") == true)
    }

    func testConfirmationCannotAcquireNewlyEligibleTargets() async {
        let apps = [cleanupApp(1), cleanupApp(2)]
        let (controller, runtime, _) = setup([observation(apps[0], frontmost: true)])
        apps.forEach { controller.setAuthorized($0, true) }
        controller.refreshApplications()
        await controller.waitUntilRefreshed()
        let confirmed = controller.confirmationApplications
        XCTAssertTrue(confirmed.isEmpty)

        runtime.observations = apps.map { observation($0) }
        controller.start(confirmedApplications: confirmed)
        await controller.waitUntilFinished()
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertEqual(controller.plannedCount, 0)
    }

    func testConfirmationKeepsOriginalIdentityAndNeverFillsVacancies() async {
        let original = cleanupApp(1)
        let replacement = cleanupApp(1, start: 2000)
        let other = cleanupApp(2)
        let (controller, runtime, _) = setup([observation(replacement), observation(other)])
        controller.setAuthorized(original, true)
        controller.setAuthorized(other, true)
        controller.start(confirmedApplications: [original])
        await controller.waitUntilFinished()
        XCTAssertTrue(runtime.requests.isEmpty)
        XCTAssertTrue(controller.entries.contains { $0.id == original.id && $0.outcome == .skipped })
    }

    func testConfirmationIsBoundedAndDeduplicated() async {
        let apps = (1...10).map { cleanupApp($0) }
        let (controller, runtime, _) = setup(apps.map { observation($0) })
        apps.forEach { controller.setAuthorized($0, true) }
        controller.start(confirmedApplications: apps.flatMap { [$0, $0] })
        await controller.waitUntilFinished()
        XCTAssertEqual(Set(runtime.requests.map(\.id)), Set(apps.prefix(8).map(\.id)))
        XCTAssertEqual(runtime.requests.count, 8)
    }

    func testRevocationAndCancellationDuringIntentPreventQuit() async {
        for cancel in [false, true] {
            let (_, runtime, defaults) = setup([observation(cleanupApp(1))])
            let reference = CleanupControllerReference()
            var events: [ProcessActionAuditEvent] = []
            let controller = SmartCleanupController(runtime: runtime, defaults: defaults, audit: { event in
                events.append(event)
                if event.phase == .intent {
                    await Task.yield()
                    if cancel { reference.controller?.cancel() }
                    else { reference.controller?.revokeAll() }
                }
                return true
            })
            reference.controller = controller
            controller.setAuthorized(cleanupApp(1), true)
            controller.start(confirmedApplications: runtime.confirmationApplications)
            await controller.waitUntilFinished()
            XCTAssertTrue(runtime.requests.isEmpty)
            XCTAssertEqual(events.map(\.phase), [.intent, .terminal])
            XCTAssertEqual(events.last?.outcome, .cancelled)
            XCTAssertNil(controller.operationGate.owner)
        }
    }

    func testFinalRelaunchAndInterruptedMeasurementKeepAuditConsistent() async {
        for scenario in 0..<3 {
            let app = cleanupApp(1)
            let (_, runtime, defaults) = setup([observation(app)])
            var events: [ProcessActionAuditEvent] = []
            let controller = SmartCleanupController(runtime: runtime, defaults: defaults, audit: { event in
                events.append(event)
                return true
            })
            controller.setAuthorized(app, true)
            if scenario == 0 {
                runtime.onExitState = { _ in runtime.memoryReads > 3 ? .relaunched : .exited }
            } else if scenario == 1 {
                runtime.failMemoryRead = 4
            } else {
                runtime.onMemoryRead = { if runtime.memoryReads == 4 { controller.cancel() } }
            }
            controller.start(confirmedApplications: [app])
            await controller.waitUntilFinished()
            XCTAssertEqual(events.map(\.phase), [.intent, .signalSent, .terminal])
            XCTAssertEqual(Set(events.map(\.operationID)).count, 1)
            XCTAssertEqual(events.last?.outcome, scenario == 0 ? .failed : .completed)
            XCTAssertEqual(controller.entries.first?.outcome, scenario == 0 ? .relaunched : .exited)
        }
    }

    func testOperationGateBlocksManualAndMemoryTest() async {
        let (controller, runtime, _) = setup()
        XCTAssertTrue(controller.operationGate.acquire(.memoryTest))
        controller.start(confirmedApplications: runtime.confirmationApplications)
        XCTAssertFalse(controller.isBusy)
        controller.operationGate.release(.memoryTest)

        let auditURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        let actions = ProcessActionController(auditStore: ProcessActionAuditStore(fileURL: auditURL))
        XCTAssertTrue(actions.operationGate.acquire(.cleanup))
        actions.requestGracefulExit(for: cleanupApp(1).process)
        guard case .denied = actions.state else { return XCTFail("Manual requests must be denied during cleanup") }
        let test = MemoryTestController(operationGate: actions.operationGate, executionEnabled: true)
        test.start(system: cleanupMemory(bytes: 4 * 1024 * 1024 * 1024, timestamp: 1), usable: true, pressure: .normal, intensity: .light)
        XCTAssertFalse(test.isRunning)
        XCTAssertTrue(test.message?.contains("等待") == true)
        actions.operationGate.release(.cleanup)
        await actions.shutdown()
    }

    func testManualBusyAndShutdownBlockCleanup() async {
        let (_, runtime, defaults) = setup()
        let controller = SmartCleanupController(runtime: runtime, defaults: defaults, manualActionIsBusy: { true })
        controller.start(confirmedApplications: runtime.confirmationApplications)
        XCTAssertFalse(controller.isBusy)
        let second = SmartCleanupController(runtime: runtime, defaults: defaults)
        await second.shutdown()
        second.start(confirmedApplications: [])
        XCTAssertFalse(second.isBusy)
        let disabled = SmartCleanupController(runtime: runtime, defaults: defaults, executionEnabled: false)
        disabled.start(confirmedApplications: [])
        XCTAssertFalse(disabled.isBusy, "UI fixture launches cannot terminate real applications")
        disabled.setAuthorized(cleanupApp(1), true)
        XCTAssertTrue(disabled.authorizations.isEmpty)
    }

    func testFourthInventoryRequestCannotClearNewWorker() async {
        let scanner = ControlledCleanupScanner()
        let runtime = LiveSmartCleanupRuntime(sampler: scanner)
        async let first = runtime.inventoryReport()
        let firstStarted = await Task.detached { waitForSemaphore(scanner.started, timeout: 2) }.value
        XCTAssertTrue(firstStarted)

        async let second = runtime.inventoryReport()
        async let third = runtime.inventoryReport()
        async let fourth = runtime.inventoryReport()
        try? await Task.sleep(for: .milliseconds(100))
        scanner.release.signal()

        let secondWorkerStarted = await Task.detached { waitForSemaphore(scanner.started, timeout: 2) }.value
        XCTAssertTrue(secondWorkerStarted)
        scanner.release.signal()
        _ = await (first, second, third, fourth)
        XCTAssertEqual(scanner.maximumActive, 1)
    }

    func testConcurrentInventoryRequestsUseOneScanWorker() async {
        let scanner = SlowCleanupScanner()
        let runtime = LiveSmartCleanupRuntime(sampler: scanner)
        async let first = runtime.inventoryReport()
        async let second = runtime.inventoryReport()
        async let third = runtime.inventoryReport()
        async let fourth = runtime.inventoryReport()
        _ = await (first, second, third, fourth)
        XCTAssertEqual(scanner.maximumActive, 1)
    }
}

private func waitForSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

private final class ControlledCleanupScanner: CleanupProcessScanning, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func sampleDetailed(
        at timestamp: Date,
        budget: ProcessScanBudget?
    ) throws -> ProcessSamplingResult {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
        started.signal()
        _ = release.wait(timeout: .now() + 5)
        lock.lock()
        active -= 1
        lock.unlock()
        return ProcessSamplingResult(
            processes: [],
            listedProcessCount: 0,
            sampledProcessCount: 0,
            skippedProcessCount: 0,
            status: .unavailable(message: "test")
        )
    }

    func descendantProcessIDs(
        of rootPID: Int32,
        budget: ProcessScanBudget?
    ) throws -> Set<Int32> {
        []
    }
}

private final class SlowCleanupScanner: CleanupProcessScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0

    var maximumActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func sampleDetailed(
        at timestamp: Date,
        budget: ProcessScanBudget?
    ) throws -> ProcessSamplingResult {
        lock.lock()
        active += 1
        maximum = max(maximum, active)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.12)
        lock.lock()
        active -= 1
        lock.unlock()
        return ProcessSamplingResult(
            processes: [],
            listedProcessCount: 0,
            sampledProcessCount: 0,
            skippedProcessCount: 0,
            status: .unavailable(message: "test")
        )
    }

    func descendantProcessIDs(
        of rootPID: Int32,
        budget: ProcessScanBudget?
    ) throws -> Set<Int32> {
        []
    }
}

@MainActor
private final class CleanupControllerReference {
    weak var controller: SmartCleanupController?
}

@MainActor
final class FakeCleanupRuntime: SmartCleanupRuntime {
    var now: TimeInterval = 1000
    var observations: [CleanupObservation] = []
    var inventoryReportValue: CleanupInventory?
    var confirmationApplications: [CleanupApplication] {
        Array(observations.sorted {
            ProcessSnapshot.memoryDescending($0.application.process, $1.application.process)
        }.prefix(8).map(\.application))
    }
    var requests: [CleanupApplication] = []
    var quitResult: CleanupQuitRequest = .sent
    var exitResult: CleanupExitState = .exited
    var onInspect: ((CleanupApplication) -> CleanupObservation?)?
    var onRequest: ((CleanupApplication) -> Void)?
    var onExitState: ((CleanupApplication) -> CleanupExitState)?
    var onSleep: (() -> Void)?
    var onMemoryRead: (() -> Void)?
    var beforeBytes: UInt64 = 2 * 1024 * 1024 * 1024
    var afterBytes: UInt64 = 2 * 1024 * 1024 * 1024
    var memoryReads = 0
    var failMemoryRead = 0
    var reliefCalls = 0
    func inventory() async -> [CleanupObservation] { observations }
    func inventoryReport() async -> CleanupInventory {
        inventoryReportValue ?? CleanupInventory(observations: observations)
    }
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
        onMemoryRead?()
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
        authorization: .init(
            bundleIdentifier: identifier,
            bundlePath: path,
            executablePath: executable,
            bundleInode: UInt64(10_000 + number),
            executableInode: UInt64(20_000 + number)
        ))
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
