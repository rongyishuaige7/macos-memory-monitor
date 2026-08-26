import AppKit
import Combine
import Foundation
import MemoryMonitorCore
import SwiftUI

@main
struct MemoryMonitorApp: App {
    @StateObject private var model = MonitorViewModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MonitorPopover(model: model)
        } label: {
            MenuBarStatus(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var system: SystemMemorySnapshot?
    @Published private(set) var processes: [ProcessSnapshot] = []
    @Published private(set) var lastError: String?
    @Published private(set) var updatedAt: Date?

    private var refreshTask: Task<Void, Never>?
    private let sampler = MonitorSampler()

    init() {
        refreshTask = Task { [weak self] in
            await self?.refreshLoop()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var pressure: PressureState {
        guard let system else { return .unknown }
        if system.availableFraction < 0.10
            || (system.swapTotalBytes > 0 && system.swapFreeBytes < 1 * 1024 * 1024 * 1024)
            || system.throttledPages > 0 {
            return .critical
        }
        if system.availableFraction < 0.20
            || system.compressedBytes > system.totalBytes / 5
            || (system.swapTotalBytes > 0 && system.swapUsedBytes > system.swapTotalBytes / 2) {
            return .attention
        }
        return .normal
    }

    private func refreshLoop() async {
        while !Task.isCancelled {
            let result = await Task.detached(priority: .utility) { [sampler] in
                sampler.sample()
            }.value

            switch result {
            case let .success(snapshot):
                system = snapshot.system
                processes = snapshot.processes
                updatedAt = snapshot.timestamp
                lastError = nil
            case let .failure(error):
                lastError = error.localizedDescription
            }

            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
        }
    }
}

private struct MonitorSampler: Sendable {
    private let systemSampler = SystemMemorySampler()
    private let processSampler = ProcessSampler()

    func sample() -> Result<MonitorSnapshot, Error> {
        do {
            let system = try systemSampler.sample()
            let processes = try processSampler.sample()
                .sorted { $0.physicalFootprintBytes > $1.physicalFootprintBytes }
            return .success(MonitorSnapshot(timestamp: Date(), system: system, processes: processes))
        } catch {
            return .failure(error)
        }
    }
}

private struct MonitorSnapshot: Sendable {
    let timestamp: Date
    let system: SystemMemorySnapshot
    let processes: [ProcessSnapshot]
}

enum PressureState: String {
    case normal
    case attention
    case critical
    case unknown

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

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(model.pressure.color)
                .frame(width: 7, height: 7)
            Text(model.system.map { "RAM \(Int((1 - $0.availableFraction) * 100))%" } ?? "RAM --")
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
    }
}

private struct MonitorPopover: View {
    @ObservedObject var model: MonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            metrics
            recommendations
            processList
            footer
        }
        .padding(16)
        .frame(width: 410)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory Monitor")
                    .font(.system(size: 18, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.pressure.color)
                        .frame(width: 8, height: 8)
                    Text(model.pressure.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(model.pressure.color)
                }
            }
            Spacer()
            if let updatedAt = model.updatedAt {
                Text(updatedAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var metrics: some View {
        HStack(spacing: 8) {
            MetricTile(
                title: "可用估算",
                value: model.system.map { MemoryFormatter.bytes($0.availableEstimateBytes) } ?? "--",
                detail: model.system.map { String(format: "%.0f%%", $0.availableFraction * 100) } ?? ""
            )
            MetricTile(
                title: "压缩",
                value: model.system.map { MemoryFormatter.bytes($0.compressedBytes) } ?? "--",
                detail: "系统"
            )
            MetricTile(
                title: "Swap",
                value: model.system.map { MemoryFormatter.bytes($0.swapUsedBytes) } ?? "--",
                detail: model.system.map { "剩余 \(MemoryFormatter.bytes($0.swapFreeBytes))" } ?? ""
            )
        }
    }

    private var recommendations: some View {
        GroupBox("建议") {
            VStack(alignment: .leading, spacing: 6) {
                switch model.pressure {
                case .critical:
                    Label("内存压力严重，优先检查增长中的工作组。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                case .attention:
                    Label("内存压力正在升高，观察压缩内存和 swap 趋势。", systemImage: "eye.fill")
                        .foregroundStyle(.orange)
                case .normal:
                    Label("当前没有需要立即处理的内存异常。", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .unknown:
                    Label("正在读取系统指标...", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }

                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("高占用进程")
                    .font(.headline)
                Spacer()
                Text("footprint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.processes.isEmpty {
                Text("暂无进程数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.processes.prefix(8))) { process in
                    ProcessRow(process: process)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("只读监视 · 每 5 秒刷新")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Apple Silicon")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
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

private struct ProcessRow: View {
    let process: ProcessSnapshot

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? process.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("PID \(process.identity.pid) · parent \(process.parentPID)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(MemoryFormatter.bytes(process.physicalFootprintBytes))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
        }
    }
}
