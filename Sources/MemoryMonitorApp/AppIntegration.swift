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
        status = runtime.status()
        lastError = nil
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        isUpdating = true
        lastError = nil

        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                if enabled {
                    try await runtime.register()
                } else {
                    try await runtime.unregister()
                }
                guard !Task.isCancelled else { return }
                status = runtime.status()
                if enabled, !status.isRegistered {
                    lastError = "系统没有确认登录启动已注册，请检查登录项设置。"
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = runtime.status()
                lastError = error.localizedDescription
            }
            isUpdating = false
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
        checkedAt: Date
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
    }
}

enum MonitorHealthEvaluator {
    static func evaluate(_ input: MonitorHealthInput) -> MonitorHealthSnapshot {
        var items: [MonitorHealthItem] = []
        items.append(metricItem(
            id: "system",
            title: "系统内存",
            status: input.systemStatus,
            estimatedDetail: "内存使用率按可回收内存估算"
        ))
        items.append(metricItem(
            id: "cpu",
            title: "CPU 采样",
            status: input.cpuStatus,
            estimatedDetail: "使用整机累计计数计算"
        ))
        items.append(gpuItem(input.gpuStatus))
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
        estimatedDetail: String
    ) -> MonitorHealthItem {
        switch status.quality {
        case .available:
            return MonitorHealthItem(
                id: id,
                title: title,
                status: "实时",
                detail: status.message ?? estimatedDetail,
                level: .healthy
            )
        case .estimated:
            return MonitorHealthItem(
                id: id,
                title: title,
                status: "部分可用",
                detail: status.message ?? estimatedDetail,
                level: .healthy
            )
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

    private static func gpuItem(_ status: SampleStatus) -> MonitorHealthItem {
        switch status.quality {
        case .available:
            return MonitorHealthItem(
                id: "gpu",
                title: "GPU 采样",
                status: "实时",
                detail: status.message ?? "IOAccelerator 利用率可用",
                level: .healthy
            )
        case .estimated:
            return MonitorHealthItem(
                id: "gpu",
                title: "GPU 采样",
                status: "部分可用",
                detail: status.message ?? "GPU 利用率为估算值",
                level: .degraded
            )
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
        case .available:
            return MonitorHealthItem(
                id: "processes",
                title: "进程读取",
                status: "完整",
                detail: coverage,
                level: .healthy
            )
        case .estimated:
            return MonitorHealthItem(
                id: "processes",
                title: "进程读取",
                status: "部分可用",
                detail: [coverage, input.processStatus.message ?? "部分条目受权限限制"].joined(separator: "；"),
                level: .degraded
            )
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
        switch status {
        case .enabled, .notRegistered:
            level = .healthy
        case .requiresApproval, .unavailable:
            level = .degraded
        case .notFound, .failed:
            level = .attention
        }
        return MonitorHealthItem(
            id: "login",
            title: "登录启动",
            status: status.title,
            detail: detail,
            level: level
        )
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
            return event.outcome == .completed
        case .attention:
            return event.outcome != .completed
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
