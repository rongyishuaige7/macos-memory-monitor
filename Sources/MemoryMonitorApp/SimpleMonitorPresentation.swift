import Foundation
import MemoryMonitorCore

enum SimpleMonitorPresentation {
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    static func pressureTitle(usable: Bool, level: MemoryPressureLevel?) -> String {
        guard usable, let level else { return "暂时无法读取" }
        switch level {
        case .normal: return "内存充足"
        case .attention: return "内存有些紧张"
        case .critical: return "内存紧张"
        }
    }

    static func listNotice(status: MonitorDetailDataStatus) -> String? {
        switch status.kind {
        case .current: return nil
        case .loading: return "正在读取…"
        case .partial: return "部分进程暂时无法读取"
        case .retained: return "显示上次读取的数据"
        case .failed, .unavailable:
            return status.hasRetainedData ? "暂时无法更新，显示上次数据" : "暂时无法读取进程"
        }
    }
}
