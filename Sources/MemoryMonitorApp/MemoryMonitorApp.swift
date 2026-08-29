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
            MonitorPopover(
                model: applicationDelegate.model,
                processActions: applicationDelegate.model.processActions,
                terminationAction: applicationDelegate.terminationAction
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
    }
}

@MainActor
final class MemoryMonitorApplicationDelegate: NSObject, NSApplicationDelegate {
    let model: MonitorViewModel
    let terminationAction = ApplicationTerminationAction()
    private let terminationCoordinator: ApplicationTerminationCoordinator

    override convenience init() {
        self.init(model: MonitorViewModel())
    }

    init(
        model: MonitorViewModel,
        terminationTimeoutSeconds: TimeInterval = 5
    ) {
        self.model = model
        terminationCoordinator = ApplicationTerminationCoordinator(
            timeoutSeconds: terminationTimeoutSeconds
        )
        super.init()
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
    @Published private(set) var cpuUsageFraction: Double?
    @Published private(set) var cpuStatus = SampleStatus.unavailable(message: "等待首次采样")
    @Published private(set) var gpuUsageFraction: Double?
    @Published private(set) var gpuStatus = SampleStatus.unavailable(message: "等待首次采样")
    @Published private(set) var processes: [ProcessSnapshot] = []
    @Published private(set) var groups: [WorkloadGroupSnapshot] = []
    @Published private(set) var processStatus = SampleStatus.unavailable(message: "等待首次采样")
    @Published private(set) var observedProcessCount = 0
    @Published private(set) var listedProcessCount = 0
    @Published private(set) var history: [MemoryHistoryRecord] = []
    @Published private(set) var lastError: String?
    @Published private(set) var historyError: String?
    @Published private(set) var historyDiagnostics: HistoryStoreDiagnostics?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isPanelPresented = false
    @Published private(set) var pressureLevel: MemoryPressureLevel?
    @Published private(set) var samplingDiagnostics = SamplingDiagnostics(
        mode: .background,
        totalDurationMilliseconds: 0,
        processDurationMilliseconds: nil,
        processSamplingPerformed: false,
        processCount: 0,
        listedProcessCount: 0
    )
    @Published private(set) var recommendation: MemoryRecommendation?
    @Published private(set) var healthCheckedAt = Date()

    let processActions: ProcessActionController
    let loginLaunch: LoginLaunchCoordinator
    private var refreshTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownCompleted = false
    private var isShuttingDown = false
    private var refreshIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private let sampler: any MonitorSamplingSource
    private let samplingPolicy = AdaptiveSamplingPolicy()
    private let recommendationEngine = RecommendationEngine()
    private let historyAnalyzer = MemoryHistoryAnalyzer()
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
    private var previousRecommendationSystem: SystemMemorySnapshot?
    private var previousRecommendationProcessSystem: SystemMemorySnapshot?
    private var previousRecommendationGroups: [WorkloadGroupSnapshot] = []
    private var previousRecommendationProcessStatus: SampleStatus?
    private var previousRecommendationProcessInventoryIsComplete = false
    private var previousRecommendationPressureLevel: MemoryPressureLevel?
    private var lastRecommendationKey: String?
    private var lastRecommendationAt: Date?
    private let recommendationCooldown: TimeInterval = 30 * 60
    private let recommendationTTL: TimeInterval
    private let monitorProcessID = Int32(ProcessInfo.processInfo.processIdentifier)

    init(
        loginLaunchRuntime: (any LoginLaunchRuntime)? = nil,
        sampler: any MonitorSamplingSource = MonitorSampler(),
        historyStore: HistoryStore = HistoryStore(),
        processActions: ProcessActionController? = nil,
        recommendationTTL: TimeInterval = 5 * 60,
        dateProvider: @escaping @MainActor () -> Date = { Date() },
        startRefreshTask: Bool = true
    ) {
        self.processActions = processActions ?? ProcessActionController()
        loginLaunch = LoginLaunchCoordinator(runtime: loginLaunchRuntime)
        self.sampler = sampler
        self.historyStore = historyStore
        self.recommendationTTL = recommendationTTL.isFinite && recommendationTTL >= 0
            ? recommendationTTL
            : 5 * 60
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

    var processObservationDescription: String {
        switch processStatus.quality {
        case .available:
            return "已采集 \(observedProcessCount) 个进程"
        case .estimated:
            let observed = observedProcessCount > 0
                ? observedProcessCount
                : samplingDiagnostics.processCount
            let listed = listedProcessCount > 0
                ? listedProcessCount
                : samplingDiagnostics.listedProcessCount
            return observed > 0
                ? "已采集 \(observed)/\(listed) 个进程"
                : "进程数据部分可用"
        case .unavailable, .error:
            return observedProcessCount > 0
                ? "上次采样 \(observedProcessCount) 个进程"
                : "进程数据 \(processStatus.quality.displayName)"
        }
    }

    var samplingIssueDescription: String? {
        if !systemDataIsUsable, systemStatus.quality.isUsable {
            return "系统采样时间无效或与当前采样不一致"
        }
        let statuses = [systemStatus, cpuStatus, gpuStatus, processStatus]
        let issues = statuses.compactMap { status -> String? in
            guard status.quality == .error else { return nil }
            return status.message
        }
        return issues.isEmpty ? nil : issues.joined(separator: "；")
    }

    var samplingNoticeDescription: String? {
        if samplingIssueDescription != nil {
            return "部分采样源失败，未用 0 覆盖已有数据"
        }
        if !samplingDiagnostics.processSamplingPerformed, !processes.isEmpty {
            return "后台低频观察中，进程排行显示最近一次成功采样"
        }
        return processStatus.quality == .estimated
            ? "进程列表部分可用，已保留成功读取的条目"
            : nil
    }

    var samplingCadenceDescription: String {
        return samplingPolicy.cadenceDescription(
            panelPresented: isPanelPresented,
            pressureActive: pressureEvaluator.pressureActiveForSampling
        )
    }

    var samplingDiagnosticsDescription: String {
        let duration = String(format: "%.0f ms", samplingDiagnostics.totalDurationMilliseconds)
        if samplingDiagnostics.processSamplingPerformed {
            return "\(samplingDiagnostics.mode.displayName) · 本轮 \(duration)"
        }
        return "\(samplingDiagnostics.mode.displayName) · 本轮 \(duration) · 进程未刷新"
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

    var historyAnalysis: MemoryHistoryAnalysis {
        historyAnalyzer.analyze(history)
    }

    func process(for identity: ProcessIdentity) -> ProcessSnapshot? {
        processes.first { $0.identity == identity }
    }

    func group(for id: String) -> WorkloadGroupSnapshot? {
        groups.first { $0.id == id }
    }

    func group(containing identity: ProcessIdentity) -> WorkloadGroupSnapshot? {
        groups.first { group in
            group.memberProcessIdentities.contains(identity)
        }
    }

    func detailDataStatus(retainedItemCount: Int) -> MonitorDetailDataStatus {
        MonitorDetailDataStatus.resolve(
            processStatus: processStatus,
            samplingDiagnostics: samplingDiagnostics,
            retainedItemCount: retainedItemCount,
            observedAt: updatedAt,
            lastSuccessfulSampledAt: lastUsableProcessSampleAt
        )
    }

    func processes(in group: WorkloadGroupSnapshot) -> [ProcessSnapshot] {
        let identities = Set(group.memberProcessIdentities)
        return processes
            .filter { identities.contains($0.identity) }
            .sorted(by: ProcessSnapshot.memoryDescending)
    }

    /// Resolves only the names present in the current snapshot. A missing
    /// parent is expected when it exited between sampling passes.
    func parentChain(for process: ProcessSnapshot, limit: Int = 8) -> [ProcessSnapshot] {
        guard limit > 0 else { return [] }
        var result: [ProcessSnapshot] = []
        var visited = Set<Int32>()
        var parentPID = process.parentPID
        while parentPID > 0, result.count < limit, visited.insert(parentPID).inserted {
            guard let parent = processes.first(where: { $0.identity.pid == parentPID }) else {
                break
            }
            result.append(parent)
            parentPID = parent.parentPID
        }
        return result
    }

    func history(for groupID: String) -> [MemoryHistoryRecord] {
        history.filter { record in
            record.workloads.contains { $0.id == groupID }
        }
    }

    func historyEvents(for groupID: String) -> [MemoryHistoryEvent] {
        historyAnalysis.events.filter { $0.targetID == groupID }
    }

    func setPanelPresented(_ presented: Bool) {
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
        guard timestamp.timeIntervalSince1970.isFinite else {
            lastError = "采样时间无效"
            return
        }

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
        guard samplingTimestamp.timeIntervalSince1970.isFinite else {
            lastError = "采样时间无效"
            return
        }
        let mode = samplingPolicy.samplingMode(
            panelPresented: isPanelPresented,
            pressureActive: pressureEvaluator.pressureActiveForSampling,
            now: samplingTimestamp,
            lastProcessSampleAt: lastUsableProcessSampleAt
        )
        let snapshot = await sampler.sample(mode: mode, at: samplingTimestamp)
        guard snapshot.timestamp.timeIntervalSince1970.isFinite else {
            lastError = "采样源返回了无效时间"
            return
        }
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

        let recommendationContext = RecommendationContext(
            current: snapshot,
            previousSystem: previousRecommendationSystem,
            previousProcessSystem: previousRecommendationProcessSystem,
            previousGroups: previousRecommendationGroups,
            previousProcessStatus: previousRecommendationProcessStatus,
            previousProcessInventoryIsComplete: previousRecommendationProcessInventoryIsComplete,
            excludedProcessIDs: [monitorProcessID],
            pressureLevel: pressureLevel,
            previousPressureLevel: previousRecommendationPressureLevel
        )

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

        var availableRecommendationSources = Set<RecommendationSource>()
        if snapshot.systemDataIsUsable {
            availableRecommendationSources.insert(.system)
        }
        if processSampleUsable {
            availableRecommendationSources.insert(.processes)
        }
        updateRecommendation(
            recommendationEngine.evaluate(recommendationContext).first,
            at: snapshot.timestamp,
            availableSources: availableRecommendationSources
        )

        if processSampleUsable {
            // Process trends advance independently from the system source.
            // The optional system snapshot remains paired with this exact
            // process pass and contributes Swap evidence only when both ends
            // of the next comparison have such a pair.
            previousRecommendationProcessSystem = snapshot.validatedSystemSample
            previousRecommendationGroups = snapshot.groups
            previousRecommendationProcessStatus = snapshot.processStatus
            previousRecommendationProcessInventoryIsComplete =
                snapshot.sampledProcessCount > 0
                && snapshot.sampledProcessCount == snapshot.listedProcessCount
        }
        if let systemSnapshot = snapshot.validatedSystemSample,
           let pressureLevel,
           MemoryPressureEvaluator.observedLevel(for: systemSnapshot) == pressureLevel {
            // Do not relabel a pending recovery sample with the old stable
            // pressure level. The pair must remain at the last observation
            // that actually agreed with that stable level until transition.
            previousRecommendationSystem = systemSnapshot
            previousRecommendationPressureLevel = pressureLevel
        }

        updatedAt = snapshot.timestamp
        lastError = samplingIssueDescription
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
        resetCrossClockBaselines()
        return refreshEpoch
    }

    private func resetCrossClockBaselines() {
        lastAcceptedPass = nil
        previousCPUTime = nil
        cpuUsageFraction = nil
        lastUsableProcessSampleAt = nil
        previousRecommendationSystem = nil
        previousRecommendationProcessSystem = nil
        previousRecommendationGroups = []
        previousRecommendationProcessStatus = nil
        previousRecommendationProcessInventoryIsComplete = false
        previousRecommendationPressureLevel = nil
        pressureEvaluator = MemoryPressureEvaluator(
            transitionIntervalSeconds: pressureEvaluator.transitionIntervalSeconds,
            maximumObservationGapSeconds: pressureEvaluator.maximumObservationGapSeconds
        )
        lastPressureObservationInstant = nil
        pressureLevel = nil
        systemDataIsUsable = false
        recommendation = nil
        lastRecommendationKey = nil
        lastRecommendationAt = nil
        // A Date-based retry deadline belongs to the previous wall-clock
        // generation. Permit one immediate recovery attempt in the new one.
        historyRetryAfter = nil
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

    private func updateRecommendation(
        _ candidate: MemoryRecommendation?,
        at timestamp: Date,
        availableSources: Set<RecommendationSource>
    ) {
        guard let candidate,
              candidate.requiredSources.isSubset(of: availableSources) else {
            guard let recommendation else { return }
            if recommendation.requiredSources.isSubset(of: availableSources) {
                clearRecommendation()
                return
            }
            let age = timestamp.timeIntervalSince(recommendation.lastConfirmedAt)
            guard age.isFinite, age >= 0, age <= recommendationTTL else {
                clearRecommendation()
                return
            }
            return
        }

        if candidate.deduplicationKey == lastRecommendationKey,
           let recommendation,
           recommendationsHaveSameDisplayContent(recommendation, candidate),
           let lastRecommendationAt,
           timestamp.timeIntervalSince(lastRecommendationAt) >= 0,
           timestamp.timeIntervalSince(lastRecommendationAt) < recommendationCooldown {
            self.recommendation = recommendation.confirmed(at: timestamp)
            return
        }

        recommendation = candidate.confirmed(at: timestamp)
        lastRecommendationKey = candidate.deduplicationKey
        lastRecommendationAt = timestamp
    }

    private func clearRecommendation() {
        recommendation = nil
        lastRecommendationKey = nil
        lastRecommendationAt = nil
    }

    private func recommendationsHaveSameDisplayContent(
        _ lhs: MemoryRecommendation,
        _ rhs: MemoryRecommendation
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.severity == rhs.severity
            && lhs.title == rhs.title
            && lhs.detail == rhs.detail
            && lhs.evidence == rhs.evidence
            && lhs.confidence == rhs.confidence
            && lhs.targetGroupID == rhs.targetGroupID
            && lhs.requiredSources == rhs.requiredSources
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

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(model.pressure.color)
                .frame(width: 7, height: 7)
            Text(
                model.systemDataIsUsable
                    ? (model.system.map { "内存 \(Int($0.usedFraction * 100))%" } ?? "内存 --")
                    : "内存 --"
            )
                .font(.system(size: 12, weight: .medium, design: .rounded))
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
                ? (model.system.map { "内存使用率 \(Int($0.usedFraction * 100))%" } ?? "内存数据不可用")
                : "内存数据不可用"
        )
    }
}

private enum MonitorListMode: String, CaseIterable, Identifiable {
    case processes
    case groups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processes: return "进程排行"
        case .groups: return "工作组归因"
        }
    }
}

private enum ProcessScope: String, CaseIterable, Identifiable {
    case all
    case user
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .user: return "用户"
        case .system: return "系统"
        }
    }
}

private enum ProcessSortMode: String, CaseIterable, Identifiable {
    case footprint
    case resident

    var id: String { rawValue }

    var title: String {
        switch self {
        case .footprint: return "footprint"
        case .resident: return "RSS"
        }
    }
}

/// Explains why a filtered list currently has no visible rows. Keeping this
/// decision outside the view body prevents an empty result from being shown as
/// an initial loading state after a search or scope change.
enum MonitorListEmptyState: Equatable, Sendable {
    case loading
    case background
    case noMatches
    case failed(String)
    case noRows
    case stale

    static func resolve(
        visibleItemCount: Int,
        hasActiveFilter: Bool,
        samplingPerformed: Bool,
        retainedItemCount: Int,
        quality: SampleQuality,
        message: String?
    ) -> MonitorListEmptyState? {
        guard visibleItemCount <= 0 else { return nil }
        if hasActiveFilter {
            return .noMatches
        }
        if !samplingPerformed {
            return retainedItemCount > 0 ? .background : .loading
        }
        switch quality {
        case .error:
            return .failed(message ?? "无法读取进程列表")
        case .unavailable:
            return retainedItemCount > 0 ? .stale : .loading
        case .available, .estimated:
            return .noRows
        }
    }

    var title: String {
        switch self {
        case .loading: return "正在读取进程数据..."
        case .background: return "等待下一次进程采样"
        case .noMatches: return "没有匹配条目"
        case .failed: return "进程采样失败"
        case .noRows: return "本轮没有可展示条目"
        case .stale: return "暂时没有新进程数据"
        }
    }

    var message: String {
        switch self {
        case .loading:
            return "完成首次扫描后，进程和工作组会显示在这里。"
        case .background:
            return "后台采样暂未刷新进程排行，下一次扫描后会更新。"
        case .noMatches:
            return "尝试清除搜索或切换显示范围。"
        case .failed(let detail):
            return detail + "；请稍后重试或打开运行健康诊断。"
        case .noRows:
            return "进程可能在扫描期间退出，或受到 macOS 权限限制。"
        case .stale:
            return "最近一次列表未能更新；请稍后重试或打开运行健康诊断。"
        }
    }

    var systemImage: String {
        switch self {
        case .loading: return "hourglass"
        case .background: return "clock.arrow.circlepath"
        case .noMatches: return "magnifyingglass"
        case .failed: return "exclamationmark.triangle"
        case .noRows: return "list.bullet.rectangle"
        case .stale: return "arrow.clockwise"
        }
    }

    var shortStatus: String {
        switch self {
        case .loading: return "等待首次采样"
        case .background: return "后台未刷新"
        case .noMatches: return "无匹配"
        case .failed: return "采样失败"
        case .noRows: return "无可展示条目"
        case .stale: return "上次数据"
        }
    }
}

private enum MonitorDetailSelection: Identifiable {
    case process(ProcessIdentity)
    case group(String)

    var id: String {
        switch self {
        case .process(let identity):
            return "process-\(identity.pid)-\(identity.startTimeSeconds)-\(identity.startTimeMicroseconds)"
        case .group(let groupID):
            return "group-\(groupID)"
        }
    }
}

private enum MonitorViewMode: String, CaseIterable, Identifiable {
    case live
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: return "实时"
        case .history: return "24 小时"
        }
    }
}

private struct MonitorPopover: View {
    @ObservedObject var model: MonitorViewModel
    /// Process actions publish independently from monitor sampling. Observe
    /// the controller here so audit failures immediately affect the health
    /// indicator in the popover.
    @ObservedObject var processActions: ProcessActionController
    let terminationAction: ApplicationTerminationAction
    @State private var listMode: MonitorListMode = .processes
    @State private var viewMode: MonitorViewMode = .live
    @State private var processScope: ProcessScope = .all
    @State private var processSortMode: ProcessSortMode = .footprint
    @State private var searchText = ""
    @State private var detailSelection: MonitorDetailSelection?
    @State private var showHealthPanel = false
    @State private var showAuditPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Picker("视图", selection: $viewMode) {
                ForEach(MonitorViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch viewMode {
            case .live:
                liveContent
            case .history:
                HistoryPanel(model: model)
            }
        }
        .padding(16)
        .frame(width: 410)
        .sheet(item: $detailSelection) { selection in
            switch selection {
            case .process(let identity):
                ProcessDetailView(
                    model: model,
                    actions: model.processActions,
                    identity: identity
                )
            case .group(let groupID):
                WorkloadGroupDetailView(model: model, groupID: groupID)
            }
        }
        .sheet(isPresented: $showHealthPanel) {
            MonitorHealthPanel(
                model: model,
                processActions: processActions,
                loginLaunch: model.loginLaunch
            )
        }
        .sheet(isPresented: $showAuditPanel) {
            OperationsAuditPanel(actions: model.processActions)
        }
    }

    @ViewBuilder
    private var liveContent: some View {
        metrics
        recommendationCard
        samplingNotice
        processList
        footer
    }

    private var header: some View {
        let overall = healthOverall
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory Monitor")
                    .font(.system(size: 18, weight: .semibold))
                Text("全量进程观察 · \(model.processObservationDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.pressure.color)
                        .frame(width: 8, height: 8)
                    Text(model.systemDataIsUsable ? model.pressure.title : "采集受限")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(model.pressure.color)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    showHealthPanel = true
                } label: {
                    Image(systemName: overall.iconName)
                        .foregroundStyle(healthLevelColor(overall))
                }
                .buttonStyle(.borderless)
                .help("运行健康与权限诊断")
                .accessibilityLabel("运行健康与权限诊断")

                Button {
                    showAuditPanel = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("查看操作审计")
                .accessibilityLabel("查看操作审计")

                Menu {
                    Button(role: .destructive) {
                        terminationAction()
                    } label: {
                        Label("退出 Memory Monitor", systemImage: "power")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("更多操作")
                .accessibilityLabel("更多操作")

                if let updatedAt = model.updatedAt {
                    Text(updatedAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var healthOverall: MonitorHealthLevel {
        // Touch the nested observable explicitly so SwiftUI subscribes to its
        // objectWillChange stream while evaluating the computed health state.
        _ = processActions.auditError
        return model.healthSnapshot.overall
    }

    @ViewBuilder
    private var recommendationCard: some View {
        if let recommendation = model.recommendation {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: recommendationIcon(recommendation.severity))
                        .imageScale(.small)
                        .foregroundStyle(recommendationColor(recommendation.severity))
                    Text(recommendation.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(recommendation.severity.displayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(recommendationColor(recommendation.severity))
                }
                Text(recommendation.detail)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !recommendation.evidence.isEmpty {
                    Text(recommendation.evidence.prefix(3).map { "\($0.label) \($0.value)" }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 4) {
                    Text("置信度 \(recommendation.confidencePercent)% · 只读建议")
                    Spacer(minLength: 6)
                    Text(recommendation.lastConfirmedAt, style: .relative)
                    Text("前确认")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(9)
            .background(
                recommendationColor(recommendation.severity).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 7)
            )
        }
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            MetricTile(
                title: "CPU",
                fraction: model.cpuUsageFraction,
                status: model.cpuStatus
            )
            MetricTile(
                title: "内存",
                fraction: model.systemDataIsUsable ? model.system?.usedFraction : nil,
                status: model.systemStatus
            )
            MetricTile(
                title: "GPU",
                fraction: model.gpuUsageFraction,
                status: model.gpuStatus
            )
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("内存占用")
                    .font(.headline)
                Spacer()
                Text(sortSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("显示", selection: $listMode) {
                ForEach(MonitorListMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 6) {
                TextField("搜索进程或工作组", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Menu {
                    Picker("范围", selection: $processScope) {
                        ForEach(ProcessScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    Picker("排序", selection: $processSortMode) {
                        ForEach(ProcessSortMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .imageScale(.medium)
                }
                .menuStyle(.borderlessButton)
                .help("筛选与排序")
                .accessibilityLabel("筛选与排序")
            }

            switch listMode {
            case .processes:
                processRanking
            case .groups:
                groupRanking
            }
        }
    }

    @ViewBuilder
    private var samplingNotice: some View {
        if let notice = model.samplingNoticeDescription {
            HStack(spacing: 6) {
                Image(systemName: model.samplingIssueDescription == nil
                    ? "info.circle"
                    : "exclamationmark.triangle")
                    .imageScale(.small)
                Text(notice)
                    .font(.caption2)
                    .foregroundStyle(
                        model.samplingIssueDescription == nil ? Color.secondary : Color.orange
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var hasActiveListFilter: Bool {
        !normalizedSearchText.isEmpty || processScope != .all
    }

    private func emptyState(
        visibleItemCount: Int,
        retainedItemCount: Int
    ) -> MonitorListEmptyState? {
        MonitorListEmptyState.resolve(
            visibleItemCount: visibleItemCount,
            hasActiveFilter: hasActiveListFilter,
            samplingPerformed: model.samplingDiagnostics.processSamplingPerformed,
            retainedItemCount: retainedItemCount,
            quality: model.processStatus.quality,
            message: model.processStatus.message
        )
    }

    private var sortSummary: String {
        switch (listMode, processSortMode) {
        case (.processes, .footprint): return "footprint 降序"
        case (.processes, .resident): return "RSS 降序"
        case (.groups, .footprint): return "归因总量 · footprint"
        case (.groups, .resident): return "归因总量 · RSS"
        }
    }

    private func matchesSearch(_ process: ProcessSnapshot) -> Bool {
        guard !normalizedSearchText.isEmpty else { return true }
        let fields = [
            process.name,
            process.applicationName,
            process.bundleIdentifier,
            process.workingDirectoryLabel
        ].compactMap { $0?.lowercased() }
        return fields.contains { $0.contains(normalizedSearchText) }
    }

    private var sortedProcesses: [ProcessSnapshot] {
        let filtered = model.processes.filter { process in
            switch processScope {
            case .all: return true
            case .user: return !process.isSystem
            case .system: return process.isSystem
            }
        }.filter { process in
            matchesSearch(process)
        }

        switch processSortMode {
        case .footprint:
            return filtered.sorted(by: ProcessSnapshot.memoryDescending)
        case .resident:
            return filtered.sorted {
                if $0.residentBytes != $1.residentBytes {
                    return $0.residentBytes > $1.residentBytes
                }
                if $0.physicalFootprintBytes != $1.physicalFootprintBytes {
                    return $0.physicalFootprintBytes > $1.physicalFootprintBytes
                }
                return $0.identity.pid < $1.identity.pid
            }
        }
    }

    private var processStatusText: String {
        if let state = emptyState(
            visibleItemCount: sortedProcesses.count,
            retainedItemCount: model.processes.count
        ) {
            return state.shortStatus
        }
        if !model.samplingDiagnostics.processSamplingPerformed {
            return sortedProcesses.isEmpty ? "等待首次进程采样" : "上次采样"
        }
        switch model.processStatus.quality {
        case .available:
            return "共 \(sortedProcesses.count) 个"
        case .estimated:
            return "\(sortedProcesses.count) 个 · 部分可用"
        case .unavailable, .error:
            return sortedProcesses.isEmpty ? model.processStatus.quality.displayName : "上次数据"
        }
    }

    private var processRanking: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(processSortMode == .footprint ? "按单个进程 footprint 从大到小排列" : "按单个进程 RSS 从大到小排列")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(processStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let state = emptyState(
                visibleItemCount: sortedProcesses.count,
                retainedItemCount: model.processes.count
            ) {
                MonitorListEmptyStateView(state: state)
                    .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 150, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedProcesses.enumerated()), id: \.element.id) { index, process in
                            Button {
                                detailSelection = .process(process.identity)
                            } label: {
                                ProcessRow(rank: index + 1, process: process)
                            }
                            .buttonStyle(.plain)
                            if index < sortedProcesses.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(minHeight: 112, maxHeight: 230)
            }
        }
    }

    private var sortedGroups: [WorkloadGroupSnapshot] {
        model.groups.filter { group in
            let scopeMatches: Bool
            switch processScope {
            case .all: scopeMatches = true
            case .user: scopeMatches = !group.isSystem
            case .system: scopeMatches = group.isSystem
            }
            guard scopeMatches, !normalizedSearchText.isEmpty else { return scopeMatches }
            let groupFieldsMatch = [group.title, group.id, group.representativeProcess]
                .contains { $0.lowercased().contains(normalizedSearchText) }
            return groupFieldsMatch || model.processes(in: group).contains { process in
                matchesSearch(process)
            }
        }.sorted {
            let leftValue: UInt64
            let rightValue: UInt64
            switch processSortMode {
            case .footprint:
                leftValue = $0.attributedFootprintBytes
                rightValue = $1.attributedFootprintBytes
            case .resident:
                leftValue = $0.attributedResidentBytes
                rightValue = $1.attributedResidentBytes
            }
            if $0.containsEstimatedFootprint != $1.containsEstimatedFootprint {
                return !$0.containsEstimatedFootprint
            }
            if leftValue != rightValue {
                return leftValue > rightValue
            }
            if $0.isSystem != $1.isSystem {
                return !$0.isSystem
            }
            return $0.id < $1.id
        }
    }

    private var groupRanking: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("组内数值为 footprint/RSS 相加的归因总量，当前按 \(processSortMode == .footprint ? "footprint" : "RSS") 降序。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(groupStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let state = emptyState(
                visibleItemCount: sortedGroups.count,
                retainedItemCount: model.groups.count
            ) {
                MonitorListEmptyStateView(state: state)
                    .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 150, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(sortedGroups) { group in
                            Button {
                                detailSelection = .group(group.id)
                            } label: {
                                WorkloadGroupRow(group: group)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 112, maxHeight: 230)
            }
        }
    }

    private var groupStatusText: String {
        if let state = emptyState(
            visibleItemCount: sortedGroups.count,
            retainedItemCount: model.groups.count
        ) {
            return state.shortStatus
        }
        switch model.processStatus.quality {
        case .available:
            return "共 \(sortedGroups.count) 组"
        case .estimated:
            return "共 \(sortedGroups.count) 组 · 部分可用"
        case .unavailable, .error:
            return "上次数据"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("本地监视 · 操作需确认 · \(model.samplingCadenceDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("Apple Silicon")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            HStack(spacing: 6) {
                Text(model.samplingDiagnosticsDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Button(role: .destructive) {
                    terminationAction()
                } label: {
                    Label("退出", systemImage: "power")
                }
                .buttonStyle(.borderless)
                .help("退出 Memory Monitor")
                .accessibilityLabel("退出 Memory Monitor")
            }
        }
    }
}

private struct MonitorListEmptyStateView: View {
    let state: MonitorListEmptyState

    private var iconColor: Color {
        switch state {
        case .failed:
            return .red
        case .noMatches:
            return .orange
        case .loading, .background, .noRows, .stale:
            return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: state.systemImage)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.caption.weight(.medium))
                Text(state.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MonitorDetailDataStatusView: View {
    let status: MonitorDetailDataStatus

    private var color: Color {
        switch status.kind {
        case .loading, .unavailable:
            return .secondary
        case .current:
            return .green
        case .partial, .retained:
            return .orange
        case .failed:
            return .red
        }
    }

    private var iconName: String {
        switch status.kind {
        case .loading:
            return "hourglass"
        case .current:
            return "checkmark.circle"
        case .partial:
            return "exclamationmark.triangle"
        case .retained:
            return "clock.arrow.circlepath"
        case .failed:
            return "xmark.octagon"
        case .unavailable:
            return "questionmark.circle"
        }
    }

    private var title: String {
        switch status.kind {
        case .loading:
            return "等待首次进程采样"
        case .current:
            return "当前进程采样"
        case .partial:
            return "当前采样部分可用"
        case .retained:
            return "显示上次成功采样"
        case .failed:
            return "本轮进程采样失败"
        case .unavailable:
            return "暂无可用进程快照"
        }
    }

    private var detail: String {
        switch status.kind {
        case .loading:
            return "详情数据会在首次进程扫描完成后显示。"
        case .current:
            return "本轮读取 \(coverageText) · 采样于 \(sampledAtText)"
        case .partial:
            return "本轮读取 \(coverageText)；部分条目未能读取，详情仅反映成功读取的进程。采样于 \(sampledAtText)"
        case .retained:
            let reason: String
            switch status.retentionReason {
            case .background:
                reason = "本轮后台采样未刷新进程"
            case .insufficientCoverage:
                reason = "本轮扫描覆盖不足"
            case .expired:
                reason = "当前采样已过期"
            case .invalidTimestamp, .none:
                reason = "当前采样时间无法确认"
            }
            return "\(reason)；显示上次成功快照\(ageText)，仅供观察，不代表此刻进程状态。"
        case .failed:
            let failure = status.message?.isEmpty == false
                ? status.message!
                : "无法读取进程列表"
            if status.hasRetainedData {
                return "\(failure)；仍显示上次成功快照\(ageText)，仅供观察。"
            }
            return "\(failure)；当前没有可用进程快照。"
        case .unavailable:
            let unavailable = status.message?.isEmpty == false
                ? status.message!
                : "本轮没有可用进程数据"
            if status.hasRetainedData {
                return "\(unavailable)；显示上次成功快照\(ageText)，仅供观察。"
            }
            return unavailable + "。"
        }
    }

    private var coverageText: String {
        guard status.listedItemCount > 0 else {
            return "尚未读取进程条目"
        }
        return "\(status.sampledItemCount)/\(status.listedItemCount) 个进程"
    }

    private var sampledAtText: String {
        status.sampledAt.map(detailDateLabel) ?? "时间未知"
    }

    private var ageText: String {
        guard let age = status.sampleAge else {
            return "（采样时间未知）"
        }
        if age < 60 {
            return "（约 \(Int(age.rounded())) 秒前）"
        }
        if age < 3_600 {
            return "（约 \(Int((age / 60).rounded())) 分钟前）"
        }
        return "（约 \(String(format: "%.1f", age / 3_600)) 小时前）"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

private struct ProcessDetailView: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var actions: ProcessActionController
    let identity: ProcessIdentity
    @Environment(\.dismiss) private var dismiss
    @State private var showGracefulConfirmation = false
    @State private var showForceConfirmation = false

    private var dataStatus: MonitorDetailDataStatus {
        model.detailDataStatus(retainedItemCount: model.processes.count)
    }

    var body: some View {
        Group {
            if let process = model.process(for: identity) {
                processContent(process)
            } else {
                processGoneContent
            }
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 560, idealHeight: 650)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("关闭")
                .accessibilityLabel("关闭进程详情")
            }
        }
    }

    private func processContent(_ process: ProcessSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                processHeader(process)
                MonitorDetailDataStatusView(status: dataStatus)
                processMetrics(process)
                identitySection(process)
                groupSection(process)
                parentSection(process)
                processActionSection(process)
            }
            .padding(20)
        }
        .confirmationDialog(
            "确认请求优雅退出？",
            isPresented: $showGracefulConfirmation,
            titleVisibility: .visible
        ) {
            Button("请求优雅退出", role: .destructive) {
                actions.requestGracefulExit(for: process)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("应用或进程会先收到正常退出请求，并有机会保存数据。若在约 \(Int(actions.gracefulTimeoutForDisplay)) 秒内仍未退出，才会出现强制结束选项。")
        }
        .confirmationDialog(
            "确认强制结束？",
            isPresented: $showForceConfirmation,
            titleVisibility: .visible
        ) {
            Button("强制结束", role: .destructive) {
                actions.requestForceTerminate(for: process)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会立即终止进程，可能丢失未保存的数据。执行前会再次校验进程身份。")
        }
    }

    private func processHeader(_ process: ProcessSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: process.isSystem ? "gearshape.2" : "memorychip")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(process.isSystem ? Color.secondary : Color.accentColor)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(processDisplayName(process))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("PID \(process.identity.pid) · \(process.isSystem ? "系统进程" : "用户进程")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if process.physicalFootprintIsEstimated {
                    Label("footprint 使用 RSS 估算", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
        }
    }

    private func processMetrics(_ process: ProcessSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 10
        ) {
            DetailMetricTile(
                title: "footprint",
                value: MemoryFormatter.bytes(process.physicalFootprintBytes),
                detail: process.physicalFootprintIsEstimated ? "RSS 估算" : "物理归因口径"
            )
            DetailMetricTile(
                title: "RSS",
                value: MemoryFormatter.bytes(process.residentBytes),
                detail: "驻留集大小"
            )
            DetailMetricTile(
                title: "虚拟内存",
                value: MemoryFormatter.bytes(process.virtualBytes),
                detail: "虚拟地址空间"
            )
            DetailMetricTile(
                title: "累计 CPU 时间",
                value: cpuDurationLabel(process.cpuTimeNanos),
                detail: "用户 + 系统"
            )
            DetailMetricTile(
                title: "线程",
                value: process.threadCount >= 0 ? "\(process.threadCount)" : "--",
                detail: "当前采样"
            )
            DetailMetricTile(
                title: "用户 UID",
                value: "\(process.userID)",
                detail: process.isSystem ? "系统对象" : "进程所有者"
            )
        }
    }

    private func identitySection(_ process: ProcessSnapshot) -> some View {
        DetailSection(title: "身份与来源") {
            DetailInfoRow(label: "应用", value: process.applicationName ?? "未解析")
            DetailInfoRow(label: "Bundle ID", value: process.bundleIdentifier ?? "未解析")
            DetailInfoRow(label: "可执行文件", value: executableLabel(process.executablePath) ?? process.name)
            DetailInfoRow(label: "工作目录", value: process.workingDirectoryLabel ?? "未采集（仅对部分运行时读取）")
            DetailInfoRow(label: "启动时间", value: process.startDate.map(detailDateLabel) ?? "不可用")
        }
    }

    @ViewBuilder
    private func groupSection(_ process: ProcessSnapshot) -> some View {
        if let group = model.group(containing: process.identity) {
            DetailSection(title: "当前工作组") {
                DetailInfoRow(label: "名称", value: group.title)
                DetailInfoRow(label: "归因依据", value: group.attributionReason.displayName)
                DetailInfoRow(label: "组内归因总量", value: MemoryFormatter.bytes(group.attributedFootprintBytes))
                Text("组内总量是成员 footprint 的相加值，包含共享映射；它不是去重后的整机内存。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func parentSection(_ process: ProcessSnapshot) -> some View {
        let chain = model.parentChain(for: process)
        return DetailSection(title: "父进程链") {
            if chain.isEmpty {
                Text("当前快照未找到可见父进程（父进程可能已退出或受权限限制）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(chain.enumerated()), id: \.offset) { index, parent in
                    HStack(spacing: 8) {
                        Text(index == 0 ? "父进程" : "上级 \(index + 1)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)
                        Text(processDisplayName(parent))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("PID \(parent.identity.pid)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func processActionSection(_ process: ProcessSnapshot) -> some View {
        let validation = actions.eligibility(for: process)
        DetailSection(title: "进程操作") {
            if validation.allowed {
                Text("仅允许当前用户的非系统进程。每次发送信号前都会重新校验启动身份、父 PID 和可执行路径。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let status = actions.status(for: process.identity) {
                    ProcessActionStatusRow(status: status)
                }

                HStack(spacing: 8) {
                    Button {
                        showGracefulConfirmation = true
                    } label: {
                        Label("请求优雅退出", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(actions.isBusy || actions.canForceTerminate(for: process.identity))
                    .help("先请求应用正常退出")

                    if actions.canForceTerminate(for: process.identity) {
                        Button(role: .destructive) {
                            showForceConfirmation = true
                        } label: {
                            Label("强制结束", systemImage: "xmark.octagon")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("仅在优雅退出超时后使用")
                    }

                    if actions.canCancel(for: process.identity) {
                        Button {
                            actions.cancel(for: process.identity)
                        } label: {
                            Label("取消当前操作", systemImage: "stop.circle")
                        }
                        .buttonStyle(.bordered)
                        .help("停止等待或取消尚未完成的操作")
                    }
                }

                recentActionSection
            } else {
                Label(validation.message, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("此进程仍可观察；为保护系统或避免身份不完整，不提供退出或强制结束入口。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var recentActionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("最近操作记录")
                    .font(.caption.weight(.medium))
                Spacer()
                if let error = actions.auditError {
                    Text("记录受限")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(error)
                }
            }
            if actions.recentEvents.isEmpty {
                Text("暂无已确认的操作记录")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(actions.recentEvents.prefix(5))) { event in
                    HStack(spacing: 6) {
                        Text(event.action.displayName)
                            .font(.caption2.weight(.medium))
                        Text(event.processLabel)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.statusDisplayName)
                            .font(.caption2)
                            .foregroundStyle(actionAuditColor(event))
                        Text(event.timestamp, style: .time)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private var processGoneContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            MonitorDetailDataStatusView(status: dataStatus)
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("进程已不在当前采样")
                .font(.title3.weight(.semibold))
            Text("PID \(identity.pid) 的启动身份（\(identity.startTimeSeconds)）已经无法在最新快照中找到。进程可能已退出，也可能受权限限制；不会将复用的 PID 当成同一个进程。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = actions.status(for: identity) {
                ProcessActionStatusRow(status: status)
            }
            if actions.canCancel(for: identity) {
                Button {
                    actions.cancel(for: identity)
                } label: {
                    Label("停止跟踪", systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .help("停止等待当前进程操作，不发送新的信号")
                Text("当前快照无法确认目标状态，只能停止跟踪；不会提供强制结束入口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("进程不在当前快照中，因此没有新的退出或强制结束操作。", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WorkloadGroupDetailView: View {
    @ObservedObject var model: MonitorViewModel
    let groupID: String
    @Environment(\.dismiss) private var dismiss

    private var dataStatus: MonitorDetailDataStatus {
        model.detailDataStatus(retainedItemCount: model.groups.count)
    }

    private var group: WorkloadGroupSnapshot? {
        model.group(for: groupID)
    }

    private var historicalRecord: PersistedWorkloadRecord? {
        for record in model.history.reversed() {
            if let workload = record.workloads.first(where: { $0.id == groupID }) {
                return workload
            }
        }
        return nil
    }

    private var displayTitle: String {
        group?.title ?? historicalRecord?.title ?? groupID
    }

    private var historicalPoints: [WorkloadHistoryPoint] {
        let records = model.history(for: groupID)
        let points = records.compactMap { record -> WorkloadHistoryPoint? in
            guard let workload = record.workloads.first(where: { $0.id == groupID }) else {
                return nil
            }
            return WorkloadHistoryPoint(
                timestamp: record.timestamp,
                footprintBytes: workload.attributedFootprintBytes,
                residentBytes: workload.attributedResidentBytes
            )
        }
        guard points.count > 240 else { return points }
        let lastIndex = points.count - 1
        let step = Double(lastIndex) / Double(239)
        return (0..<240).map { points[Int((Double($0) * step).rounded())] }
    }

    private var maxHistoryGiB: Double {
        let maximum = historicalPoints
            .flatMap { [$0.footprintBytes, $0.residentBytes] }
            .map { Double($0) / 1_073_741_824 }
            .max() ?? 0
        return max(maximum * 1.15, 0.1)
    }

    private var members: [ProcessSnapshot] {
        guard let group else { return [] }
        return model.processes(in: group)
    }

    private var events: [MemoryHistoryEvent] {
        Array(model.historyEvents(for: groupID).prefix(8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                groupHeader
                MonitorDetailDataStatusView(status: dataStatus)
                if let group {
                    groupMetrics(group)
                    attributionSection(group)
                    memberSection(group)
                } else {
                    unavailableSection
                }
                historySection
                eventSection
                readOnlyNotice
            }
            .padding(20)
        }
        .frame(minWidth: 540, idealWidth: 600, minHeight: 600, idealHeight: 720)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("关闭")
                .accessibilityLabel("关闭工作组详情")
            }
        }
    }

    private var groupHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: group?.isSystem == true ? "gearshape.2" : "rectangle.3.group")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(group?.isSystem == true ? Color.secondary : Color.accentColor)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(group == nil ? "当前不在进程排行中" : "工作组归因 · \(group?.processCount ?? 0) 个进程")
                    .font(.caption)
                    .foregroundStyle(group == nil ? .orange : .secondary)
            }
            Spacer(minLength: 8)
        }
    }

    private func groupMetrics(_ group: WorkloadGroupSnapshot) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: 10
        ) {
            DetailMetricTile(
                title: "footprint 归因总量",
                value: MemoryFormatter.bytes(group.attributedFootprintBytes),
                detail: group.containsEstimatedFootprint ? "包含 RSS 估算成员" : "成员相加值"
            )
            DetailMetricTile(
                title: "RSS 归因总量",
                value: MemoryFormatter.bytes(group.attributedResidentBytes),
                detail: "成员驻留集相加"
            )
            DetailMetricTile(
                title: "进程数",
                value: "\(group.processCount)",
                detail: "当前采样"
            )
            DetailMetricTile(
                title: "归因置信",
                value: attributionConfidence(group.attributionReason),
                detail: "启发式分类"
            )
        }
    }

    private func attributionSection(_ group: WorkloadGroupSnapshot) -> some View {
        DetailSection(title: "归因说明") {
            DetailInfoRow(label: "依据", value: group.attributionReason.displayName)
            DetailInfoRow(label: "代表进程", value: group.representativeProcess)
            if !group.parentChain.isEmpty {
                DetailInfoRow(label: "父链", value: group.parentChain.joined(separator: " > "))
            }
            Text(attributionExplanation(group.attributionReason))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("归因总量会把共享映射计入每个成员，不能与其他工作组相加来估算整机实际占用。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func memberSection(_ group: WorkloadGroupSnapshot) -> some View {
        DetailSection(title: "当前成员") {
            if members.isEmpty {
                Text("成员已离开当前采样，工作组可能刚刚结束或暂时受权限限制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("已解析 \(members.count)/\(group.processCount) 个成员，按 footprint 降序。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(members) { process in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(processDisplayName(process))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text("PID \(process.identity.pid) · RSS \(MemoryFormatter.bytes(process.residentBytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(MemoryFormatter.bytes(process.physicalFootprintBytes))
                            .font(.caption.monospacedDigit())
                    }
                    if process.id != members.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var unavailableSection: some View {
        DetailSection(title: "当前状态") {
            Text("该工作组已不在当前进程快照中。历史数据仍可能保留它的分钟级归因，但这不等同于确认进程退出。")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let record = historicalRecord {
                DetailInfoRow(label: "最近历史归因", value: MemoryFormatter.bytes(record.attributedFootprintBytes))
                DetailInfoRow(label: "历史成员数", value: "\(record.processCount)")
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        DetailSection(title: "最近 24 小时趋势") {
            if historicalPoints.isEmpty {
                Text("暂无该工作组的历史分钟样本。历史写盘完成后会在这里出现趋势。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 12) {
                    Label("footprint", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                    Label("RSS", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                    Spacer()
                    Text("分钟样本 \(model.history(for: groupID).count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Chart {
                    ForEach(historicalPoints) { point in
                        LineMark(
                            x: .value("时间", point.timestamp),
                            y: .value("footprint", Double(point.footprintBytes) / 1_073_741_824)
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                        LineMark(
                            x: .value("时间", point.timestamp),
                            y: .value("RSS", Double(point.residentBytes) / 1_073_741_824)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartYScale(domain: 0...maxHistoryGiB)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4))
                }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 170)
            }
        }
    }

    @ViewBuilder
    private var eventSection: some View {
        DetailSection(title: "相关历史事件") {
            if events.isEmpty {
                Text("暂无该工作组的进入、离开或增长事件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    HistoryEventRow(event: event)
                    if event.id != events.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var readOnlyNotice: some View {
        Label("工作组详情不提供批量操作；请在单个用户进程详情中逐次确认。", systemImage: "lock.shield")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct WorkloadHistoryPoint: Identifiable {
    let timestamp: Date
    let footprintBytes: UInt64
    let residentBytes: UInt64

    var id: Date { timestamp }
}

struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
            VStack(alignment: .leading, spacing: 7, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct DetailInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

private struct DetailMetricTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
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

private struct HistoryPanel: View {
    @ObservedObject var model: MonitorViewModel

    private var analysis: MemoryHistoryAnalysis {
        model.historyAnalysis
    }

    private var chartRecords: [MemoryHistoryRecord] {
        let records = model.history
        guard records.count > 240 else { return records }

        let lastIndex = records.count - 1
        let step = Double(lastIndex) / Double(239)
        return (0..<240).map { index in
            records[Int((Double(index) * step).rounded())]
        }
    }

    private var maxSwapGiB: Double {
        let maximum = chartRecords
            .map { Double($0.swapUsedBytes) / 1_073_741_824 }
            .max() ?? 0
        guard maximum.isFinite else { return 1 }
        return max(maximum * 1.15, 1)
    }

    var body: some View {
        Group {
            if analysis.hasData {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        historyHeader
                        historySummary
                        memoryChart
                        swapChart
                        eventTimeline
                        historyFooter
                    }
                }
                .frame(minHeight: 360, maxHeight: 540, alignment: .top)
            } else {
                emptyState
                    .frame(minHeight: 180, maxHeight: 260, alignment: .top)
            }
        }
    }

    private var historyHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("24 小时趋势")
                    .font(.headline)
                Text("\(analysis.sampleCount) 个分钟样本 · \(windowDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "internaldrive")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
    }

    private var historySummary: some View {
        HStack(spacing: 8) {
            HistoryMetricTile(
                title: "当前内存",
                value: percentage(analysis.latestUsedFraction)
            )
            HistoryMetricTile(
                title: "峰值内存",
                value: percentage(analysis.peakUsedFraction)
            )
            HistoryMetricTile(
                title: "峰值 Swap",
                value: bytes(analysis.peakSwapUsedBytes)
            )
        }
    }

    private var memoryChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("内存使用")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("可回收内存估算")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(chartRecords) { record in
                    LineMark(
                        x: .value("时间", record.timestamp),
                        y: .value("使用率", record.usedFraction * 100)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
                RuleMark(y: .value("注意阈值", 75))
                    .foregroundStyle(Color.orange.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(y: .value("严重阈值", 90))
                    .foregroundStyle(Color.red.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4))
            }
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 126)
        }
    }

    private var swapChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Swap 已用")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("GiB")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Chart {
                ForEach(chartRecords) { record in
                    LineMark(
                        x: .value("时间", record.timestamp),
                        y: .value("Swap", Double(record.swapUsedBytes) / 1_073_741_824)
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                }
            }
            .chartYScale(domain: 0...maxSwapGiB)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4))
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 112)
        }
    }

    private var eventTimeline: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("关键事件")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(analysis.pressureTransitionCount) 次压力切换")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if analysis.events.isEmpty {
                Text("暂无明显变化")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(analysis.events.prefix(8))) { event in
                    HistoryEventRow(event: event)
                    if event.id != analysis.events.prefix(8).last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var historyFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("本地保存 · 按分钟合并 · 保留最近 24 小时")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = model.historyError {
                Text("历史写盘受限：\(error)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("历史数据准备中")
                .font(.subheadline.weight(.medium))
            Text(model.historyError ?? "完成首个分钟记录后，这里会显示趋势和事件。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 20)
    }

    private var windowDescription: String {
        let seconds = analysis.windowDuration
        guard seconds >= 60 else { return "不足 1 分钟" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分钟" : "\(hours) 小时"
        }
        return "\(minutes) 分钟"
    }

    private func percentage(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "--" }
        return String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "--" }
        return MemoryFormatter.bytes(value)
    }
}

private struct HistoryMetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct HistoryEventRow: View {
    let event: MemoryHistoryEvent

    private var icon: String {
        switch event.kind {
        case .pressureTransition:
            return "gauge.with.dots.needle.67percent"
        case .swapThreshold:
            return "externaldrive.badge.timemachine"
        case .workloadAppeared:
            return "arrow.down.right.and.arrow.up.left"
        case .workloadDisappeared:
            return "arrow.up.left.and.arrow.down.right"
        case .workloadGrowth:
            return "chart.line.uptrend.xyaxis"
        }
    }

    private var color: Color {
        switch event.severity {
        case .info: return .secondary
        case .attention: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(event.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(event.timestamp, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MetricTile: View {
    let title: String
    let fraction: Double?
    let status: SampleStatus

    private var value: String {
        guard let fraction, fraction.isFinite else { return "--" }
        return String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }

    private var detail: String {
        guard fraction != nil else {
            if title == "CPU", status.quality.isUsable {
                return "等待下一次采样"
            }
            return status.quality == .available ? "暂无数据" : status.quality.displayName
        }
        if title == "内存", status.quality == .estimated {
            return "估算"
        }
        return status.quality == .available ? "已使用" : status.quality.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(utilizationColor(fraction))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}

private func utilizationColor(_ fraction: Double?) -> Color {
    guard let fraction, fraction.isFinite else { return .secondary }
    if fraction >= 0.9 { return .red }
    if fraction >= 0.75 { return .orange }
    return .primary
}

private func recommendationColor(_ severity: RecommendationSeverity) -> Color {
    switch severity {
    case .info: return .secondary
    case .attention: return .orange
    case .critical: return .red
    }
}

private func recommendationIcon(_ severity: RecommendationSeverity) -> String {
    switch severity {
    case .info: return "info.circle"
    case .attention: return "exclamationmark.triangle"
    case .critical: return "bolt.trianglebadge.exclamationmark"
    }
}

private func actionOutcomeColor(_ outcome: ProcessActionOutcome) -> Color {
    switch outcome {
    case .completed: return .green
    case .timedOut: return .orange
    case .denied, .failed: return .red
    case .cancelled: return .secondary
    }
}

private func actionAuditColor(_ event: ProcessActionAuditEvent) -> Color {
    switch event.phase {
    case .intent:
        return .secondary
    case .signalSent:
        return .orange
    case .terminal:
        return actionOutcomeColor(event.outcome)
    }
}

private struct WorkloadGroupRow: View {
    let group: WorkloadGroupSnapshot

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(group.processCount) 个进程 · \(group.representativeProcess)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("依据：\(group.attributionReason.displayName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !group.parentChain.isEmpty {
                    Text("父链：\(group.parentChain.joined(separator: " > "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(group.containsEstimatedFootprint ? "footprint 归因总量 · 估算" : "footprint 归因总量")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(MemoryFormatter.bytes(group.attributedFootprintBytes))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                Text("RSS 归因总量 \(MemoryFormatter.bytes(group.attributedResidentBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProcessRow: View {
    let rank: Int
    let process: ProcessSnapshot

    private var displayName: String {
        guard let executablePath = process.executablePath else { return process.name }
        let basename = URL(fileURLWithPath: executablePath).lastPathComponent
        return WorkingDirectoryLabelSanitizer.label(fromComponent: basename) ?? process.name
    }

    private var detailText: String {
        var details = ["PID \(process.identity.pid)", process.isSystem ? "系统" : "用户"]
        if let applicationName = process.applicationName,
           applicationName.caseInsensitiveCompare(process.name) != .orderedSame {
            details.append(applicationName)
        }
        if let label = process.workingDirectoryLabel {
            details.append(label)
        }
        return details.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("#\(rank)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detailText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(process.physicalFootprintIsEstimated ? "footprint 估算" : "footprint")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(MemoryFormatter.bytes(process.physicalFootprintBytes))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Text("RSS \(MemoryFormatter.bytes(process.residentBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
    }
}
