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
    /// Identity anchors for the bundle and executable observed at authorization
    /// time. An in-place app update or replacement changes at least one of
    /// these and invalidates the authorization until the user re-adds it.
    let bundleInode: UInt64?
    let executableInode: UInt64?

    init(
        bundleIdentifier: String,
        bundlePath: String,
        executablePath: String,
        bundleInode: UInt64? = nil,
        executableInode: UInt64? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.bundleInode = bundleInode
        self.executableInode = executableInode
    }
}

struct CleanupApplication: Identifiable, Equatable, Sendable {
    let process: ProcessSnapshot
    let authorization: CleanupAuthorization
    var id: ProcessIdentity { process.identity }
    var name: String { process.applicationName ?? process.name }
}

enum CleanupDecisionReason: String, Codable, Sendable, Equatable {
    case frontmost
    case recentActivity
    case missingCPUSample
    case busyCPU
    case allowed
}

struct CleanupEligibilityDecision: Sendable, Equatable {
    let reason: CleanupDecisionReason
    let message: String?

    var isAllowed: Bool { reason == .allowed }
}

struct CleanupEligibilityPolicy: Sendable, Equatable {
    let policyID: String
    let recentActivitySeconds: TimeInterval
    let busyCPUPercent: Double

    static let standard = CleanupEligibilityPolicy()

    init(
        policyID: String = "smart-cleanup.v1",
        recentActivitySeconds: TimeInterval = 120,
        busyCPUPercent: Double = 5
    ) {
        self.policyID = policyID
        self.recentActivitySeconds = recentActivitySeconds.isFinite
            ? max(recentActivitySeconds, 0)
            : 120
        self.busyCPUPercent = busyCPUPercent.isFinite
            ? max(busyCPUPercent, 0)
            : 5
    }

    func decision(for observation: CleanupObservation) -> CleanupEligibilityDecision {
        if observation.isFrontmost {
            return .init(reason: .frontmost, message: "正在使用")
        }
        if !observation.secondsSinceActivity.isFinite
            || observation.secondsSinceActivity < recentActivitySeconds {
            return .init(reason: .recentActivity, message: "近期使用或仍在观察")
        }
        guard let cpu = observation.cpuPercent, cpu.isFinite, cpu >= 0 else {
            return .init(reason: .missingCPUSample, message: "等待活动数据")
        }
        if cpu >= busyCPUPercent {
            return .init(reason: .busyCPU, message: "当前忙碌")
        }
        return .init(reason: .allowed, message: nil)
    }

    func protectionMessage(for observation: CleanupObservation) -> String? {
        decision(for: observation).message
    }
}

struct CleanupObservation: Identifiable, Equatable, Sendable {
    let application: CleanupApplication
    let isFrontmost: Bool
    let secondsSinceActivity: TimeInterval
    let cpuPercent: Double?
    var id: ProcessIdentity { application.id }

    var protection: String? {
        CleanupEligibilityPolicy.standard.protectionMessage(for: self)
    }
}

enum CleanupSkipReason: String, Sendable, Equatable, Error {
    case missingBundle
    case missingExecutable
    case systemPath
    case protectedProcess
    case notReady
    case samplingFailed

    var displayName: String {
        switch self {
        case .missingBundle: return "缺少 bundle 标识"
        case .missingExecutable: return "缺少可执行路径"
        case .systemPath: return "系统路径"
        case .protectedProcess: return "受系统保护"
        case .notReady: return "尚未完成启动"
        case .samplingFailed: return "无法读取进程"
        }
    }
}

struct CleanupSkip: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let reason: CleanupSkipReason

    init(name: String, reason: CleanupSkipReason) {
        self.id = reason.rawValue + ":" + name
        self.name = name
        self.reason = reason
    }
}

struct CleanupInventoryMetrics: Sendable, Equatable {
    let generation: UInt64
    let scanCount: Int
    let memberCount: Int
    let complete: Bool
    let durationMilliseconds: Double
    let cancellationLatencyMilliseconds: Double?
    let budgetExhausted: Bool
}

struct CleanupInventory: Sendable, Equatable {
    let observations: [CleanupObservation]
    let skipped: [CleanupSkip]
    let metrics: CleanupInventoryMetrics?

    init(
        observations: [CleanupObservation],
        skipped: [CleanupSkip] = [],
        metrics: CleanupInventoryMetrics? = nil
    ) {
        self.observations = observations
        self.skipped = skipped
        self.metrics = metrics
    }

    var evaluatedCount: Int { observations.count + skipped.count }
    var eligibleCount: Int { observations.filter { $0.protection == nil }.count }
    var skippedCount: Int { skipped.count }

    var skippedSummary: String? {
        guard !skipped.isEmpty else { return nil }
        var counts: [CleanupSkipReason: Int] = [:]
        for item in skipped { counts[item.reason, default: 0] += 1 }
        return counts
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.value) 个\($0.key.displayName)" }
            .joined(separator: "，")
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
    func inventoryReport() async -> CleanupInventory
    func inspect(_ application: CleanupApplication) async -> CleanupObservation?
    func requestQuit(_ application: CleanupApplication) -> CleanupQuitRequest
    func exitState(_ application: CleanupApplication) -> CleanupExitState
    func sampleMemory() async -> SystemMemorySnapshot?
    func relieveOwnMemory() async
    func sleep(seconds: TimeInterval) async throws
}

@MainActor
extension SmartCleanupRuntime {
    func inventoryReport() async -> CleanupInventory {
        CleanupInventory(observations: await inventory())
    }
}

@MainActor
final class SmartCleanupController: ObservableObject {
    typealias AuditHandler = @MainActor (ProcessActionAuditEvent) async -> Bool

    @Published private(set) var phase: CleanupPhase = .idle
    @Published private(set) var applications: [CleanupObservation] = []
    @Published private(set) var inventory = CleanupInventory(observations: [])
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
    private let audit: AuditHandler?
    private let eligibilityPolicy: CleanupEligibilityPolicy
    private let executionEnabled: Bool
    private let approvalKey = "smartCleanup.authorizedApplications.v1"
    private var task: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var wantsSkip = false
    private var shuttingDown = false
    private var cooldownUntil: TimeInterval = 0
    private var pendingExitAudits: [ProcessIdentity: String] = [:]

    init(runtime: (any SmartCleanupRuntime)? = nil, defaults: UserDefaults = .standard,
         operationGate: MonitorOperationGate = MonitorOperationGate(),
         executionEnabled: Bool = true,
         manualActionIsBusy: @escaping @MainActor () -> Bool = { false },
         eligibilityPolicy: CleanupEligibilityPolicy = .standard,
         audit: AuditHandler? = nil) {
        self.runtime = runtime ?? LiveSmartCleanupRuntime()
        self.defaults = defaults
        self.operationGate = operationGate
        self.manualActionIsBusy = manualActionIsBusy
        self.eligibilityPolicy = eligibilityPolicy
        self.audit = audit
        self.executionEnabled = executionEnabled
        if executionEnabled, let data = defaults.data(forKey: approvalKey),
           let saved = try? JSONDecoder().decode([CleanupAuthorization].self, from: data) {
            let current = saved.filter { $0.bundleInode != nil && $0.executableInode != nil }
            authorizations = Set(current)
            if current.count != saved.count {
                notice = "应用身份校验已升级，请重新授权清理名单。"
            }
        } else {
            authorizations = []
        }
    }

    var isBusy: Bool { task != nil }
    var canStart: Bool { executionEnabled && !isBusy && !shuttingDown && operationGate.owner == nil && !manualActionIsBusy() }

    /// The UI freezes this value after refreshing activity samples. Execution
    /// may skip these identities, but must never fill their places with others.
    var confirmationApplications: [CleanupApplication] {
        Array(applications.filter {
            isAuthorized($0.application) && eligibilityPolicy.decision(for: $0).isAllowed
        }.sorted {
            ProcessSnapshot.memoryDescending($0.application.process, $1.application.process)
        }.prefix(8).map(\.application))
    }

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
            _ = await runtime.inventoryReport()
            do { try await runtime.sleep(seconds: 0.6) } catch { finishRefresh(); return }
            let report = await runtime.inventoryReport()
            if !Task.isCancelled && !isBusy {
                inventory = report
                applications = report.observations
            }
            finishRefresh()
        }
    }

    private func finishRefresh() { isRefreshing = false; refreshTask = nil }

    func start(confirmedApplications: [CleanupApplication]) {
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
        pendingExitAudits = [:]
        var identities = Set<ProcessIdentity>()
        let confirmed = Array(confirmedApplications.filter {
            identities.insert($0.id).inserted
        }.prefix(8))
        phase = .scanning
        task = Task { [weak self] in
            await previousRefresh?.value
            guard let self else { return }
            await run(confirmedApplications: confirmed)
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
    func waitUntilRefreshed() async { await refreshTask?.value }

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

    private func run(confirmedApplications: [CleanupApplication]) async {
        var before: MemoryWindow?
        var after: MemoryWindow?
        var planned: [CleanupApplication] = []
        do {
            before = try await memoryWindow()
            guard before != nil else { notice = "内存数据暂不可用，本次未执行清理。"; finishResult(before: nil, after: nil); return }
            _ = await runtime.inventoryReport()
            try await runtime.sleep(seconds: 0.6)
            let report = await runtime.inventoryReport()
            inventory = report
            applications = report.observations
            try Task.checkCancellation()
            let authorized = applications.filter { isAuthorized($0.application) }
            let confirmedByID = Dictionary(uniqueKeysWithValues: confirmedApplications.map { ($0.id, $0) })
            for observation in authorized {
                let decision = eligibilityPolicy.decision(for: observation)
                if !decision.isAllowed {
                    append(observation.application, .skipped, decision.message ?? "已跳过")
                } else if let confirmed = confirmedByID[observation.id],
                          confirmed.authorization == observation.application.authorization {
                    planned.append(confirmed)
                } else {
                    append(observation.application, .skipped, "未包含在本次确认中")
                }
            }
            for app in confirmedApplications where !applications.contains(where: { $0.id == app.id }) {
                append(app, .skipped, "应用已退出或身份发生变化")
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
        } catch {
            if !Task.isCancelled { notice = "清理已中断，请稍后重试。" }
        }
        for app in planned where !entries.contains(where: { $0.id == app.id }) {
            append(app, .cancelled, "尚未发送退出请求")
        }
        // Finalize verified exits even when measurement was cancelled/failed.
        // Keep one terminal record that agrees with the final relaunch check.
        for app in planned {
            guard let operationID = pendingExitAudits.removeValue(forKey: app.id) else { continue }
            let relaunched = runtime.exitState(app) == .relaunched
            if relaunched, let index = entries.firstIndex(where: { $0.id == app.id && $0.outcome == .exited }) {
                entries[index].outcome = .relaunched
                entries[index].detail = "应用已重新启动"
            }
            await recordAudit(app, operationID: operationID, phase: .terminal,
                              outcome: relaunched ? .failed : .completed,
                              detail: relaunched ? "智能清理：应用已重新启动" : "智能清理：应用已正常退出")
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
        let operationID = UUID().uuidString
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
            let decision = eligibilityPolicy.decision(for: observation)
            if !decision.isAllowed {
                append(app, .skipped, decision.message ?? "已跳过")
                return
            }

            // The intent is a durable prerequisite for sending the quit
            // request, mirroring the manual process-action audit gate.
            guard await recordAudit(
                app,
                operationID: operationID,
                phase: .intent,
                outcome: .completed,
                detail: "智能清理[\(eligibilityPolicy.policyID)]：用户已授权，准备请求正常退出"
            ) else {
                append(app, .skipped, "无法记录清理意图，未发送退出请求")
                notice = "清理审计不可用，已阻止本次退出请求。"
                return
            }

            try Task.checkCancellation()
            guard isAuthorized(app) else {
                append(app, .skipped, "已取消授权")
                await recordAudit(app, operationID: operationID, phase: .terminal,
                                  outcome: .cancelled, detail: "智能清理：请求前已取消授权，未发送退出请求")
                return
            }

            switch runtime.requestQuit(observation.application) {
            case .refused:
                append(app, .refused, "应用未接受退出请求")
                await recordAudit(
                    app,
                    operationID: operationID,
                    phase: .terminal,
                    outcome: .denied,
                    detail: "智能清理：应用未接受正常退出请求"
                )
                return
            case .changed:
                append(app, .skipped, "应用状态已变化")
                await recordAudit(
                    app,
                    operationID: operationID,
                    phase: .terminal,
                    outcome: .cancelled,
                    detail: "智能清理：应用状态在请求前发生变化"
                )
                return
            case .sent:
                requestSent = true
                await recordAudit(
                    app,
                    operationID: operationID,
                    phase: .signalSent,
                    outcome: .completed,
                    detail: "智能清理：已发送正常退出请求"
                )
            }
            phase = .waiting
            let deadline = runtime.now + 8
            while true {
                try Task.checkCancellation()
                switch runtime.exitState(app) {
                case .exited:
                    append(app, .exited, "已正常退出")
                    pendingExitAudits[app.id] = operationID
                    completionPulse += 1
                    return
                case .relaunched:
                    append(app, .relaunched, "应用已重新启动")
                    await recordAudit(
                        app,
                        operationID: operationID,
                        phase: .terminal,
                        outcome: .failed,
                        detail: "智能清理：应用已重新启动"
                    )
                    return
                case .running: break
                }
                if wantsSkip {
                    append(app, .skipped, "已跳过等待；退出请求已发出")
                    await recordAudit(
                        app,
                        operationID: operationID,
                        phase: .terminal,
                        outcome: .cancelled,
                        detail: "智能清理：已跳过等待，退出请求已发出"
                    )
                    return
                }
                if runtime.now >= deadline {
                    append(app, .timedOut, "尚未退出，可能需要保存确认")
                    await recordAudit(
                        app,
                        operationID: operationID,
                        phase: .terminal,
                        outcome: .timedOut,
                        detail: "智能清理：等待正常退出超时"
                    )
                    return
                }
                try await runtime.sleep(seconds: 0.25)
            }
        } catch {
            let detail = requestSent ? "已停止等待；退出请求已发出" : "尚未发送退出请求"
            append(app, .cancelled, detail)
            await recordAudit(
                app,
                operationID: operationID,
                phase: .terminal,
                outcome: .cancelled,
                detail: "智能清理：" + detail
            )
        }
    }

    @discardableResult
    private func recordAudit(
        _ app: CleanupApplication,
        operationID: String,
        phase: ProcessActionAuditPhase,
        outcome: ProcessActionOutcome,
        detail: String
    ) async -> Bool {
        guard let audit else { return true }
        let event = ProcessActionAuditEvent(
            operationID: operationID,
            action: .gracefulExit,
            phase: phase,
            outcome: outcome,
            processLabel: app.name,
            applicationName: app.process.applicationName,
            detail: detail
        )
        let recorded = await audit(event)
        if !recorded {
            notice = "清理审计写入失败；本次操作可能无法在审计面板中查看。"
        }
        return recorded
    }

    private func append(_ app: CleanupApplication, _ outcome: CleanupEntry.Outcome, _ detail: String) {
        entries.append(.init(id: app.id, name: app.name, outcome: outcome, detail: detail))
    }

    deinit { task?.cancel(); refreshTask?.cancel() }
}
