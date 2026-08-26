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
    @Published private(set) var cpuUsageFraction: Double?
    @Published private(set) var gpuUsageFraction: Double?
    @Published private(set) var processes: [ProcessSnapshot] = []
    @Published private(set) var groups: [WorkloadGroupSnapshot] = []
    @Published private(set) var observedProcessCount = 0
    @Published private(set) var history: [MemoryHistoryRecord] = []
    @Published private(set) var lastError: String?
    @Published private(set) var historyError: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isPanelPresented = false
    @Published private(set) var pressureLevel: MemoryPressureLevel?

    private var refreshTask: Task<Void, Never>?
    private let sampler = MonitorSampler()
    private let samplingPolicy = AdaptiveSamplingPolicy()
    private var pressureEvaluator = MemoryPressureEvaluator()
    private let refreshWakeup = RefreshWakeup()
    private let historyStore = HistoryStore()
    private var historyBuffer = MemoryHistoryBuffer(capacity: 60)
    private var historyStoreAvailable = true
    private var previousCPUTime: CPUTimeSnapshot?

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
                if let cpuTime = snapshot.cpuTime {
                    cpuUsageFraction = previousCPUTime.flatMap {
                        CPUUsageCalculator.usedFraction(current: cpuTime, previous: $0)
                    }
                    previousCPUTime = cpuTime
                } else {
                    cpuUsageFraction = nil
                    previousCPUTime = nil
                }
                gpuUsageFraction = snapshot.gpuUsageFraction
                system = snapshot.system
                processes = snapshot.processes
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
    private let cpuSampler = CPUTimeSampler()
    private let gpuSampler = GPUUsageSampler()
    private let processSampler = ProcessSampler()

    func sample() -> Result<MonitorSnapshot, Error> {
        do {
            let cpuTime = try? cpuSampler.sample()
            let system = try systemSampler.sample()
            let processes = try processSampler.sample()
                .sorted {
                    if $0.physicalFootprintBytes != $1.physicalFootprintBytes {
                        return $0.physicalFootprintBytes > $1.physicalFootprintBytes
                    }
                    if $0.residentBytes != $1.residentBytes {
                        return $0.residentBytes > $1.residentBytes
                    }
                    return $0.identity.pid < $1.identity.pid
                }
            return .success(MonitorSnapshot(
                timestamp: Date(),
                system: system,
                cpuTime: cpuTime,
                gpuUsageFraction: gpuSampler.sample(),
                processes: processes,
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
    let cpuTime: CPUTimeSnapshot?
    let gpuUsageFraction: Double?
    let processes: [ProcessSnapshot]
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
                    ? (model.system.map { "内存 \(Int($0.usedFraction * 100))%" } ?? "内存 --")
                    : "内存 --"
            )
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
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

private struct MonitorPopover: View {
    @ObservedObject var model: MonitorViewModel
    @State private var listMode: MonitorListMode = .processes

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            metrics
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
                title: "CPU",
                fraction: model.cpuUsageFraction
            )
            MetricTile(
                title: "内存",
                fraction: model.system?.usedFraction
            )
            MetricTile(
                title: "GPU",
                fraction: model.gpuUsageFraction
            )
        }
    }

    private var processList: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("内存占用")
                    .font(.headline)
                Spacer()
                Text(listMode == .processes ? "footprint 降序" : "归因总量 · footprint")
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

            switch listMode {
            case .processes:
                processRanking
            case .groups:
                groupRanking
            }
        }
    }

    private var sortedProcesses: [ProcessSnapshot] {
        model.processes.sorted {
            if $0.physicalFootprintBytes != $1.physicalFootprintBytes {
                return $0.physicalFootprintBytes > $1.physicalFootprintBytes
            }
            if $0.residentBytes != $1.residentBytes {
                return $0.residentBytes > $1.residentBytes
            }
            return $0.identity.pid < $1.identity.pid
        }
    }

    private var processRanking: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("按单个进程 footprint 从大到小排列")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("共 \(sortedProcesses.count) 个")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if sortedProcesses.isEmpty {
                Text("正在读取进程数据...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 150, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedProcesses.enumerated()), id: \.element.id) { index, process in
                            ProcessRow(rank: index + 1, process: process)
                            if index < sortedProcesses.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(height: 230)
            }
        }
    }

    private var sortedGroups: [WorkloadGroupSnapshot] {
        model.groups.sorted {
            if $0.attributedFootprintBytes != $1.attributedFootprintBytes {
                return $0.attributedFootprintBytes > $1.attributedFootprintBytes
            }
            if $0.isSystem != $1.isSystem {
                return !$0.isSystem
            }
            return $0.id < $1.id
        }
    }

    private var groupRanking: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("已采集本机所有可枚举进程；组内数值为 footprint/RSS 相加的归因总量，包含共享映射，不能相加当作整机实际占用。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if sortedGroups.isEmpty {
                Text("暂无工作组数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 150, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(sortedGroups) { group in
                            WorkloadGroupRow(group: group)
                        }
                    }
                }
                .frame(height: 230)
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
    let fraction: Double?

    private var value: String {
        guard let fraction, fraction.isFinite else { return "--" }
        return String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
    }

    private var detail: String {
        fraction == nil ? "暂不可用" : "已使用"
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
