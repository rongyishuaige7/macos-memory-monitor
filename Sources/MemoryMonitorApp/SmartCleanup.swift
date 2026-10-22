import AppKit
import Combine
import MemoryMonitorCore

@MainActor
final class MonitorOperationGate: ObservableObject {
    enum Owner { case cleanup, memoryTest, manualAction }
    @Published private(set) var owner: Owner?

    func acquire(_ owner: Owner) -> Bool {
        guard self.owner == nil else { return false }
        self.owner = owner
        return true
    }

    func release(_ owner: Owner) {
        if self.owner == owner { self.owner = nil }
    }
}

struct CleanupAuthorization: Codable, Hashable, Sendable {
    let bundleIdentifier: String
    let bundlePath: String
    let executablePath: String
}

struct CleanupApplication: Identifiable, Equatable, Sendable {
    let process: ProcessSnapshot
    let authorization: CleanupAuthorization
    var id: ProcessIdentity { process.identity }
    var name: String { process.applicationName ?? process.name }
}

struct CleanupObservation: Identifiable, Equatable, Sendable {
    let application: CleanupApplication
    let isFrontmost: Bool
    let secondsSinceActivity: TimeInterval
    let cpuPercent: Double?
    var id: ProcessIdentity { application.id }

    var protection: String? {
        if isFrontmost { return "正在使用" }
        if !secondsSinceActivity.isFinite || secondsSinceActivity < 120 { return "近期使用或仍在观察" }
        guard let cpuPercent, cpuPercent.isFinite, cpuPercent >= 0 else { return "等待活动数据" }
        if cpuPercent >= 5 { return "当前忙碌" }
        return nil
    }
}

enum CleanupQuitRequest { case sent, refused, changed }
enum CleanupExitState { case running, exited, relaunched }
enum CleanupPhase: Equatable { case idle, scanning, quitting, waiting, measuring, finished }

struct CleanupEntry: Identifiable, Equatable {
    enum Outcome: Equatable { case exited, skipped, refused, timedOut, relaunched, cancelled }
    let id: ProcessIdentity
    let name: String
    var outcome: Outcome
    var detail: String
}

struct CleanupResult: Equatable {
    let entries: [CleanupEntry]
    let observedChangeBytes: Int64?
    let cancelled: Bool
    let measurementFailed: Bool
    var exitedCount: Int { entries.filter { $0.outcome == .exited }.count }
    var hasMeasuredBenefit: Bool {
        !cancelled && !measurementFailed && exitedCount > 0 && (observedChangeBytes ?? 0) >= 16 * 1024 * 1024
    }
    var title: String {
        if cancelled { return "已停止清理" }
        if exitedCount > 0 { return "已退出 \(exitedCount) 个应用" }
        return "本次未退出应用"
    }
}

@MainActor
protocol SmartCleanupRuntime: AnyObject {
    var now: TimeInterval { get }
    func inventory() async -> [CleanupObservation]
    func inspect(_ application: CleanupApplication) async -> CleanupObservation?
    func requestQuit(_ application: CleanupApplication) -> CleanupQuitRequest
    func exitState(_ application: CleanupApplication) -> CleanupExitState
    func sampleMemory() async -> SystemMemorySnapshot?
    func relieveOwnMemory() async
    func sleep(seconds: TimeInterval) async throws
}

@MainActor
final class SmartCleanupController: ObservableObject {
    @Published private(set) var phase: CleanupPhase = .idle
    @Published private(set) var applications: [CleanupObservation] = []
    @Published private(set) var authorizations: Set<CleanupAuthorization>
    @Published private(set) var entries: [CleanupEntry] = []
    @Published private(set) var result: CleanupResult?
    @Published private(set) var currentName: String?
    @Published private(set) var plannedCount = 0
    @Published private(set) var completedCount = 0
    @Published private(set) var completionPulse = 0
    @Published private(set) var notice: String?
    @Published private(set) var isRefreshing = false
    let operationGate: MonitorOperationGate
    private let runtime: any SmartCleanupRuntime
    private let defaults: UserDefaults
    private let manualActionIsBusy: @MainActor () -> Bool
    private let executionEnabled: Bool
    private let approvalKey = "smartCleanup.authorizedApplications.v1"
    private var task: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var wantsSkip = false
    private var shuttingDown = false
    private var cooldownUntil: TimeInterval = 0

    init(runtime: (any SmartCleanupRuntime)? = nil, defaults: UserDefaults = .standard,
         operationGate: MonitorOperationGate = MonitorOperationGate(),
         executionEnabled: Bool = true,
         manualActionIsBusy: @escaping @MainActor () -> Bool = { false }) {
        self.runtime = runtime ?? LiveSmartCleanupRuntime()
        self.defaults = defaults
        self.operationGate = operationGate
        self.manualActionIsBusy = manualActionIsBusy
        self.executionEnabled = executionEnabled
        if executionEnabled, let data = defaults.data(forKey: approvalKey),
           let saved = try? JSONDecoder().decode([CleanupAuthorization].self, from: data) {
            authorizations = Set(saved)
        } else {
            authorizations = []
        }
    }

    var isBusy: Bool { task != nil }
    var canStart: Bool { executionEnabled && !isBusy && !shuttingDown && operationGate.owner == nil && !manualActionIsBusy() }

    func isAuthorized(_ application: CleanupApplication) -> Bool {
        authorizations.contains(application.authorization)
    }

    func setAuthorized(_ application: CleanupApplication, _ authorized: Bool) {
        // Revocation is allowed even while a batch is running.
        guard !authorized || !isBusy else { return }
        var next = authorizations
        if authorized { next.insert(application.authorization) }
        else { next.remove(application.authorization) }
        persist(next)
    }

    func revokeAll() { persist([]) }

    private func persist(_ next: Set<CleanupAuthorization>) {
        guard executionEnabled else { return }
        guard let encoded = try? JSONEncoder().encode(Array(next)) else {
            notice = "无法保存清理名单，请重试。"
            return
        }
        defaults.set(encoded, forKey: approvalKey)
        authorizations = next
    }

    func refreshApplications() {
        guard executionEnabled, !isBusy, !isRefreshing, !shuttingDown else { return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            _ = await runtime.inventory()
            do { try await runtime.sleep(seconds: 0.6) } catch { finishRefresh(); return }
            let observations = await runtime.inventory()
            if !Task.isCancelled && !isBusy { applications = observations }
            finishRefresh()
        }
    }

    private func finishRefresh() { isRefreshing = false; refreshTask = nil }

    func start() {
        guard canStart else { notice = "请等待当前操作结束。"; return }
        guard runtime.now >= cooldownUntil else { notice = "刚刚完成清理，请稍后再试。"; return }
        guard operationGate.acquire(.cleanup) else { return }
        refreshTask?.cancel()
        let previousRefresh = refreshTask
        notice = nil
        result = nil
        entries = []
        plannedCount = 0
        completedCount = 0
        currentName = nil
        phase = .scanning
        task = Task { [weak self] in
            await previousRefresh?.value
            guard let self else { return }
            await run()
            phase = .finished
            currentName = nil
            cooldownUntil = runtime.now + 10
            operationGate.release(.cleanup)
            task = nil
        }
    }

    func cancel() { task?.cancel() }
    func skipCurrent() { if phase == .waiting { wantsSkip = true } }
    func waitUntilFinished() async { await task?.value }

    func shutdown() async {
        shuttingDown = true
        refreshTask?.cancel()
        task?.cancel()
        await refreshTask?.value
        await task?.value
    }

    private struct MemoryWindow {
        let available: UInt64
        let total: UInt64
    }

    private func memoryWindow() async throws -> MemoryWindow? {
        var samples: [SystemMemorySnapshot] = []
        for index in 0..<3 {
            try Task.checkCancellation()
            guard let sample = await runtime.sampleMemory(), sample.isStructurallyValid else { return nil }
            try Task.checkCancellation()
            samples.append(sample)
            if index < 2 { try await runtime.sleep(seconds: 0.35) }
        }
        guard Set(samples.map(\.totalBytes)).count == 1,
              zip(samples, samples.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else { return nil }
        return MemoryWindow(available: samples.map(\.availableEstimateBytes).sorted()[1], total: samples[0].totalBytes)
    }

    private func run() async {
        var before: MemoryWindow?
        var after: MemoryWindow?
        var planned: [CleanupApplication] = []
        do {
            before = try await memoryWindow()
            guard before != nil else { notice = "内存数据暂不可用，本次未执行清理。"; finishResult(before: nil, after: nil); return }
            _ = await runtime.inventory()
            try await runtime.sleep(seconds: 0.6)
            applications = await runtime.inventory()
            try Task.checkCancellation()
            let authorized = applications.filter { isAuthorized($0.application) }
            for observation in authorized {
                if let reason = observation.protection {
                    append(observation.application, .skipped, reason)
                } else { planned.append(observation.application) }
            }
            planned.sort { ProcessSnapshot.memoryDescending($0.process, $1.process) }
            // Bound a click's scope even if a large authorization list is imported.
            for app in planned.dropFirst(8) { append(app, .skipped, "留待下次清理") }
            planned = Array(planned.prefix(8))
            plannedCount = planned.count
            await runtime.relieveOwnMemory()
            for app in planned {
                try Task.checkCancellation()
                phase = .quitting
                currentName = app.name
                wantsSkip = false
                await quit(app)
                completedCount += 1
            }
            try Task.checkCancellation()
            phase = .measuring
            try await runtime.sleep(seconds: 0.6)
            after = try await memoryWindow()
            // A verified exit followed by a relaunch must not remain a success.
            for app in planned where runtime.exitState(app) == .relaunched {
                if let index = entries.firstIndex(where: { $0.id == app.id && $0.outcome == .exited }) {
                    entries[index].outcome = .relaunched
                    entries[index].detail = "应用已重新启动"
                }
            }
        } catch {
            if !Task.isCancelled { notice = "清理已中断，请稍后重试。" }
        }
        for app in planned where !entries.contains(where: { $0.id == app.id }) {
            append(app, .cancelled, "尚未发送退出请求")
        }
        finishResult(before: before, after: after)
    }

    private func finishResult(before: MemoryWindow?, after: MemoryWindow?) {
        let change: Int64? = if let before, let after, before.total == after.total,
            before.available <= UInt64(Int64.max), after.available <= UInt64(Int64.max) {
            Int64(after.available) - Int64(before.available)
        } else { nil }
        result = CleanupResult(entries: entries, observedChangeBytes: change, cancelled: Task.isCancelled,
                               measurementFailed: change == nil)
    }

    private func quit(_ app: CleanupApplication) async {
        var requestSent = false
        do {
            var observation = await runtime.inspect(app)
            if observation?.cpuPercent == nil {
                try await runtime.sleep(seconds: 0.6)
                observation = await runtime.inspect(app)
            }
            try Task.checkCancellation()
            guard isAuthorized(app) else { append(app, .skipped, "已取消授权"); return }
            guard let observation, observation.application.id == app.id,
                  observation.application.authorization == app.authorization else {
                append(app, .skipped, "应用已退出或身份发生变化"); return
            }
            if let reason = observation.protection { append(app, .skipped, reason); return }
            switch runtime.requestQuit(observation.application) {
            case .refused: append(app, .refused, "应用未接受退出请求"); return
            case .changed: append(app, .skipped, "应用状态已变化"); return
            case .sent: requestSent = true
            }
            phase = .waiting
            let deadline = runtime.now + 8
            while true {
                try Task.checkCancellation()
                switch runtime.exitState(app) {
                case .exited:
                    append(app, .exited, "已正常退出")
                    completionPulse += 1
                    return
                case .relaunched: append(app, .relaunched, "应用已重新启动"); return
                case .running: break
                }
                if wantsSkip { append(app, .skipped, "已跳过等待；退出请求已发出"); return }
                if runtime.now >= deadline { append(app, .timedOut, "尚未退出，可能需要保存确认"); return }
                try await runtime.sleep(seconds: 0.25)
            }
        } catch {
            append(app, .cancelled, requestSent ? "已停止等待；退出请求已发出" : "尚未发送退出请求")
        }
    }

    private func append(_ app: CleanupApplication, _ outcome: CleanupEntry.Outcome, _ detail: String) {
        entries.append(.init(id: app.id, name: app.name, outcome: outcome, detail: detail))
    }

    deinit { task?.cancel(); refreshTask?.cancel() }
}
