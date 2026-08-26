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
                .onAppear { model.setPanelPresented(true) }
                .onDisappear { model.setPanelPresented(false) }
        } label: {
            MenuBarStatus(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class MonitorViewModel: ObservableObject {
    @Published private(set) var system: SystemMemorySnapshot?
    @Published private(set) var groups: [WorkloadGroupSnapshot] = []
    @Published private(set) var observedProcessCount = 0
    @Published private(set) var growth: [WorkloadGrowth] = []
    @Published private(set) var history: [MemoryHistoryRecord] = []
    @Published private(set) var lastError: String?
    @Published private(set) var historyError: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isPanelPresented = false
    @Published private(set) var pressureLevel: MemoryPressureLevel?

    private var refreshTask: Task<Void, Never>?
    private let sampler = MonitorSampler()
    private let trendAnalyzer = WorkloadTrendAnalyzer()
    private let samplingPolicy = AdaptiveSamplingPolicy()
    private var pressureEvaluator = MemoryPressureEvaluator()
    private let refreshWakeup = RefreshWakeup()
    private let historyStore = HistoryStore()
    private var historyBuffer = MemoryHistoryBuffer(capacity: 60)
    private var historyStoreAvailable = true
    private var previousGroups: [WorkloadGroupSnapshot] = []
    private var previousSampleAt: Date?

    init() {
        refreshTask = Task { [weak self] in
            await self?.refreshLoop()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var pressure: PressureState {
        guard lastError == nil, let pressureLevel else { return .unknown }
        return PressureState(level: pressureLevel)
    }

    var samplingCadenceDescription: String {
        let interval = samplingPolicy.intervalSeconds(
            panelPresented: isPanelPresented,
            pressureActive: pressureEvaluator.pressureActiveForSampling
        )
        if interval.rounded() == interval {
            return "约 \(Int(interval)) 秒刷新"
        }
        return String(format: "约 %.1f 秒刷新", interval)
    }

    func setPanelPresented(_ presented: Bool) {
        guard isPanelPresented != presented else { return }
        isPanelPresented = presented
        Task { await refreshWakeup.signal() }
    }

    private func refreshLoop() async {
        do {
            history = try await historyStore.load()
            historyError = nil
        } catch {
            historyStoreAvailable = false
            historyError = error.localizedDescription
        }

        while !Task.isCancelled {
            let result = await Task.detached(priority: .utility) { [sampler] in
                sampler.sample()
            }.value

            switch result {
            case let .success(snapshot):
                pressureLevel = pressureEvaluator.update(snapshot: snapshot.system)
                historyBuffer.append(snapshot: snapshot.system)
                if historyStoreAvailable {
                    do {
                        history = try await historyStore.append(
                            snapshot: snapshot.system,
                            groups: snapshot.groups,
                            now: snapshot.timestamp
                        )
                        historyError = nil
                    } catch {
                        historyStoreAvailable = false
                        historyError = error.localizedDescription
                        history = historyBuffer.entries.map { MemoryHistoryRecord(entry: $0) }
                    }
                } else {
                    history = historyBuffer.entries.map { MemoryHistoryRecord(entry: $0) }
                }
                if let previousSampleAt {
                    growth = trendAnalyzer.growingGroups(
                        previous: previousGroups,
                        current: snapshot.groups,
                        intervalSeconds: snapshot.timestamp.timeIntervalSince(previousSampleAt)
                    )
                }
                previousGroups = snapshot.groups
                previousSampleAt = snapshot.timestamp
                system = snapshot.system
                groups = snapshot.groups
                observedProcessCount = snapshot.processCount
                updatedAt = snapshot.timestamp
                lastError = nil
            case let .failure(error):
                lastError = error.localizedDescription
            }

            guard await waitForNextSample() else { break }
        }

        if historyStoreAvailable {
            try? await historyStore.flush()
        }
    }

    private func waitForNextSample() async -> Bool {
        let interval = samplingPolicy.intervalSeconds(
            panelPresented: isPanelPresented,
            pressureActive: pressureEvaluator.pressureActiveForSampling
        )
        let wakeup = refreshWakeup

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
    private var waiter: CheckedContinuation<Bool, Never>?
    private var pendingSignal = false

    func signal() {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: true)
        } else {
            pendingSignal = true
        }
    }

    func wait() async -> Bool {
        if pendingSignal {
            pendingSignal = false
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    private func cancelWaiter() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: false)
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
            return .success(MonitorSnapshot(
                timestamp: Date(),
                system: system,
                groups: WorkloadGrouper().group(processes),
                processCount: processes.count
            ))
        } catch {
            return .failure(error)
        }
    }
}

private struct MonitorSnapshot: Sendable {
    let timestamp: Date
    let system: SystemMemorySnapshot
    let groups: [WorkloadGroupSnapshot]
    let processCount: Int
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

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(model.pressure.color)
                .frame(width: 7, height: 7)
            Text(
                model.lastError == nil
                    ? (model.system.map { "RAM \(Int((1 - $0.availableFraction) * 100))%" } ?? "RAM --")
                    : "RAM --"
            )
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
            historyTrend
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
                Text("全量进程观察 · 已采集 \(model.observedProcessCount) 个进程")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.pressure.color)
                        .frame(width: 8, height: 8)
                    Text(model.lastError == nil ? model.pressure.title : "采集受限")
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

                if let fastest = model.growth.first,
                   fastest.deltaBytes >= 16 * 1024 * 1024 {
                    Label(
                        "增长最快：\(fastest.title) +\(MemoryFormatter.bytes(fastest.deltaBytes))",
                        systemImage: "arrow.up.right"
                    )
                    .foregroundStyle(.orange)
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

    private var historyTrend: some View {
        GroupBox("24 小时磁盘历史") {
            if let first = model.history.first, let last = model.history.last, model.history.count >= 2 {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        TrendValue(
                            title: "可用",
                            value: String(format: "%+.1f%%", (last.availableFraction - first.availableFraction) * 100)
                        )
                        TrendValue(
                            title: "压缩",
                            value: signedBytes(last.compressedBytes, comparedTo: first.compressedBytes)
                        )
                        TrendValue(
                            title: "Swap",
                            value: signedBytes(last.swapUsedBytes, comparedTo: first.swapUsedBytes)
                        )
                    }
                    Text("已保存 \(model.history.count) 条分钟记录 · 从 \(first.timestamp, style: .time) 到 \(last.timestamp, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(model.history.isEmpty ? "等待首条分钟记录" : "等待更多采样以生成趋势")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let historyError = model.historyError {
                Text(historyError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("工作组归因")
                    .font(.headline)
                Spacer()
                Text("归因总量 · footprint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("已采集本机所有可枚举进程；组内数值为 footprint/RSS 相加的归因总量，包含共享映射，不能相加当作整机实际占用。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.groups.isEmpty {
                Text("暂无工作组数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.groups) { group in
                            WorkloadGroupRow(group: group)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("只读监视 · 全量进程 · \(model.samplingCadenceDescription)")
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

private struct TrendValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private func signedBytes(_ current: UInt64, comparedTo initial: UInt64) -> String {
    if current >= initial {
        return "+\(MemoryFormatter.bytes(current - initial))"
    }
    return "-\(MemoryFormatter.bytes(initial - current))"
}
