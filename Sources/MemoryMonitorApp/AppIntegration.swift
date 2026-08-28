import AppKit
import Combine
import Foundation
import ServiceManagement
import MemoryMonitorCore

/// The observable state of the app's optional login-item registration.
enum LoginLaunchStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .notRegistered: return "未启用"
        case .enabled: return "已启用"
        case .requiresApproval: return "等待系统批准"
        case .notFound: return "未找到应用"
        case .unavailable: return "不可用"
        case .failed: return "操作失败"
        }
    }

    var detail: String {
        switch self {
        case .notRegistered:
            return "登录启动已关闭（默认）"
        case .enabled:
            return "登录后会自动启动 Memory Monitor"
        case .requiresApproval:
            return "请在系统设置的登录项中允许 Memory Monitor"
        case .notFound:
            return "当前应用包无法被系统识别"
        case .unavailable(let message), .failed(let message):
            return message
        }
    }

    var isRegistered: Bool {
        switch self {
        case .enabled, .requiresApproval:
            return true
        case .notRegistered, .notFound, .unavailable, .failed:
            return false
        }
    }

    var isEnabled: Bool {
        self == .enabled
    }
}

enum LoginLaunchRuntimeError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .operationFailed(let message):
            return message
        }
    }
}

/// Runtime boundary for login-item registration. Keeping it separate from
/// the coordinator makes all registration behavior testable without touching
/// the user's actual Login Items database.
@MainActor
protocol LoginLaunchRuntime: AnyObject {
    func status() -> LoginLaunchStatus
    func register() async throws
    func unregister() async throws
    func openSystemSettings()
}

@MainActor
final class LiveLoginLaunchRuntime: LoginLaunchRuntime {
    func status() -> LoginLaunchStatus {
        guard #available(macOS 13.0, *) else {
            return .unavailable("登录启动需要 macOS 13 或更高版本")
        }

        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unavailable("系统返回了未知的登录启动状态")
        }
    }

    func register() async throws {
        guard #available(macOS 13.0, *) else {
            throw LoginLaunchRuntimeError.unavailable(
                "登录启动需要 macOS 13 或更高版本"
            )
        }
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw LoginLaunchRuntimeError.operationFailed(
                "无法启用登录启动：" + error.localizedDescription
            )
        }
    }

    func unregister() async throws {
        guard #available(macOS 13.0, *) else {
            throw LoginLaunchRuntimeError.unavailable(
                "登录启动需要 macOS 13 或更高版本"
            )
        }
        do {
            try await SMAppService.mainApp.unregister()
        } catch {
            throw LoginLaunchRuntimeError.operationFailed(
                "无法关闭登录启动：" + error.localizedDescription
            )
        }
    }

    func openSystemSettings() {
        guard #available(macOS 13.0, *) else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LoginLaunchCoordinator: ObservableObject {
    @Published private(set) var status: LoginLaunchStatus = .unavailable("正在检查…")
    @Published private(set) var isUpdating = false
    @Published private(set) var lastError: String?

    private let runtime: any LoginLaunchRuntime
    private var operationTask: Task<Void, Never>?
    private var operationToken = UUID()
    private var cancellationRefreshToken: UUID?
    /// The runtime status observed when the last operation error was
    /// reported. A passive refresh clears the error only after the system
    /// state changes, which allows recovery in System Settings without
    /// hiding an unresolved failure.
    private var statusAtLastError: LoginLaunchStatus?

    init(runtime: (any LoginLaunchRuntime)? = nil) {
        self.runtime = runtime ?? LiveLoginLaunchRuntime()
        refreshStatus()
    }

    deinit {
        operationTask?.cancel()
    }

    var toggleValue: Bool {
        status.isRegistered
    }

    func refreshStatus() {
        guard !isUpdating else { return }
        let refreshedStatus = runtime.status()
        status = refreshedStatus
        if let statusAtLastError,
           refreshedStatus != statusAtLastError {
            lastError = nil
            self.statusAtLastError = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        lastError = nil
        cancellationRefreshToken = nil

        operationTask?.cancel()
        let token = UUID()
        operationToken = token
        let runtime = self.runtime
        operationTask = Task { [weak self] in
            defer {
                if let self, self.operationToken == token {
                    self.isUpdating = false
                    self.operationTask = nil
                }
            }

            do {
                if enabled {
                    try await runtime.register()
                } else {
                    try await runtime.unregister()
                }
                guard !Task.isCancelled,
                      let self,
                      self.operationToken == token else {
                    return
                }
                self.status = runtime.status()
                if enabled, !self.status.isRegistered {
                    self.lastError = "系统没有确认登录启动已注册，请检查登录项设置。"
                    self.statusAtLastError = self.status
                } else if !enabled, self.status.isRegistered {
                    self.lastError = "系统没有确认登录启动已关闭，请检查登录项设置。"
                    self.statusAtLastError = self.status
                } else {
                    self.lastError = nil
                    self.statusAtLastError = nil
                }
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.operationToken == token else {
                    return
                }
                self.status = runtime.status()
                self.lastError = error.localizedDescription
                self.statusAtLastError = self.status
            }
        }
    }

    /// Cancels an in-flight registration change without allowing its eventual
    /// completion to overwrite newer UI state. Runtime implementations are
    /// expected to observe task cancellation, but the coordinator also clears
    /// its own state immediately so a slow system service cannot leave the
    /// toggle stuck in an indeterminate state.
    func cancelUpdate() {
        guard isUpdating else { return }
        let taskBeingCancelled = operationTask
        let runtime = self.runtime
        let refreshToken = UUID()
        operationToken = UUID()
        cancellationRefreshToken = refreshToken
        taskBeingCancelled?.cancel()
        operationTask = nil
        isUpdating = false

        // Some system services complete a registration request even after the
        // Swift task has been cancelled. Wait for that old task and refresh
        // the observed status, while keeping a newer enable/disable request
        // authoritative through the token check.
        Task { [weak self] in
            await taskBeingCancelled?.value
            guard let self,
                  self.cancellationRefreshToken == refreshToken,
                  !self.isUpdating else { return }
            self.status = runtime.status()
            self.cancellationRefreshToken = nil
        }
    }

    func openSystemSettings() {
        runtime.openSystemSettings()
    }
}

enum MonitorHealthLevel: Int, CaseIterable, Comparable, Equatable, Sendable {
    case healthy = 0
    case degraded = 1
    case attention = 2

    static func < (lhs: MonitorHealthLevel, rhs: MonitorHealthLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .healthy: return "正常"
        case .degraded: return "部分可用"
        case .attention: return "需要处理"
        }
    }

    var iconName: String {
        switch self {
        case .healthy: return "checkmark.circle.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .attention: return "xmark.octagon.fill"
        }
    }
}

struct MonitorHealthItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: String
    let detail: String
    let level: MonitorHealthLevel
}

struct MonitorHealthSnapshot: Equatable, Sendable {
    let checkedAt: Date
    let overall: MonitorHealthLevel
    let items: [MonitorHealthItem]
}

struct MonitorHealthInput: Equatable, Sendable {
    let systemStatus: SampleStatus
    let cpuStatus: SampleStatus
    let gpuStatus: SampleStatus
    let processStatus: SampleStatus
    let observedProcessCount: Int
    let listedProcessCount: Int
    let samplingDiagnostics: SamplingDiagnostics
    let historyRecordCount: Int
    let historyError: String?
    let historyDiagnostics: HistoryStoreDiagnostics?
    let auditError: String?
    let loginStatus: LoginLaunchStatus
    let loginError: String?
    let checkedAt: Date
    /// Optional payload validation supplied by the live monitor. A nil value
    /// skips only payload consistency validation; usable statuses still need a
    /// finite sample timestamp so freshness can be established.
    let systemDataIsUsable: Bool?
    /// The instant against which sample freshness is evaluated. It is
    /// separate from `checkedAt` so a caller can keep the displayed check
    /// timestamp stable while still detecting samples that have gone stale.
    let now: Date

    init(
        systemStatus: SampleStatus,
        cpuStatus: SampleStatus,
        gpuStatus: SampleStatus,
        processStatus: SampleStatus,
        observedProcessCount: Int,
        listedProcessCount: Int,
        samplingDiagnostics: SamplingDiagnostics,
        historyRecordCount: Int,
        historyError: String?,
        historyDiagnostics: HistoryStoreDiagnostics?,
        auditError: String?,
        loginStatus: LoginLaunchStatus,
        loginError: String?,
        checkedAt: Date,
        systemDataIsUsable: Bool? = nil,
        now: Date? = nil
    ) {
        self.systemStatus = systemStatus
        self.cpuStatus = cpuStatus
        self.gpuStatus = gpuStatus
        self.processStatus = processStatus
        self.observedProcessCount = max(observedProcessCount, 0)
        self.listedProcessCount = max(listedProcessCount, self.observedProcessCount)
        self.samplingDiagnostics = samplingDiagnostics
        self.historyRecordCount = max(historyRecordCount, 0)
        self.historyError = historyError
        self.historyDiagnostics = historyDiagnostics
        self.auditError = auditError
        self.loginStatus = loginStatus
        self.loginError = loginError
        self.checkedAt = checkedAt
        self.systemDataIsUsable = systemDataIsUsable
        self.now = now ?? checkedAt
    }
}

enum MonitorHealthEvaluator {
    private static let systemStaleAfter: TimeInterval = 90
    private static let cpuStaleAfter: TimeInterval = 90
    private static let processStaleAfter: TimeInterval = 120
    private static let gpuStaleAfter: TimeInterval = 180

    static func evaluate(_ input: MonitorHealthInput) -> MonitorHealthSnapshot {
        var items: [MonitorHealthItem] = []
        items.append(metricItem(
            id: "system",
            title: "系统内存",
            status: input.systemStatus,
            estimatedDetail: "内存使用率按可回收内存估算",
            now: input.now,
            staleAfter: systemStaleAfter,
            staleLevel: .attention,
            dataIsUsable: input.systemDataIsUsable
        ))
        items.append(metricItem(
            id: "cpu",
            title: "CPU 采样",
            status: input.cpuStatus,
            estimatedDetail: "使用整机累计计数计算",
            now: input.now,
            staleAfter: cpuStaleAfter,
            staleLevel: .degraded
        ))
        items.append(gpuItem(input.gpuStatus, now: input.now))
        items.append(processItem(input))
        items.append(samplingItem(input.samplingDiagnostics))
        items.append(historyItem(input))
        items.append(auditItem(input.auditError))
        items.append(loginItem(input.loginStatus, error: input.loginError))

        let overall = items.map(\.level).max() ?? .healthy
        return MonitorHealthSnapshot(
            checkedAt: input.checkedAt,
            overall: overall,
            items: items
        )
    }

    private static func metricItem(
        id: String,
        title: String,
        status: SampleStatus,
        estimatedDetail: String,
        now: Date,
        staleAfter: TimeInterval,
        staleLevel: MonitorHealthLevel,
        dataIsUsable: Bool? = nil
    ) -> MonitorHealthItem {
        switch status.quality {
        case .available, .estimated:
            let baseStatus = status.quality == .available ? "实时" : "部分可用"
            let baseDetail = status.message ?? estimatedDetail
            if dataIsUsable == false {
                return MonitorHealthItem(
                    id: id,
                    title: title,
                    status: "数据异常",
                    detail: baseDetail + "；采样值未通过一致性校验",
                    level: staleLevel
                )
            }
            switch freshness(of: status, now: now, staleAfter: staleAfter) {
            case .fresh:
                return MonitorHealthItem(
                    id: id,
                    title: title,
                    status: baseStatus,
                    detail: baseDetail,
                    level: .healthy
                )
            case .stale(let age):
                return MonitorHealthItem(
                    id: id,
                    title: title,
                    status: "已过期",
                    detail: baseDetail + "；距采样 " + formatAge(age),
                    level: staleLevel
                )
            case .invalid:
                return MonitorHealthItem(
                    id: id,
                    title: title,
                    status: "时间异常",
                    detail: baseDetail + "；采样时间无效或晚于诊断时间",
                    level: staleLevel
                )
            }
        case .unavailable:
            return MonitorHealthItem(
                id: id,
                title: title,
                status: "暂无数据",
                detail: status.message ?? "等待下一次成功采样",
                level: .attention
            )
        case .error:
            return MonitorHealthItem(
                id: id,
                title: title,
                status: "采集失败",
                detail: status.message ?? "采样源返回错误",
                level: .attention
            )
        }
    }

    private static func gpuItem(_ status: SampleStatus, now: Date) -> MonitorHealthItem {
        switch status.quality {
        case .available, .estimated:
            let baseStatus = status.quality == .available ? "实时" : "部分可用"
            let baseDetail = status.message ?? (status.quality == .available
                ? "IOAccelerator 利用率可用"
                : "GPU 利用率为估算值")
            switch freshness(of: status, now: now, staleAfter: gpuStaleAfter) {
            case .fresh:
                return MonitorHealthItem(
                    id: "gpu",
                    title: "GPU 采样",
                    status: baseStatus,
                    detail: baseDetail,
                    level: status.quality == .available ? .healthy : .degraded
                )
            case .stale(let age):
                return MonitorHealthItem(
                    id: "gpu",
                    title: "GPU 采样",
                    status: "已过期",
                    detail: baseDetail + "；距采样 " + formatAge(age) + "，不影响内存监视",
                    level: .degraded
                )
            case .invalid:
                return MonitorHealthItem(
                    id: "gpu",
                    title: "GPU 采样",
                    status: "时间异常",
                    detail: baseDetail + "；采样时间无效或晚于诊断时间，不影响内存监视",
                    level: .degraded
                )
            }
        case .unavailable:
            return MonitorHealthItem(
                id: "gpu",
                title: "GPU 采样",
                status: "未提供",
                detail: status.message ?? "系统未提供 GPU 利用率；不影响内存监视",
                level: .degraded
            )
        case .error:
            return MonitorHealthItem(
                id: "gpu",
                title: "GPU 采样",
                status: "采集失败",
                detail: status.message ?? "GPU 数据源返回错误；不影响内存监视",
                level: .degraded
            )
        }
    }

    private static func processItem(_ input: MonitorHealthInput) -> MonitorHealthItem {
        let observed = input.observedProcessCount
        let listed = input.listedProcessCount
        let coverage = listed > 0
            ? "已读取 " + String(observed) + "/" + String(listed) + " 个进程"
            : "尚未读取进程条目"
        switch input.processStatus.quality {
        case .available, .estimated:
            let baseStatus = input.processStatus.quality == .available ? "完整" : "部分可用"
            let baseDetail = [
                coverage,
                input.processStatus.message ?? (input.processStatus.quality == .available
                    ? ""
                    : "部分条目受权限限制")
            ].filter { !$0.isEmpty }.joined(separator: "；")
            switch freshness(
                of: input.processStatus,
                now: input.now,
                staleAfter: processStaleAfter
            ) {
            case .fresh:
                return MonitorHealthItem(
                    id: "processes",
                    title: "进程读取",
                    status: baseStatus,
                    detail: baseDetail,
                    level: input.processStatus.quality == .available ? .healthy : .degraded
                )
            case .stale(let age):
                return MonitorHealthItem(
                    id: "processes",
                    title: "进程读取",
                    status: "已过期",
                    detail: baseDetail + "；距采样 " + formatAge(age) + "，显示内容仅供参考",
                    level: .attention
                )
            case .invalid:
                return MonitorHealthItem(
                    id: "processes",
                    title: "进程读取",
                    status: "时间异常",
                    detail: baseDetail + "；采样时间无效或晚于诊断时间",
                    level: .attention
                )
            }
        case .unavailable:
            let detail = observed > 0
                ? coverage + "；显示最近一次成功采样"
                : (input.processStatus.message ?? "等待首次进程采样")
            return MonitorHealthItem(
                id: "processes",
                title: "进程读取",
                status: "暂无新数据",
                detail: detail,
                level: observed > 0 ? .degraded : .attention
            )
        case .error:
            return MonitorHealthItem(
                id: "processes",
                title: "进程读取",
                status: "采集失败",
                detail: input.processStatus.message ?? "无法读取进程列表",
                level: .attention
            )
        }
    }

    private static func historyItem(_ input: MonitorHealthInput) -> MonitorHealthItem {
        if let error = input.historyError, !error.isEmpty {
            return MonitorHealthItem(
                id: "history",
                title: "24 小时历史",
                status: "写入受限",
                detail: error,
                level: .attention
            )
        }
        guard input.historyRecordCount > 0 else {
            return MonitorHealthItem(
                id: "history",
                title: "24 小时历史",
                status: "等待积累",
                detail: "尚未积累分钟样本，监视不受影响",
                level: .degraded
            )
        }
        let bytes = input.historyDiagnostics?.totalBytes ?? 0
        return MonitorHealthItem(
            id: "history",
            title: "24 小时历史",
            status: "正常",
            detail: bytes > 0
                ? String(input.historyRecordCount) + " 个样本 · " + MemoryFormatter.bytes(UInt64(bytes))
                : String(input.historyRecordCount) + " 个样本",
            level: .healthy
        )
    }

    private static func samplingItem(_ diagnostics: SamplingDiagnostics) -> MonitorHealthItem {
        let duration = String(format: "%.0f ms", diagnostics.totalDurationMilliseconds)
        let processDuration = diagnostics.processDurationMilliseconds.map {
            String(format: "；进程扫描 %.0f ms", $0)
        } ?? ""
        let detail = "本轮 " + duration + processDuration
        if diagnostics.totalDurationMilliseconds >= 2_000 {
            return MonitorHealthItem(
                id: "sampling",
                title: "采样性能",
                status: "较慢",
                detail: detail + "；建议关闭面板后观察是否恢复",
                level: .attention
            )
        }
        if diagnostics.totalDurationMilliseconds >= 500 {
            return MonitorHealthItem(
                id: "sampling",
                title: "采样性能",
                status: "需留意",
                detail: detail,
                level: .degraded
            )
        }
        return MonitorHealthItem(
            id: "sampling",
            title: "采样性能",
            status: "正常",
            detail: detail,
            level: .healthy
        )
    }

    private static func auditItem(_ error: String?) -> MonitorHealthItem {
        guard let error, !error.isEmpty else {
            return MonitorHealthItem(
                id: "audit",
                title: "操作审计",
                status: "正常",
                detail: "本地受限记录可用",
                level: .healthy
            )
        }
        return MonitorHealthItem(
            id: "audit",
            title: "操作审计",
            status: "记录受限",
            detail: error,
            level: .degraded
        )
    }

    private static func loginItem(
        _ status: LoginLaunchStatus,
        error: String?
    ) -> MonitorHealthItem {
        let detail = [status.detail, error].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: "；")
        let level: MonitorHealthLevel
        if let error, !error.isEmpty {
            // A runtime status can remain `.notRegistered` after a failed
            // register/unregister call. The explicit error is stronger
            // evidence than that stale status and must be reflected in the
            // overall health level.
            level = .attention
        } else {
            switch status {
            case .enabled, .notRegistered:
                level = .healthy
            case .requiresApproval, .unavailable:
                level = .degraded
            case .notFound, .failed:
                level = .attention
            }
        }
        return MonitorHealthItem(
            id: "login",
            title: "登录启动",
            status: status.title,
            detail: detail,
            level: level
        )
    }

    private enum SampleFreshness {
        case fresh
        case stale(TimeInterval)
        case invalid
    }

    private static func freshness(
        of status: SampleStatus,
        now: Date,
        staleAfter: TimeInterval
    ) -> SampleFreshness {
        guard let sampledAt = status.sampledAt,
              sampledAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite,
              staleAfter.isFinite,
              staleAfter >= 0 else {
            return .invalid
        }
        let age = now.timeIntervalSince(sampledAt)
        guard age.isFinite else { return .invalid }
        // A small negative age is normal when independent providers finish a
        // few milliseconds after the diagnostic timestamp. Larger future
        // values indicate a broken clock or malformed input.
        if age < -5 { return .invalid }
        if age > staleAfter { return .stale(age) }
        return .fresh
    }

    private static func formatAge(_ age: TimeInterval) -> String {
        guard age.isFinite, age >= 0 else { return "时间未知" }
        if age < 60 {
            return String(format: "%.0f 秒", age)
        }
        if age < 3_600 {
            return String(format: "%.0f 分钟", age / 60)
        }
        return String(format: "%.1f 小时", age / 3_600)
    }
}

enum AuditEventFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case completed
    case attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .completed: return "已完成"
        case .attention: return "需关注"
        }
    }

    func matches(_ event: ProcessActionAuditEvent) -> Bool {
        switch self {
        case .all:
            return true
        case .completed:
            return event.phase == .terminal && event.outcome == .completed
        case .attention:
            // Intent and signal-sent records are successful lifecycle stages,
            // not attention-worthy outcomes. Only terminal failures,
            // cancellations, and timeouts belong in this result filter.
            return event.phase == .terminal && event.outcome != .completed
        }
    }
}

enum AuditEventFiltering {
    static func apply(
        events: [ProcessActionAuditEvent],
        filter: AuditEventFilter,
        query: String
    ) -> [ProcessActionAuditEvent] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return events
            .filter(filter.matches)
            .filter { event in
                guard !normalizedQuery.isEmpty else { return true }
                let fields = [event.processLabel, event.applicationName, event.detail]
                    .compactMap { $0?.lowercased() }
                return fields.contains { $0.contains(normalizedQuery) }
            }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.id < $1.id
            }
    }
}
