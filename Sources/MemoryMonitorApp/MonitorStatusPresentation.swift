import Foundation
import MemoryMonitorCore

enum MonitorStatusTone: String, Equatable, Sendable {
    case normal
    case loading
    case partial
    case attention
    case critical
    case unavailable
}

struct MonitorStatusPresentation: Equatable, Sendable {
    let title: String
    let detail: String
    let tone: MonitorStatusTone
    let nextStep: String?
}

struct ActionAvailability: Equatable, Sendable {
    let isEnabled: Bool
    let reason: String?

    static let enabled = ActionAvailability(isEnabled: true, reason: nil)

    static func disabled(_ reason: String) -> ActionAvailability {
        ActionAvailability(isEnabled: false, reason: reason)
    }
}

enum MonitorHealthRoute: String, Equatable, Sendable {
    case audit
    case localData
    case processes
    case login
    case runtime
}

enum MonitorStatusProjection {
    static func pressure(
        usable: Bool,
        level: MemoryPressureLevel?
    ) -> MonitorStatusPresentation {
        guard usable, let level else {
            return MonitorStatusPresentation(
                title: "正在读取内存状态",
                detail: "还没有可用于判断的最新系统样本",
                tone: .loading,
                nextStep: "稍候或重新读取"
            )
        }
        switch level {
        case .normal:
            return MonitorStatusPresentation(
                title: "内存充足",
                detail: "当前系统没有明显内存压力",
                tone: .normal,
                nextStep: nil
            )
        case .attention:
            return MonitorStatusPresentation(
                title: "内存有些紧张",
                detail: "系统压力有所升高，可查看主要占用或历史",
                tone: .attention,
                nextStep: "查看主要占用"
            )
        case .critical:
            return MonitorStatusPresentation(
                title: "内存紧张",
                detail: "系统压力较高，建议先查看主要占用",
                tone: .critical,
                nextStep: "查看主要占用"
            )
        }
    }

    static func detail(_ status: MonitorDetailDataStatus) -> MonitorStatusPresentation {
        let message = status.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status.kind {
        case .loading:
            return MonitorStatusPresentation(
                title: "正在读取",
                detail: "等待首个有效进程样本",
                tone: .loading,
                nextStep: "稍候"
            )
        case .current:
            return MonitorStatusPresentation(
                title: "数据可用",
                detail: "当前样本可用",
                tone: .normal,
                nextStep: nil
            )
        case .partial:
            return MonitorStatusPresentation(
                title: "部分数据可用",
                detail: "已显示可读取部分；其余进程可能受权限或读取时机限制",
                tone: .partial,
                nextStep: "查看详情"
            )
        case .retained:
            let age = status.sampleAge.map { "，约 \(Int($0)) 秒前" } ?? ""
            let reason: String
            switch status.retentionReason {
            case .background: reason = "后台采样未更新进程详情"
            case .insufficientCoverage: reason = "本次可用进程覆盖不足"
            case .expired: reason = "样本已过期"
            case .invalidTimestamp: reason = "样本时间无效"
            case .targetUnavailable: reason = "目标进程已不可用"
            case nil: reason = "暂时无法更新"
            }
            return MonitorStatusPresentation(
                title: "显示上次读取的数据",
                detail: reason + age,
                tone: .attention,
                nextStep: "重新读取或查看原因"
            )
        case .failed:
            return MonitorStatusPresentation(
                title: "读取失败",
                detail: message?.isEmpty == false ? message! : "本次进程检查未完成",
                tone: .critical,
                nextStep: "重新读取；不要将失败当作没有可清理对象"
            )
        case .unavailable:
            return MonitorStatusPresentation(
                title: "暂时无法读取",
                detail: message?.isEmpty == false ? message! : "当前没有可用的进程数据",
                tone: .unavailable,
                nextStep: "重新读取"
            )
        }
    }

    static func manualAction(
        busy: Bool,
        shuttingDown: Bool,
        auditQueueFull: Bool,
        auditError: String?
    ) -> ActionAvailability {
        if shuttingDown { return .disabled("应用正在退出") }
        if busy { return .disabled("已有进程操作正在进行，请先完成或停止当前操作") }
        if auditQueueFull { return .disabled("操作记录待写队列已满，请先恢复记录") }
        if auditError != nil { return .disabled("操作记录暂不可用，无法安全发送新的退出请求") }
        return .enabled
    }

    static func recoveryStatus(_ error: Error?) -> MonitorStatusPresentation? {
        guard let error else { return nil }
        if let storeError = error as? HistoryStoreError {
            switch storeError {
            case .recoveryRequired:
                return MonitorStatusPresentation(
                    title: "数据恢复尚未完成",
                    detail: "检测到未完成的恢复事务，相关存储操作已暂停",
                    tone: .critical,
                    nextStep: "保留现场并按恢复说明处理"
                )
            case .lockTimedOut:
                return MonitorStatusPresentation(
                    title: "本地数据正在被使用",
                    detail: "等待本地存储锁超时，未读取或修改数据",
                    tone: .attention,
                    nextStep: "稍后重新检查"
                )
            case .readFailed:
                return MonitorStatusPresentation(
                    title: "无法读取本地数据",
                    detail: "没有修改权限或文件状态",
                    tone: .unavailable,
                    nextStep: "查看说明或重新检查"
                )
            case .writeFailed, .fileTooLarge, .invalidData, .unsupportedVersion:
                return MonitorStatusPresentation(
                    title: "本地数据异常",
                    detail: "检查未完成，未自动修复或清空",
                    tone: .critical,
                    nextStep: "查看脱敏摘要或本地数据说明"
                )
            }
        }
        if let restoreError = error as? StorageRestoreError,
           case .manualRecoveryRequired = restoreError {
            return MonitorStatusPresentation(
                title: "需要人工恢复",
                detail: "旧恢复事务缺少完整性清单，已拒绝自动回滚；数据、标记和副本仍保留",
                tone: .critical,
                nextStep: "保留现场并按恢复说明处理"
            )
        }
        return nil
    }

    static func healthRoute(for itemID: String) -> MonitorHealthRoute? {
        switch itemID {
        case "audit": return .audit
        case "history": return .localData
        case "processes": return .processes
        case "login": return .login
        case "environment": return .runtime
        default: return nil
        }
    }
}
