import AppKit
import Charts
import Combine
import Darwin
import Foundation
import MemoryMonitorCore
import SwiftUI

@MainActor
protocol MonitorSamplingSource {
    func sample(mode: SamplingMode, at timestamp: Date) async -> MonitorSnapshot
}

@MainActor
extension MonitorSampler: MonitorSamplingSource {
    func sample(mode: SamplingMode, at timestamp: Date) async -> MonitorSnapshot {
        let sampler = self
        return await Task.detached(priority: .utility) {
            sampler.sample(mode: mode, at: timestamp)
        }.value
    }
}

/// The single user-facing exit action. AppKit routes the termination request
/// through `applicationShouldTerminate`, where the existing coordinator waits
/// for graceful model shutdown before replying.
@MainActor
struct ApplicationTerminationAction {
    private let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void = {
        NSApplication.shared.terminate(nil)
    }) {
        self.handler = handler
    }

    func callAsFunction() {
        handler()
    }
}

struct MemoryMonitorApp: App {
    @NSApplicationDelegateAdaptor(MemoryMonitorApplicationDelegate.self)
    private var applicationDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            DesktopMenuPanel(
                model: applicationDelegate.model,
                openDesktop: { page in applicationDelegate.desktop.show(page) },
                terminationAction: applicationDelegate.terminationAction,
                openAudit: { applicationDelegate.desktop.show(.settings, audit: true) }
            )
                .onAppear { applicationDelegate.model.setPanelPresented(true) }
                .onDisappear { applicationDelegate.model.setPanelPresented(false) }
        } label: {
            MenuBarStatus(
                model: applicationDelegate.model,
                terminationAction: applicationDelegate.terminationAction
            )
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    applicationDelegate.desktop.show(.settings)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("搜索当前页面") {
                    let navigation = applicationDelegate.desktop.navigation
                    guard navigation.page == .processes else { return }
                    navigation.searchFocusRequest = UUID()
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

struct MemoryMonitorLaunchConfiguration: Equatable {
    let usesUIFixture: Bool
    /// True whenever the explicit UI-check switch was present, even if its
    /// storage root was missing or untrusted. Destructive capabilities are
    /// disabled for both the valid and the fail-closed fallback launch.
    let fixtureRequested: Bool
    let storageRoot: URL

    static func resolve(environment: [String: String]) -> Self {
        let fixtureRequested = MemoryMonitorUIFixture.isEnabled(environment: environment)
        if let isolatedRoot = MemoryMonitorUIFixture.isolatedStorageRootURL(
            environment: environment
        ) {
            return Self(
                usesUIFixture: true,
                fixtureRequested: true,
                storageRoot: isolatedRoot
            )
        }
        if fixtureRequested {
            // The fixture switch was supplied without a trustworthy storage
            // root. Keep the synthetic sampler and disable destructive
            // capabilities instead of silently falling back to the user's
            // production store. The generated root is a Darwin user temp
            // directory and is safe to recreate on every launch.
            let fallbackRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "MemoryMonitorFixtureFallback-\(UUID().uuidString)",
                    isDirectory: true
                )
            return Self(
                usesUIFixture: true,
                fixtureRequested: true,
                storageRoot: fallbackRoot
            )
        }
        return Self(
            usesUIFixture: false,
            fixtureRequested: false,
            storageRoot: MemoryMonitorStoragePaths.defaultRootURL
        )
    }
}

@MainActor
final class MemoryMonitorApplicationDelegate: NSObject, NSApplicationDelegate {
    let model: MonitorViewModel
    lazy var desktop = DesktopWindowCoordinator(
        model: model,
        allowsMemoryTest: allowsMemoryTest
    )
    let terminationAction = ApplicationTerminationAction()
    private let allowsMemoryTest: Bool
    private let terminationCoordinator: ApplicationTerminationCoordinator

    /// Selects the sampling source without reading global state in tests.
    /// Synthetic data is available only to the explicit isolated UI-check
    /// launch; every other environment keeps the production sampler.
    static func makeSamplingSource(
        environment: [String: String]
    ) -> any MonitorSamplingSource {
        makeSamplingSource(configuration: resolveLaunchConfiguration(environment: environment))
    }

    static func resolveLaunchConfiguration(
        environment: [String: String]
    ) -> MemoryMonitorLaunchConfiguration {
        MemoryMonitorLaunchConfiguration.resolve(environment: environment)
    }

    private static func makeSamplingSource(
        configuration: MemoryMonitorLaunchConfiguration
    ) -> any MonitorSamplingSource {
        guard configuration.usesUIFixture else {
            return MonitorSampler()
        }
        return MemoryMonitorUIFixtureSamplingSource(
            dataset: MemoryMonitorUIFixture.makeDataset()
        )
    }

    static func makeModel(
        environment: [String: String],
        startRefreshTask: Bool = true,
        dateProvider: @escaping @MainActor () -> Date = { Date() }
    ) -> MonitorViewModel {
        makeModel(
            configuration: resolveLaunchConfiguration(environment: environment),
            startRefreshTask: startRefreshTask,
            dateProvider: dateProvider
        )
    }

    static func makeModel(
        configuration: MemoryMonitorLaunchConfiguration,
        startRefreshTask: Bool = true,
        dateProvider: @escaping @MainActor () -> Date = { Date() }
    ) -> MonitorViewModel {
        let historyStore = HistoryStore(
            fileURL: MemoryMonitorStoragePaths.historyFileURL(
                root: configuration.storageRoot
            )
        )
        let auditStore = ProcessActionAuditStore(
            fileURL: MemoryMonitorStoragePaths.auditFileURL(
                root: configuration.storageRoot
            )
        )
        return MonitorViewModel(
            loginLaunchRuntime: configuration.fixtureRequested
                ? ReadOnlyLoginLaunchRuntime()
                : nil,
            sampler: makeSamplingSource(configuration: configuration),
            historyStore: historyStore,
            processActions: ProcessActionController(auditStore: auditStore),
            cleanupExecutionEnabled: !configuration.usesUIFixture,
            dateProvider: dateProvider,
            startRefreshTask: startRefreshTask
        )
    }

    override convenience init() {
        let configuration = Self.resolveLaunchConfiguration(
            environment: ProcessInfo.processInfo.environment
        )
        self.init(
            model: Self.makeModel(configuration: configuration),
            allowsMemoryTest: !configuration.fixtureRequested
        )
    }

    init(
        model: MonitorViewModel,
        terminationTimeoutSeconds: TimeInterval = 5,
        allowsMemoryTest: Bool = false
    ) {
        self.model = model
        self.allowsMemoryTest = allowsMemoryTest
        terminationCoordinator = ApplicationTerminationCoordinator(
            timeoutSeconds: terminationTimeoutSeconds
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        desktop.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        desktop.show(desktop.navigation.page)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationCoordinator.hasReplied {
            return .terminateNow
        }
        terminationCoordinator.begin(
            shutdown: { [weak model] in
                await model?.shutdown()
            },
            reply: { [weak sender] shouldTerminate in
                sender?.reply(toApplicationShouldTerminate: shouldTerminate)
            }
        )
        return .terminateLater
    }
}

/// Races graceful shutdown against a monotonic timeout without making the
/// application wait for a child task that ignores cancellation. The first
/// completion wins and AppKit receives exactly one termination reply.
@MainActor
final class ApplicationTerminationCoordinator {
    private enum State {
        case idle
        case waiting
        case replied
    }

    private let timeoutSeconds: TimeInterval
    private var state = State.idle
    private var shutdownTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(timeoutSeconds: TimeInterval = 5) {
        self.timeoutSeconds = timeoutSeconds.isFinite && timeoutSeconds > 0
            ? timeoutSeconds
            : 5
    }

    var hasReplied: Bool {
        state == .replied
    }

    func begin(
        shutdown: @escaping @MainActor () async -> Void,
        reply: @escaping @MainActor (Bool) -> Void
    ) {
        guard state == .idle else { return }
        state = .waiting

        shutdownTask = Task { @MainActor [weak self] in
            await shutdown()
            self?.finish(reply: reply)
        }
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(self.timeoutSeconds))
            } catch {
                return
            }
            self.finish(reply: reply)
        }
    }

    private func finish(reply: @escaping @MainActor (Bool) -> Void) {
        guard state == .waiting else { return }
        state = .replied
        shutdownTask?.cancel()
        timeoutTask?.cancel()
        shutdownTask = nil
        timeoutTask = nil
        reply(true)
    }
}

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var system: SystemMemorySnapshot?
    @Published private(set) var systemStatus = SampleStatus.unavailable(message: "等待首次采样")
    /// Indicates that the current `system` value belongs to a validated,
    /// finite sampling pass. `system` itself is retained across provider
    /// failures so the UI can avoid destructive resets, but must not be
    /// presented as current data when this flag is false.
    @Published private(set) var systemDataIsUsable = false
    /// Kept for diagnostics/tests; no current production view reads these
    /// fractions. They must not invalidate every observing SwiftUI view on
    /// each sampling pass.
    private(set) var cpuUsageFraction: Double?
    @Published private(set) var cpuStatus = SampleStatus.unavailable(message: "等待首次采样")
    private(set) var gpuUsageFraction: Double?
    @Published private(set) var gpuStatus = SampleStatus.unavailable(message: "等待首次采样")
    @Published private(set) var processes: [ProcessSnapshot] = []
    @Published private(set) var processCPUPercent: [ProcessIdentity: Double] = [:]
    private var processCPUBaseline = ProcessCPUBaseline()
    @Published private(set) var groups: [WorkloadGroupSnapshot] = []
    @Published private(set) var processStatus = SampleStatus.unavailable(message: "等待首次采样")
    @Published private(set) var observedProcessCount = 0
    @Published private(set) var listedProcessCount = 0
    @Published private(set) var history: [MemoryHistoryRecord] = []
    @Published private(set) var historyError: String?
    @Published private(set) var historyDiagnostics: HistoryStoreDiagnostics?
    @Published private(set) var updatedAt: Date?
    /// Cadence input only; no view observes it, so it must not trigger a
    /// full SwiftUI invalidation when the panel opens or closes.
    private(set) var isPanelPresented = false
    private var isPopoverPresented = false
    private var isDesktopPresented = false
    @Published private(set) var pressureLevel: MemoryPressureLevel?
    @Published private(set) var samplingDiagnostics = SamplingDiagnostics(
        mode: .background,
        totalDurationMilliseconds: 0,
        processDurationMilliseconds: nil,
        processSamplingPerformed: false,
        processCount: 0,
        listedProcessCount: 0
    )
    @Published private(set) var healthCheckedAt = Date()

    let processActions: ProcessActionController
    let smartCleanup: SmartCleanupController
    let loginLaunch: LoginLaunchCoordinator
    private var refreshTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownCompleted = false
    private var isShuttingDown = false
    private var refreshIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private let sampler: any MonitorSamplingSource
    private let samplingPolicy = AdaptiveSamplingPolicy()
    private var pressureEvaluator = MemoryPressureEvaluator()
    private let refreshWakeup = RefreshWakeup()
    private let historyStore: HistoryStore
    private var historyStoreAvailable = true
    private var historyLoaded = false
    /// Samples kept in memory while the durable history store is unavailable.
    /// They are merged into the actor before the store is marked recovered.
    private var fallbackHistory: [MemoryHistoryRecord] = []
    private let historyRetentionInterval = HistoryStore.defaultRetentionInterval
    private var historyRetryAfter: Date?
    private var historyRetryAttempt = 0
    private let historyRetryBaseInterval: TimeInterval = 30
    private let historyRetryMaxInterval: TimeInterval = 5 * 60
    private var refreshInFlight = false
    private let refreshClock = ContinuousClock()
    private let dateProvider: @MainActor () -> Date
    private var lastPressureObservationInstant: ContinuousClock.Instant?
    private let clockRollbackTolerance: TimeInterval = 1
    private var refreshEpoch: UInt64 = 0
    private var lastObservedRefreshRequest: (
        timestamp: Date,
        instant: ContinuousClock.Instant
    )?
    /// Calls arriving while a sample is in progress are coalesced to the
    /// latest request. Each caller still waits until that coalesced pass has
    /// completed, so a health refresh cannot report success prematurely.
    private struct QueuedRefresh {
        let timestamp: Date
        let usesLiveClock: Bool
        let epoch: UInt64
        let requestSequence: UInt64
        let token: UUID
        let continuation: CheckedContinuation<Void, Never>
    }
    private var queuedRefreshes: [QueuedRefresh] = []
    private var nextRefreshSequence: UInt64 = 0
    /// The last pass accepted by the UI. A provider can return a delayed
    /// snapshot after a newer request was already applied; accepting it would
    /// move timestamps and every cross-sample baseline backwards.
    private var lastAcceptedPass: (
        timestamp: Date,
        epoch: UInt64,
        requestSequence: UInt64
    )?
    private var previousCPUTime: CPUTimeSnapshot?
    private var lastUsableProcessSampleAt: Date?

    init(
        loginLaunchRuntime: (any LoginLaunchRuntime)? = nil,
        sampler: any MonitorSamplingSource = MonitorSampler(),
        historyStore: HistoryStore,
        processActions: ProcessActionController,
        cleanupExecutionEnabled: Bool = false,
        dateProvider: @escaping @MainActor () -> Date = { Date() },
        startRefreshTask: Bool = true
    ) {
        self.processActions = processActions
        smartCleanup = SmartCleanupController(operationGate: processActions.operationGate,
            executionEnabled: cleanupExecutionEnabled,
            manualActionIsBusy: { [weak processActions] in processActions?.isBusy != false },
            audit: { [weak processActions] event in
                guard let processActions else { return false }
                return await processActions.recordExternalAudit(event)
            })
        loginLaunch = LoginLaunchCoordinator(runtime: loginLaunchRuntime)
        self.sampler = sampler
        self.historyStore = historyStore
        self.dateProvider = dateProvider
        if startRefreshTask {
            refreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    // Keep the model alive only while a single refresh pass
                    // is running. The cadence wait below must not call an
                    // instance method, otherwise the task would retain the
                    // model through the entire wait and form a cycle with
                    // `refreshTask`.
                    guard let waitConfiguration = await self?.refreshPass() else {
                        return
                    }
                    guard await Self.waitForNextSample(
                        interval: waitConfiguration.interval,
                        wakeup: waitConfiguration.wakeup
                    ) else {
                        break
                    }
                }

            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var pressure: PressureState {
        guard systemDataIsUsable, let pressureLevel else { return .unknown }
        return PressureState(level: pressureLevel)
    }

    var healthSnapshot: MonitorHealthSnapshot {
        MonitorHealthEvaluator.evaluate(
            MonitorHealthInput(
                systemStatus: systemStatus,
                cpuStatus: cpuStatus,
                gpuStatus: gpuStatus,
                processStatus: processStatus,
                observedProcessCount: observedProcessCount,
                listedProcessCount: listedProcessCount,
                samplingDiagnostics: samplingDiagnostics,
                historyRecordCount: history.count,
                historyError: historyError,
                historyDiagnostics: historyDiagnostics,
                auditError: processActions.auditError,
                loginStatus: loginLaunch.status,
                loginError: loginLaunch.lastError,
                runtimeEnvironment: .current(),
                checkedAt: healthCheckedAt,
                systemDataIsUsable: systemDataIsUsable,
                now: Date()
            )
        )
    }

    func process(for identity: ProcessIdentity) -> ProcessSnapshot? {
        processes.first { $0.identity == identity }
    }

    func detailDataStatus(
        retainedItemCount: Int,
        targetPresent: Bool
    ) -> MonitorDetailDataStatus {
        MonitorDetailDataStatus.resolve(
            processStatus: processStatus,
            samplingDiagnostics: samplingDiagnostics,
            retainedItemCount: retainedItemCount,
            targetPresent: targetPresent,
            observedAt: updatedAt,
            lastSuccessfulSampledAt: lastUsableProcessSampleAt
        )
    }

    func setPanelPresented(_ presented: Bool) {
        isPopoverPresented = presented
        updatePresentationState()
    }

    func setDesktopPresented(_ presented: Bool) {
        isDesktopPresented = presented
        updatePresentationState()
    }

    private func updatePresentationState() {
        let presented = isPopoverPresented || isDesktopPresented
        guard isPanelPresented != presented else { return }
        isPanelPresented = presented
        Task { await refreshWakeup.signal() }
    }

    func refreshHealth() {
        loginLaunch.refreshStatus()
        // The health panel's action is an actual state refresh, not only a
        // timestamp update. refreshOnce serializes with the regular loop so
        // a manually requested pass cannot race a background sample.
        Task { [weak self] in
            guard let self else { return }
            await self.refreshOnce()
            await self.processActions.refreshAudit()
            // Publish the check marker only after the requested sampling pass
            // (including any queued/latest-request coalescing) has finished.
            self.healthCheckedAt = self.dateProvider()
        }
    }

    private struct RefreshWaitConfiguration {
        let interval: TimeInterval
        let wakeup: RefreshWakeup
    }

    /// Runs one pass and returns only the values needed by the cadence wait.
    /// Keeping this finite is important: the task can release its temporary
    /// strong reference to `self` before entering the next wait.
    private func refreshPass() async -> RefreshWaitConfiguration {
        await refreshOnce()
        return RefreshWaitConfiguration(
            interval: samplingPolicy.intervalSeconds(
                panelPresented: isPanelPresented,
                pressureActive: pressureEvaluator.pressureActiveForSampling
            ),
            wakeup: refreshWakeup
        )
    }

    func shutdown() async {
        if shutdownCompleted { return }
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        isShuttingDown = true
        let activeRefreshTask = refreshTask
        refreshTask = nil
        activeRefreshTask?.cancel()
        await refreshWakeup.signal()

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.smartCleanup.shutdown()
            if let activeRefreshTask {
                await activeRefreshTask.value
            }
            await self.waitForRefreshIdle()
            await self.flushHistoryForShutdown()
            await self.processActions.shutdown()
        }
        shutdownTask = task
        await task.value
        shutdownCompleted = true
        shutdownTask = nil
    }

    private func waitForRefreshIdle() async {
        guard refreshInFlight else { return }
        await withCheckedContinuation { continuation in
            refreshIdleWaiters.append(continuation)
        }
    }

    private func markRefreshIdle() {
        refreshInFlight = false
        let waiters = refreshIdleWaiters
        refreshIdleWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func flushHistoryForShutdown() async {
        let now = dateProvider()
        do {
            // Retry the complete recovery path during shutdown. A transient
            // write failure may have left samples in `fallbackHistory`; a
            // simple flush would be a no-op when the actor had not loaded
            // successfully and would lose those samples on process exit.
            _ = try await historyStore.load(now: now)
            if !fallbackHistory.isEmpty {
                _ = try await historyStore.merge(records: fallbackHistory, now: now)
            }
            try await historyStore.flush(now: now)
            history = try await historyStore.currentRecords(now: now)
            fallbackHistory.removeAll(keepingCapacity: false)
            historyStoreAvailable = true
            historyLoaded = true
            historyError = nil
            historyRetryAfter = nil
            historyRetryAttempt = 0
        } catch {
            historyStoreAvailable = false
            historyError = error.localizedDescription
            scheduleHistoryRetry(after: now)
        }
        historyDiagnostics = await historyStore.diagnostics()
    }

    func refreshOnce() async {
        await refreshOnce(at: dateProvider(), usesLiveClock: true)
    }

    func refreshOnce(at timestamp: Date) async {
        await refreshOnce(at: timestamp, usesLiveClock: false)
    }

    private func refreshOnce(at timestamp: Date, usesLiveClock: Bool) async {
        guard !isShuttingDown else { return }
        guard timestamp.timeIntervalSince1970.isFinite else { return }

        let requestSequence = nextRefreshSequence
        nextRefreshSequence &+= 1
        let epoch = refreshEpochForRequest(
            at: timestamp,
            observedAt: refreshClock.now
        )

        if refreshInFlight {
            await enqueueRefresh(
                at: timestamp,
                usesLiveClock: usesLiveClock,
                epoch: epoch,
                requestSequence: requestSequence
            )
            return
        }

        refreshInFlight = true
        await performRefresh(
            at: timestamp,
            usesLiveClock: usesLiveClock,
            epoch: epoch,
            requestSequence: requestSequence
        )

        // Drain the one-slot queue synchronously. New callers can re-enter
        // while `performRefresh` awaits the sampler; taking and clearing the
        // array happens in one actor-isolated segment, so no request can be
        // lost between passes.
        while !queuedRefreshes.isEmpty {
            let queued = queuedRefreshes
            queuedRefreshes.removeAll(keepingCapacity: true)
            if !isShuttingDown,
               let latest = queued.max(by: { lhs, rhs in
                   Self.refreshRequestPrecedes(lhs, rhs)
               }) {
                await performRefresh(
                    at: latest.timestamp,
                    usesLiveClock: latest.usesLiveClock,
                    epoch: latest.epoch,
                    requestSequence: latest.requestSequence
                )
            }
            for waiter in queued {
                waiter.continuation.resume()
            }
        }
        markRefreshIdle()
    }

    private func performRefresh(
        at timestamp: Date,
        usesLiveClock: Bool,
        epoch: UInt64,
        requestSequence: UInt64
    ) async {
        // A queued request can carry an older wall-clock instant than the pass
        // already shown (for example after a delayed health refresh). Skip the
        // expensive provider/history work rather than allowing it to alter
        // retention anchors or diagnostics.
        guard canStartPass(
            timestamp: timestamp,
            epoch: epoch,
            requestSequence: requestSequence
        ) else {
            return
        }
        let historyLoadNow = usesLiveClock ? dateProvider() : timestamp
        await loadHistoryIfNeeded(at: historyLoadNow)
        let samplingTimestamp = usesLiveClock ? dateProvider() : timestamp
        guard samplingTimestamp.timeIntervalSince1970.isFinite else { return }
        let mode = samplingPolicy.samplingMode(
            panelPresented: isPanelPresented,
            pressureActive: pressureEvaluator.pressureActiveForSampling,
            now: samplingTimestamp,
            lastProcessSampleAt: lastUsableProcessSampleAt
        )
        let snapshot = await sampler.sample(mode: mode, at: samplingTimestamp)
        guard snapshot.timestamp.timeIntervalSince1970.isFinite else { return }
        await apply(
            snapshot: snapshot,
            persistenceNow: snapshot.timestamp,
            usesLiveClock: usesLiveClock,
            epoch: epoch,
            requestSequence: requestSequence
        )
    }

    private func enqueueRefresh(
        at timestamp: Date,
        usesLiveClock: Bool,
        epoch: UInt64,
        requestSequence: UInt64
    ) async {
        guard !isShuttingDown else { return }
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                queuedRefreshes.append(
                    QueuedRefresh(
                        timestamp: timestamp,
                        usesLiveClock: usesLiveClock,
                        epoch: epoch,
                        requestSequence: requestSequence,
                        token: token,
                        continuation: continuation
                    )
                )
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelQueuedRefresh(token: token)
            }
        }
    }

    private func cancelQueuedRefresh(token: UUID) {
        guard !queuedRefreshes.isEmpty else { return }
        var retained: [QueuedRefresh] = []
        retained.reserveCapacity(queuedRefreshes.count)
        for waiter in queuedRefreshes {
            if waiter.token == token {
                waiter.continuation.resume()
            } else {
                retained.append(waiter)
            }
        }
        queuedRefreshes = retained
    }

    private func loadHistoryIfNeeded(at timestamp: Date) async {
        if historyLoaded {
            guard !historyStoreAvailable,
                  let retryAfter = historyRetryAfter,
                  timestamp >= retryAfter else {
                return
            }
        }
        do {
            let loadedRecords = try await historyStore.load(now: timestamp)
            var recoveredRecords = loadedRecords
            if !fallbackHistory.isEmpty {
                recoveredRecords = try await historyStore.merge(
                    records: fallbackHistory,
                    now: timestamp
                )
            }
            // A previous write failure may have left pending records in the
            // actor. Retry the durable write before declaring the store
            // recovered.
            try await historyStore.flush(now: timestamp)
            recoveredRecords = try await historyStore.currentRecords(now: timestamp)
            history = recoveredRecords
            fallbackHistory.removeAll(keepingCapacity: false)
            historyError = nil
            historyStoreAvailable = true
            historyRetryAfter = nil
            historyRetryAttempt = 0
        } catch {
            historyStoreAvailable = false
            historyError = error.localizedDescription
            scheduleHistoryRetry(after: timestamp)
        }
        historyDiagnostics = await historyStore.diagnostics()
        historyLoaded = true
    }

    private func apply(
        snapshot: MonitorSnapshot,
        persistenceNow: Date,
        usesLiveClock: Bool,
        epoch: UInt64,
        requestSequence: UInt64
    ) async {
        guard acceptsPass(
            timestamp: snapshot.timestamp,
            epoch: epoch,
            requestSequence: requestSequence
        ) else {
            return
        }

        let processSampleAttempted = snapshot.didSampleProcesses
        // Keep the exact provider timestamp for freshness and history. The
        // snapshot timestamp describes the enclosing pass and may differ from
        // the process scan's completion instant.
        let processSampledAt = snapshot.validatedProcessSampleAt
        let processSampleIsMonotonic = processSampledAt.map { sampledAt in
            guard let previous = lastUsableProcessSampleAt else { return true }
            return sampledAt >= previous
        } ?? false
        let processSampleUsable = snapshot.processDataIsUsable
            && processSampledAt != nil
            && processSampleIsMonotonic
        let workloadInventoryIsComplete = processSampleUsable
            && snapshot.sampledProcessCount > 0
            && snapshot.sampledProcessCount == snapshot.listedProcessCount

        samplingDiagnostics = snapshot.diagnostics
        systemStatus = snapshot.systemStatus
        systemDataIsUsable = snapshot.systemDataIsUsable
        cpuStatus = snapshot.cpuStatus
        gpuStatus = snapshot.gpuStatus

        if processSampleAttempted {
            processStatus = snapshot.processStatus
        }

        // A low-coverage scan, including 0/N, is still useful diagnostic
        // evidence. Publish its counts without replacing the retained rows;
        // otherwise the health panel would report the previous full scan as
        // if it were the current coverage. A thrown 0/0 attempt carries no
        // inventory evidence and therefore leaves the previous counts intact.
        if snapshot.processSamplingSucceeded
            || (snapshot.didSampleProcesses && snapshot.listedProcessCount > 0) {
            observedProcessCount = snapshot.sampledProcessCount
            listedProcessCount = snapshot.listedProcessCount
        }

        if processSampleUsable {
            if let processSampledAt {
                processCPUPercent = processCPUBaseline.update(snapshot.processes, at: processSampledAt)
            }
            lastUsableProcessSampleAt = processSampledAt
            processes = snapshot.processes
            groups = snapshot.groups
        }

        if let systemSnapshot = snapshot.validatedSystemSample {
            if usesLiveClock {
                let observationInstant = refreshClock.now
                let elapsed = lastPressureObservationInstant.map {
                    Self.elapsedSeconds(from: $0, to: observationInstant)
                }
                if lastPressureObservationInstant == nil {
                    pressureEvaluator.interruptPendingTransition()
                }
                pressureLevel = pressureEvaluator.update(
                    snapshot: systemSnapshot,
                    elapsedSincePrevious: elapsed
                )
                lastPressureObservationInstant = observationInstant
            } else {
                lastPressureObservationInstant = nil
                pressureLevel = pressureEvaluator.update(snapshot: systemSnapshot)
            }
            let historyGroups = processSampleUsable ? snapshot.groups : []
            if historyStoreAvailable {
                do {
                    history = try await historyStore.append(
                        snapshot: systemSnapshot,
                        groups: historyGroups,
                        workloadsSampledAt: processSampleUsable
                            ? processSampledAt
                            : nil,
                        workloadInventoryIsComplete: processSampleUsable
                            ? workloadInventoryIsComplete
                            : nil,
                        now: persistenceNow
                    )
                    historyError = nil
                    historyRetryAfter = nil
                    historyRetryAttempt = 0
                    historyDiagnostics = await historyStore.diagnostics()
                } catch {
                    historyStoreAvailable = false
                    historyError = error.localizedDescription
                    scheduleHistoryRetry(after: persistenceNow)
                    appendFallbackHistory(
                        snapshot: systemSnapshot,
                        groups: historyGroups,
                        workloadsSampledAt: processSampleUsable
                            ? processSampledAt
                            : nil,
                        workloadInventoryIsComplete: processSampleUsable
                            ? workloadInventoryIsComplete
                            : nil,
                        now: persistenceNow
                    )
                    historyDiagnostics = await historyStore.diagnostics()
                }
            } else {
                appendFallbackHistory(
                    snapshot: systemSnapshot,
                    groups: historyGroups,
                    workloadsSampledAt: processSampleUsable
                        ? processSampledAt
                        : nil,
                    workloadInventoryIsComplete: processSampleUsable
                        ? workloadInventoryIsComplete
                        : nil,
                    now: persistenceNow
                )
            }
            system = systemSnapshot
        } else {
            pressureEvaluator.interruptPendingTransition()
            lastPressureObservationInstant = nil
        }

        if let cpuTime = snapshot.cpuTime, snapshot.cpuStatus.quality.isUsable {
            cpuUsageFraction = previousCPUTime.flatMap {
                CPUUsageCalculator.usedFraction(current: cpuTime, previous: $0)
            }
            previousCPUTime = cpuTime
        } else {
            cpuUsageFraction = nil
            previousCPUTime = nil
        }

        gpuUsageFraction = snapshot.gpuStatus.quality.isUsable
            ? snapshot.gpuUsageFraction
            : nil

        updatedAt = snapshot.timestamp
    }

    /// Orders queued refreshes by clock generation, wall-clock sample time,
    /// and request sequence. A request from the new clock generation must win
    /// even though its wall time is earlier than every pre-rollback request.
    private static func refreshRequestPrecedes(
        _ lhs: QueuedRefresh,
        _ rhs: QueuedRefresh
    ) -> Bool {
        if lhs.epoch != rhs.epoch {
            return lhs.epoch < rhs.epoch
        }
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        return lhs.requestSequence < rhs.requestSequence
    }

    private static func elapsedSeconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> TimeInterval {
        guard end >= start else { return 0 }
        let components = start.duration(to: end).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private func refreshEpochForRequest(
        at timestamp: Date,
        observedAt instant: ContinuousClock.Instant
    ) -> UInt64 {
        defer {
            lastObservedRefreshRequest = (timestamp: timestamp, instant: instant)
        }
        guard let previousRequest = lastObservedRefreshRequest,
              instant >= previousRequest.instant,
              let lastAcceptedPass,
              lastAcceptedPass.epoch == refreshEpoch else {
            return refreshEpoch
        }

        let wallDelta = timestamp.timeIntervalSince(previousRequest.timestamp)
        guard wallDelta.isFinite,
              wallDelta < -clockRollbackTolerance else {
            return refreshEpoch
        }

        refreshEpoch &+= 1
        resetCrossClockBaselines(now: timestamp)
        return refreshEpoch
    }

    /// Records captured under the previous wall-clock generation may be
    /// "future" relative to the new clock. Keeping them in the fallback buffer
    /// makes `HistoryStore.merge` reject the whole recovery batch, so drop
    /// only the records that cannot be accepted by the new generation.
    static func fallbackRecordsForNewClock(
        _ records: [MemoryHistoryRecord],
        now: Date,
        allowance: TimeInterval = HistoryStore.maximumFutureSkew
    ) -> [MemoryHistoryRecord] {
        guard now.timeIntervalSince1970.isFinite,
              allowance.isFinite,
              allowance >= 0 else {
            return []
        }
        return records.filter { record in
            isDateWithinFutureSkew(record.timestamp, now: now, allowance: allowance)
                && (record.sourceSampledAt.map {
                    isDateWithinFutureSkew($0, now: now, allowance: allowance)
                } ?? true)
                && (record.workloadsSampledAt.map {
                    isDateWithinFutureSkew($0, now: now, allowance: allowance)
                } ?? true)
        }
    }

    private static func isDateWithinFutureSkew(
        _ date: Date,
        now: Date,
        allowance: TimeInterval
    ) -> Bool {
        let dateSeconds = date.timeIntervalSince1970
        let nowSeconds = now.timeIntervalSince1970
        guard dateSeconds.isFinite,
              nowSeconds.isFinite,
              allowance.isFinite,
              allowance >= 0,
              nowSeconds <= 253_402_300_799 - allowance else {
            return false
        }
        return dateSeconds <= nowSeconds + allowance
    }

    private func resetCrossClockBaselines(now: Date) {
        lastAcceptedPass = nil
        previousCPUTime = nil
        cpuUsageFraction = nil
        lastUsableProcessSampleAt = nil
        pressureEvaluator = MemoryPressureEvaluator(
            transitionIntervalSeconds: pressureEvaluator.transitionIntervalSeconds,
            maximumObservationGapSeconds: pressureEvaluator.maximumObservationGapSeconds
        )
        lastPressureObservationInstant = nil
        pressureLevel = nil
        systemDataIsUsable = false
        // A Date-based retry deadline belongs to the previous wall-clock
        // generation. Permit one immediate recovery attempt in the new one.
        historyRetryAfter = nil
        historyRetryAttempt = 0
        fallbackHistory = Self.fallbackRecordsForNewClock(
            fallbackHistory,
            now: now
        )
    }

    /// Checks a request before doing provider/history work. The actual
    /// snapshot is checked again after the provider returns because its own
    /// timestamp is the authoritative ordering key.
    private func canStartPass(
        timestamp: Date,
        epoch: UInt64,
        requestSequence: UInt64
    ) -> Bool {
        let seconds = timestamp.timeIntervalSince1970
        guard seconds.isFinite, epoch == refreshEpoch else { return false }
        guard let lastAcceptedPass else { return true }
        guard epoch == lastAcceptedPass.epoch else {
            return epoch > lastAcceptedPass.epoch
        }
        if timestamp < lastAcceptedPass.timestamp {
            return false
        }
        return timestamp != lastAcceptedPass.timestamp
            || requestSequence >= lastAcceptedPass.requestSequence
    }

    /// A pass is accepted only if it cannot move the displayed timeline or its
    /// associated baselines backwards. Equal timestamps are accepted in newer
    /// request order so a same-minute refresh can still replace its payload.
    private func acceptsPass(
        timestamp: Date,
        epoch: UInt64,
        requestSequence: UInt64
    ) -> Bool {
        let seconds = timestamp.timeIntervalSince1970
        guard seconds.isFinite else { return false }
        if !canStartPass(
            timestamp: timestamp,
            epoch: epoch,
            requestSequence: requestSequence
        ) {
            return false
        }
        lastAcceptedPass = (
            timestamp: timestamp,
            epoch: epoch,
            requestSequence: requestSequence
        )
        return true
    }

    private func scheduleHistoryRetry(after timestamp: Date) {
        let attempt = min(historyRetryAttempt, 4)
        let multiplier = pow(2, Double(attempt))
        let delay = min(historyRetryBaseInterval * multiplier, historyRetryMaxInterval)
        historyRetryAfter = timestamp.addingTimeInterval(delay)
        historyRetryAttempt = min(historyRetryAttempt + 1, 5)
    }

    /// Keeps the already loaded 24-hour history visible when the disk store
    /// is temporarily unavailable. The previous implementation replaced it
    /// with a 60-entry ring, which made a transient write error look like data
    /// loss. Records are coalesced to the same minute as `HistoryStore`.
    private func appendFallbackHistory(
        snapshot: SystemMemorySnapshot,
        groups: [WorkloadGroupSnapshot],
        workloadsSampledAt: Date?,
        workloadInventoryIsComplete: Bool?,
        now: Date
    ) {
        guard let minute = persistableMinuteBucket(snapshot.timestamp),
              isHistoryDateWithinFutureSkew(minute, now: now),
              isHistoryDateWithinFutureSkew(snapshot.timestamp, now: now),
              (workloadsSampledAt.map {
                  isHistoryDateWithinFutureSkew($0, now: now)
              } ?? true),
              let cutoff = historyCutoff(now: now) else {
            // The durable store applies the same validation. Do not let the
            // in-memory fallback become a side channel for invalid dates.
            return
        }
        let candidate = MemoryHistoryRecord(
            timestamp: minute,
            availableFraction: snapshot.availableFraction,
            compressedBytes: snapshot.compressedBytes,
            swapUsedBytes: snapshot.swapUsedBytes,
            workloads: HistoryStore.compactedWorkloads(
                groups.map(PersistedWorkloadRecord.init(group:)),
                limit: HistoryStore.defaultMaxPersistedWorkloads
            ),
            workloadsSampledAt: workloadsSampledAt,
            workloadInventoryIsComplete: workloadInventoryIsComplete,
            sourceSampledAt: snapshot.timestamp
        )

        mergeFallbackRecord(candidate, now: now)

        if let index = history.firstIndex(where: { $0.timestamp == minute }) {
            let previous = history[index]
            history[index] = HistoryStore.preferredRecord(
                existing: previous,
                candidate: candidate
            )
        } else {
            history.append(candidate)
        }

        history = history
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func mergeFallbackRecord(_ candidate: MemoryHistoryRecord, now: Date) {
        if let index = fallbackHistory.firstIndex(where: { $0.timestamp == candidate.timestamp }) {
            let previous = fallbackHistory[index]
            fallbackHistory[index] = HistoryStore.preferredRecord(
                existing: previous,
                candidate: candidate
            )
        } else {
            fallbackHistory.append(candidate)
        }

        guard let cutoff = historyCutoff(now: now) else { return }
        fallbackHistory = fallbackHistory
            .filter { $0.timestamp >= cutoff }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private func persistableMinuteBucket(_ date: Date) -> Date? {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite,
              seconds >= -62_135_596_800,
              seconds <= 253_402_300_799 else {
            return nil
        }
        let bucket = floor(seconds / 60)
        let normalized = bucket * 60
        guard bucket.isFinite,
              normalized.isFinite,
              normalized >= -62_135_596_800,
              normalized <= 253_402_300_799 else {
            return nil
        }
        return Date(timeIntervalSince1970: normalized)
    }

    private func isHistoryDateWithinFutureSkew(_ date: Date, now: Date) -> Bool {
        let dateSeconds = date.timeIntervalSince1970
        let nowSeconds = now.timeIntervalSince1970
        guard dateSeconds.isFinite,
              nowSeconds.isFinite,
              nowSeconds <= 253_402_300_799 - HistoryStore.maximumFutureSkew else {
            return false
        }
        return dateSeconds <= nowSeconds + HistoryStore.maximumFutureSkew
    }

    private func historyCutoff(now: Date) -> Date? {
        let nowSeconds = now.timeIntervalSince1970
        let cutoff = nowSeconds - historyRetentionInterval
        guard nowSeconds.isFinite,
              cutoff.isFinite,
              cutoff >= -62_135_596_800,
              cutoff <= 253_402_300_799 else {
            return nil
        }
        return Date(timeIntervalSince1970: cutoff)
    }

    private static func waitForNextSample(
        interval: TimeInterval,
        wakeup: RefreshWakeup
    ) async -> Bool {
        return await withTaskGroup(of: RefreshWaitResult.self) { group in
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(interval))
                    return .intervalElapsed
                } catch {
                    return .cancelled
                }
            }
            group.addTask {
                guard await wakeup.wait() else { return .cancelled }
                return .wakeup
            }

            guard let result = await group.next() else { return false }
            group.cancelAll()
            return result != .cancelled
        }
    }
}

private enum RefreshWaitResult: Sendable {
    case intervalElapsed
    case wakeup
    case cancelled
}

/// A one-slot async signal used to interrupt the current cadence when the
/// popover opens or closes. A continuation keeps the wakeup path fully
/// actor-isolated and cancellation-safe.
private actor RefreshWakeup {
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var waiter: Waiter?
    private var pendingSignal = false

    func signal() {
        if let waiter {
            self.waiter = nil
            waiter.continuation.resume(returning: true)
        } else {
            pendingSignal = true
        }
    }

    func wait() async -> Bool {
        guard !Task.isCancelled else { return false }
        if pendingSignal {
            pendingSignal = false
            return true
        }

        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiter = Waiter(token: token, continuation: continuation)
                }
            }
        } onCancel: {
            // Cancellation is delivered through a separate actor hop. Keep a
            // token with the continuation so a delayed callback from an old
            // wait cannot cancel a newer waiter installed in the meantime.
            Task { await self.cancelWaiter(token: token) }
        }
    }

    private func cancelWaiter(token: UUID) {
        guard let waiter, waiter.token == token else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: false)
    }
}

enum PressureState: String {
    case normal
    case attention
    case critical
    case unknown

    init(level: MemoryPressureLevel) {
        switch level {
        case .normal:
            self = .normal
        case .attention:
            self = .attention
        case .critical:
            self = .critical
        }
    }

    var title: String {
        switch self {
        case .normal: return "正常"
        case .attention: return "注意"
        case .critical: return "严重"
        case .unknown: return "采集中"
        }
    }

    var color: Color {
        switch self {
        case .normal: return .green
        case .attention: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }
}

private struct MenuBarStatus: View {
    @ObservedObject var model: MonitorViewModel
    let terminationAction: ApplicationTerminationAction
    @AppStorage("menuBarShowsPercentage") private var showsPercentage = true

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(model.pressure.color)
                .frame(width: 7, height: 7)
            if showsPercentage { Text(
                model.systemDataIsUsable
                    ? (model.system.map { "内存 \(Int($0.usedFraction * 100))%" } ?? "内存 --")
                    : "内存 --"
            )
                .font(.system(size: 12, weight: .medium, design: .rounded))
            } else {
                Image(nsImage: MemoryMonitorMark.menuBarImage).accessibilityHidden(true)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                terminationAction()
            } label: {
                Label("退出 Memory Monitor", systemImage: "power")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory Monitor 状态")
        .accessibilityValue(
            model.systemDataIsUsable
                ? (model.system.map {
                    "内存使用率 \(Int($0.usedFraction * 100))%，\(model.pressure.title)，数据可用"
                } ?? "内存数据不可用")
                : "内存数据不可用，\(model.pressure.title)"
        )
    }
}

struct ProcessDetailView: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var actions: ProcessActionController
    let identity: ProcessIdentity
    @Environment(\.dismiss) private var dismiss
    @State private var showGracefulConfirmation = false
    @State private var showForceConfirmation = false

    private var dataStatus: MonitorDetailDataStatus {
        model.detailDataStatus(
            retainedItemCount: model.processes.count,
            targetPresent: model.process(for: identity) != nil
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    Text(model.process(for: identity).map {
                        $0.applicationName ?? processDisplayName($0)
                    } ?? "进程已不可用")
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                    .accessibilityLabel("关闭进程详情")
                }
                if let notice = SimpleMonitorPresentation.listNotice(status: dataStatus) {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let process = model.process(for: identity) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("内存占用")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text((process.physicalFootprintIsEstimated ? "约 " : "")
                            + SimpleMonitorPresentation.memory(process.physicalFootprintBytes))
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .minimumScaleFactor(0.7)
                    }
                    Text("进程编号 " + String(process.identity.pid))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    actionsContent(process)
                } else {
                    Text("它可能已退出，或暂时无法读取。")
                        .foregroundStyle(.secondary)
                    actionStatus
                    if actions.canCancel(for: identity) {
                        Button("停止等待", systemImage: "stop.circle") {
                            actions.cancel(for: identity)
                        }
                    }
                }
                if actions.auditError != nil {
                    Label("操作记录暂时无法保存", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            minWidth: 380,
            idealWidth: 380,
            maxWidth: 380,
            minHeight: 240,
            idealHeight: 420,
            maxHeight: 560,
            alignment: .leading
        )
        .confirmationDialog(
            "退出这个进程？",
            isPresented: $showGracefulConfirmation,
            titleVisibility: .visible
        ) {
            Button("退出进程", role: .destructive) {
                if let process = model.process(for: identity) {
                    actions.requestGracefulExit(for: process)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先保存工作。退出请求可能中断正在进行的任务；若没有响应，可再选择强制结束。")
        }
        .confirmationDialog(
            "强制结束这个进程？",
            isPresented: $showForceConfirmation,
            titleVisibility: .visible
        ) {
            Button("强制结束", role: .destructive) {
                if let process = model.process(for: identity) {
                    actions.requestForceTerminate(for: process)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("进程会立即关闭，未保存的内容可能丢失。")
        }
    }

    @ViewBuilder
    private var actionStatus: some View {
        if let status = actions.status(for: identity) {
            ProcessActionStatusRow(status: status)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button("退出进程", systemImage: "rectangle.portrait.and.arrow.right") {
            showGracefulConfirmation = true
        }
        .disabled(!actions.manualActionAvailability.isEnabled || actions.canForceTerminate(for: identity))
        if actions.canForceTerminate(for: identity) {
            Button("强制结束", systemImage: "xmark.octagon", role: .destructive) {
                showForceConfirmation = true
            }
        }
        if actions.canCancel(for: identity) {
            Button {
                actions.cancel(for: identity)
            } label: {
                Image(systemName: "stop.circle")
            }
            .help("停止等待")
            .accessibilityLabel("停止等待")
        }
    }

    @ViewBuilder
    private func actionsContent(_ process: ProcessSnapshot) -> some View {
        let validation = actions.eligibility(for: process)
        actionStatus
        if actions.isBusy, actions.status(for: identity) == nil {
            Label("另一个进程操作进行中，请稍后再试。", systemImage: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if validation.allowed {
            let availability = actions.manualActionAvailability
            if let reason = availability.reason, !availability.isEnabled {
                Label(reason, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actionButtons }
                VStack(alignment: .leading, spacing: 8) { actionButtons }
            }
            .buttonStyle(.bordered)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Label("这个进程暂不支持退出", systemImage: "lock")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(validation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProcessActionStatusRow: View {
    let status: ProcessActionStatus

    private var color: Color {
        switch status.tone {
        case .neutral: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    var body: some View {
        Label(status.message, systemImage: status.tone.iconName)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }
}

private func processDisplayName(_ process: ProcessSnapshot) -> String {
    if let applicationName = process.applicationName, !applicationName.isEmpty {
        return applicationName
    }
    return process.name
}

private func executableLabel(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let basename = URL(fileURLWithPath: path).lastPathComponent
    return WorkingDirectoryLabelSanitizer.label(fromComponent: basename)
}

private func detailDateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.string(from: date)
}

private func cpuDurationLabel(_ nanoseconds: UInt64) -> String {
    let seconds = Double(nanoseconds) / 1_000_000_000
    guard seconds.isFinite else { return "--" }
    if seconds < 1 {
        return "\(nanoseconds / 1_000_000) ms"
    }
    if seconds < 60 {
        return String(format: "%.1f 秒", seconds)
    }
    let minutes = Int(seconds) / 60
    let remainder = Int(seconds) % 60
    if minutes < 60 {
        return "\(minutes) 分 \(remainder) 秒"
    }
    let hours = minutes / 60
    return "\(hours) 小时 \(minutes % 60) 分"
}

private func attributionConfidence(_ reason: WorkloadAttributionReason) -> String {
    switch reason {
    case .systemProcess, .codexSession, .codexAncestor, .safariAncestor,
         .chromeIdentity, .ghosttyAncestor, .maibotIdentity, .virtualizationIdentity:
        return "较高"
    case .runtimeWorkingDirectory, .runtimeAncestorWorkingDirectory:
        return "中等"
    case .unattributedWebKit, .runtimeFallback, .processName:
        return "有限"
    }
}

private func attributionExplanation(_ reason: WorkloadAttributionReason) -> String {
    switch reason {
    case .systemProcess:
        return "该组由系统标记、UID 0 或受保护的系统进程组成，默认只作为观察对象。"
    case .codexSession, .codexAncestor:
        return "通过 Codex 标识或父链将浏览器、Node 等子进程归入同一工作会话。"
    case .safariAncestor:
        return "通过父链中的 Safari 根进程归属 WebKit 子进程。"
    case .unattributedWebKit:
        return "进程具备 WebKit 特征，但当前快照没有找到 Safari 父链，因此单独列为未归属。"
    case .chromeIdentity:
        return "通过应用标识、可执行路径或进程名中的 Chrome/Chromium 特征归类。"
    case .ghosttyAncestor:
        return "通过 Ghostty 父链归入终端及其开发服务。"
    case .maibotIdentity:
        return "通过进程或可执行路径中的 MaiBot 特征归类。"
    case .virtualizationIdentity:
        return "通过虚拟化运行时标识归类，可能代表正在运行的虚拟机。"
    case .runtimeWorkingDirectory, .runtimeAncestorWorkingDirectory:
        return "通过 Node/Python 运行时和脱敏工作目录标签细分，目录原始路径不会进入界面或历史。"
    case .runtimeFallback:
        return "仅取得运行时名称，未能读取工作目录，可能与其他同名服务合并。"
    case .processName:
        return "仅依据进程名称归类，属于最低确定性的兜底规则。"
    }
}
