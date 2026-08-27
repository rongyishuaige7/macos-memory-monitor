import AppKit
import Charts
import Combine
import Darwin
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
    @Published private(set) var systemStatus = SampleStatus.unavailable(message: "等待首次采样")
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

    let processActions: ProcessActionController
    private var refreshTask: Task<Void, Never>?
    private let sampler = MonitorSampler()
    private let samplingPolicy = AdaptiveSamplingPolicy()
    private let recommendationEngine = RecommendationEngine()
    private let historyAnalyzer = MemoryHistoryAnalyzer()
    private var pressureEvaluator = MemoryPressureEvaluator()
    private let refreshWakeup = RefreshWakeup()
    private let historyStore = HistoryStore()
    private var historyBuffer = MemoryHistoryBuffer(capacity: 60)
    private var historyStoreAvailable = true
    private var previousCPUTime: CPUTimeSnapshot?
    private var lastProcessSampleAt: Date?
    private var previousRecommendationSystem: SystemMemorySnapshot?
    private var previousRecommendationProcessSystem: SystemMemorySnapshot?
    private var previousRecommendationGroups: [WorkloadGroupSnapshot] = []
    private var previousRecommendationProcessStatus: SampleStatus?
    private var previousRecommendationPressureLevel: MemoryPressureLevel?
    private var lastRecommendationKey: String?
    private var lastRecommendationAt: Date?
    private let recommendationCooldown: TimeInterval = 30 * 60

    init() {
        processActions = ProcessActionController()
        refreshTask = Task { [weak self] in
            await self?.refreshLoop()
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    var pressure: PressureState {
        guard systemStatus.quality.isUsable, let pressureLevel else { return .unknown }
        return PressureState(level: pressureLevel)
    }

    var processObservationDescription: String {
        switch processStatus.quality {
        case .available:
            return "已采集 \(observedProcessCount) 个进程"
        case .estimated:
            return "已采集 \(observedProcessCount)/\(listedProcessCount) 个进程"
        case .unavailable, .error:
            return observedProcessCount > 0
                ? "上次采样 \(observedProcessCount) 个进程"
                : "进程数据 \(processStatus.quality.displayName)"
        }
    }

    var samplingIssueDescription: String? {
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

    private func refreshLoop() async {
        do {
            history = try await historyStore.load()
            historyError = nil
        } catch {
            historyStoreAvailable = false
            historyError = error.localizedDescription
        }
        historyDiagnostics = await historyStore.diagnostics()

        while !Task.isCancelled {
            let mode = samplingPolicy.samplingMode(
                panelPresented: isPanelPresented,
                pressureActive: pressureEvaluator.pressureActiveForSampling,
                now: Date(),
                lastProcessSampleAt: lastProcessSampleAt
            )
            let snapshot = await Task.detached(priority: .utility) { [sampler] in
                sampler.sample(mode: mode)
            }.value

            samplingDiagnostics = snapshot.diagnostics
            systemStatus = snapshot.systemStatus
            cpuStatus = snapshot.cpuStatus
            gpuStatus = snapshot.gpuStatus

            if snapshot.didSampleProcesses {
                lastProcessSampleAt = snapshot.timestamp
                processStatus = snapshot.processStatus
                if snapshot.processStatus.quality.isUsable {
                    processes = snapshot.processes
                    groups = snapshot.groups
                    observedProcessCount = snapshot.sampledProcessCount
                    listedProcessCount = snapshot.listedProcessCount
                }
            }

            if let systemSnapshot = snapshot.system {
                pressureLevel = pressureEvaluator.update(snapshot: systemSnapshot)
                historyBuffer.append(snapshot: systemSnapshot)
                if historyStoreAvailable {
                    do {
                        history = try await historyStore.append(
                            snapshot: systemSnapshot,
                            groups: groups,
                            now: snapshot.timestamp
                        )
                        historyError = nil
                        historyDiagnostics = await historyStore.diagnostics()
                    } catch {
                        historyStoreAvailable = false
                        historyError = error.localizedDescription
                        history = historyBuffer.entries.map { MemoryHistoryRecord(entry: $0) }
                        historyDiagnostics = await historyStore.diagnostics()
                    }
                } else {
                    history = historyBuffer.entries.map { MemoryHistoryRecord(entry: $0) }
                }
                system = systemSnapshot
            }

            let recommendationContext = RecommendationContext(
                current: snapshot,
                previousSystem: previousRecommendationSystem,
                previousProcessSystem: previousRecommendationProcessSystem,
                previousGroups: previousRecommendationGroups,
                previousProcessStatus: previousRecommendationProcessStatus,
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

            updateRecommendation(
                recommendationEngine.evaluate(recommendationContext).first,
                at: snapshot.timestamp,
                allowClearing: snapshot.didSampleProcesses
            )

            if let systemSnapshot = snapshot.system {
                previousRecommendationSystem = systemSnapshot
            }
            if snapshot.didSampleProcesses, snapshot.processStatus.quality.isUsable {
                previousRecommendationProcessSystem = snapshot.system
                previousRecommendationGroups = snapshot.groups
                previousRecommendationProcessStatus = snapshot.processStatus
            }
            if let pressureLevel {
                previousRecommendationPressureLevel = pressureLevel
            }

            updatedAt = snapshot.timestamp
            lastError = samplingIssueDescription

            guard await waitForNextSample() else { break }
        }

        if historyStoreAvailable {
            try? await historyStore.flush()
        }
    }

    private func updateRecommendation(
        _ candidate: MemoryRecommendation?,
        at timestamp: Date,
        allowClearing: Bool
    ) {
        guard let candidate else {
            // A system-only pass has no fresh process evidence. Keep the last
            // actionable explanation visible until a process sample confirms
            // that it is no longer relevant.
            guard allowClearing else { return }
            recommendation = nil
            lastRecommendationKey = nil
            lastRecommendationAt = nil
            return
        }

        if candidate.deduplicationKey == lastRecommendationKey,
           let lastRecommendationAt,
           timestamp.timeIntervalSince(lastRecommendationAt) < recommendationCooldown {
            return
        }

        recommendation = candidate
        lastRecommendationKey = candidate.deduplicationKey
        lastRecommendationAt = timestamp
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
                model.systemStatus.quality.isUsable
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
    @State private var listMode: MonitorListMode = .processes
    @State private var viewMode: MonitorViewMode = .live
    @State private var processScope: ProcessScope = .all
    @State private var processSortMode: ProcessSortMode = .footprint
    @State private var searchText = ""
    @State private var detailSelection: MonitorDetailSelection?

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
        HStack(alignment: .top) {
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
                    Text(model.systemStatus.quality.isUsable ? model.pressure.title : "采集受限")
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
                Text("置信度 \(recommendation.confidencePercent)% · 只读建议")
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
                fraction: model.systemStatus.quality.isUsable ? model.system?.usedFraction : nil,
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
        }.filter(matchesSearch)

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
                .frame(height: 230)
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
            return groupFieldsMatch || model.processes(in: group).contains(where: matchesSearch)
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
            Text("已采集本机所有可枚举进程；组内数值为 footprint/RSS 相加的归因总量，当前按 \(processSortMode == .footprint ? "footprint" : "RSS") 降序，包含共享映射，不能相加当作整机实际占用。")
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
                            Button {
                                detailSelection = .group(group.id)
                            } label: {
                                WorkloadGroupRow(group: group)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 230)
            }
        }
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
            Text("本地监视 · 操作需确认 · \(model.samplingCadenceDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.samplingDiagnosticsDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("Apple Silicon")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProcessDetailView: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var actions: ProcessActionController
    let identity: ProcessIdentity
    @Environment(\.dismiss) private var dismiss
    @State private var showGracefulConfirmation = false
    @State private var showForceConfirmation = false

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
            }
        }
    }

    private func processContent(_ process: ProcessSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                processHeader(process)
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
                        Text(event.outcome.displayName)
                            .font(.caption2)
                            .foregroundStyle(actionOutcomeColor(event.outcome))
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
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("进程已不在当前采样")
                .font(.title3.weight(.semibold))
            Text("PID \(identity.pid) 的启动身份（\(identity.startTimeSeconds)）已经无法在最新快照中找到。进程可能已退出，也可能受权限限制；不会将复用的 PID 当成同一个进程。")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("进程不在当前快照中，因此没有可执行操作。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WorkloadGroupDetailView: View {
    @ObservedObject var model: MonitorViewModel
    let groupID: String
    @Environment(\.dismiss) private var dismiss

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

private struct DetailSection<Content: View>: View {
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
            } else {
                emptyState
            }
        }
        .frame(height: 540, alignment: .top)
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
