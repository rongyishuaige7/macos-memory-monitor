import AppKit
import Charts
import MemoryMonitorCore
import SwiftUI

struct DesktopShell: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var navigation: DesktopNavigation
    @ObservedObject var memoryTest: MemoryTestController
    @AppStorage("desktopAppearance") private var appearance = "dark"

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pageTitle).font(.system(size: 24, weight: .semibold))
                        Text(pageSubtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if memoryTest.isRunning {
                        Label("测试中", systemImage: "cpu").font(.caption).foregroundStyle(.orange)
                    }
                    Label(model.pressure.title, systemImage: "circle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(model.pressure.color)
                    Button { model.refreshHealth() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless).help("刷新数据")
                    .accessibilityLabel("刷新数据")
                }
                .padding(.horizontal, 28).padding(.vertical, 18)
                Group {
                    switch navigation.page {
                    case .overview: DesktopOverview(model: model, navigation: navigation)
                    case .processes: DesktopProcesses(model: model, navigation: navigation)
                    case .cleanup: DesktopRelease(model: model, actions: model.processActions, navigation: navigation)
                    case .history: DesktopHistory(model: model)
                    case .stress: DesktopTestInstrument(model: model, test: memoryTest)
                    case .settings: DesktopPreferences(model: model, login: model.loginLaunch, navigation: navigation)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 0.5) }
        }
        .tint(.blue)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, appearance == "light" ? .light : .dark)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                Image(systemName: "memorychip.fill").font(.system(size: 23)).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory Monitor").font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text("Mac 内存管理").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 24).padding(.bottom, 22)
            ForEach(DesktopPage.allCases) { page in
                Button {
                    navigation.page = page
                } label: {
                    Label(page.title, systemImage: page.symbol)
                        .font(.system(size: 14, weight: navigation.page == page ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13).frame(height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(navigation.page == page ? Color.primary : Color.secondary)
                .background(navigation.page == page ? Color.blue.opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(alignment: .leading) {
                    if navigation.page == page { Capsule().fill(.cyan).frame(width: 3, height: 16).padding(.leading, 2) }
                }
                .monitorRowHover(selected: navigation.page == page)
                .accessibilityIdentifier("desktop-nav-" + page.rawValue)
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 7) {
                Text(ProcessInfo.processInfo.hostName).lineLimit(1).truncationMode(.middle)
                Text("\(SimpleMonitorPresentation.memory(ProcessInfo.processInfo.physicalMemory)) 内存")
                    .foregroundStyle(.secondary)
            }
            .font(.caption).padding(12)
        }
        .padding(.horizontal, 12).padding(.bottom, 14)
        .frame(width: 182)
        .background(.ultraThinMaterial)
    }

    private var pageTitle: String {
        switch navigation.page {
        case .overview: "内存状态"
        case .processes: "进程管理"
        case .cleanup: "释放内存"
        case .history: "内存历史"
        case .stress: "内存压力测试"
        case .settings: "设置"
        }
    }

    private var pageSubtitle: String {
        switch navigation.page {
        case .overview: SimpleMonitorPresentation.pressureTitle(usable: model.systemDataIsUsable, level: model.pressureLevel)
        case .processes: "\(model.processes.count) 个已读取进程"
        case .cleanup: "退出不再使用的应用，释放它们占用的内存"
        case .history: "最近 24 小时的本机记录"
        case .stress: "短时增加内存负载，观察 Mac 的响应"
        case .settings: "通用与外观"
        }
    }
}

struct DesktopOverview: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var navigation: DesktopNavigation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 30) {
                    MemoryUsageRing(system: model.systemDataIsUsable ? model.system : nil)
                        .frame(width: 216, height: 216)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("最近 1 小时").font(.system(size: 13, weight: .medium))
                            Spacer()
                            Button { navigation.page = .history } label: {
                                Image(systemName: "arrow.up.right")
                            }.buttonStyle(.borderless).help("查看内存历史").accessibilityLabel("查看内存历史")
                        }
                        MemoryTrend(records: model.history, hours: 1, now: model.updatedAt ?? Date(), compact: true)
                            .frame(height: 164)
                    }
                    .frame(maxWidth: .infinity)
                }
                MemoryMetrics(system: model.systemDataIsUsable ? model.system : nil)
                HStack(spacing: 12) {
                    Button {
                        navigation.page = .cleanup
                    } label: {
                        Label("释放内存", systemImage: "sparkles")
                            .frame(minWidth: 160)
                    }.buttonStyle(MonitorPrimaryButtonStyle())
                    Button("查看进程", systemImage: "list.bullet.rectangle") { navigation.page = .processes }
                        .buttonStyle(.bordered).controlSize(.large)
                    Spacer()
                }
                HStack {
                    Label("\(model.processes.count) 个进程", systemImage: "square.stack.3d.up")
                    Spacer()
                    if let updated = model.updatedAt {
                        Text("更新于 " + updated.formatted(date: .omitted, time: .standard))
                    }
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                if let notice = SimpleMonitorPresentation.listNotice(status: model.detailDataStatus(
                    retainedItemCount: model.processes.count, targetPresent: !model.processes.isEmpty
                )) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
    }
}

struct MemoryUsageRing: View {
    let system: SystemMemorySnapshot?

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.035), lineWidth: 30)
            Circle().stroke(.blue.opacity(0.13), lineWidth: 15)
            Circle().trim(from: 0, to: system?.usedFraction ?? 0)
                .stroke(AngularGradient(colors: [.cyan, .blue], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360 * (system?.usedFraction ?? 1))),
                        style: StrokeStyle(lineWidth: 15, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: .cyan.opacity(0.24), radius: 6)
            Circle().trim(from: 0, to: system?.usedFraction ?? 0)
                .stroke(.white.opacity(0.28), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .padding(-6).rotationEffect(.degrees(-90))
            VStack(spacing: 9) {
                Text("内存使用率").font(.system(size: 13)).foregroundStyle(.secondary)
                Text(system.map { "\(Int($0.usedFraction * 100))%" } ?? "--")
                    .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(system.map {
                    "\(SimpleMonitorPresentation.memory($0.usedEstimateBytes)) / \(SimpleMonitorPresentation.memory($0.totalBytes))"
                } ?? "等待数据")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(20)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
        .help("使用量为扣除估算可用内存后的值")
    }
}

struct MemoryMetrics: View {
    let system: SystemMemorySnapshot?

    var body: some View {
        HStack(spacing: 10) {
            MemoryMetric(title: "可用内存", bytes: system?.availableEstimateBytes, color: .green)
                .help("包括可回收部分的估算值")
            MemoryMetric(title: "系统保留", bytes: system?.wiredBytes, color: .purple)
                .help("macOS 及驱动保留、不能换出的内存；已包含在使用量中")
            MemoryMetric(title: "已压缩", bytes: system?.compressedBytes, color: .orange)
                .help("压缩后实际占用的内存；已包含在使用量中")
            MemoryMetric(title: "磁盘交换", bytes: system?.swapUsedBytes, color: .cyan)
                .help("暂存在磁盘上的内存内容，不属于物理内存组成")
        }
    }
}

private struct MemoryMetric: View {
    let title: String
    let bytes: UInt64?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(bytes.map(SimpleMonitorPresentation.memory) ?? "--")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(accent: color)
    }
}

struct MemoryTrend: View {
    let records: [MemoryHistoryRecord]
    let hours: Int
    let now: Date
    var compact = false
    var sparkline = false
    @State private var points: [MemoryHistoryRecord] = []
    @State private var segments: [Date: Int] = [:]
    @State private var isolatedPoints = Set<Date>()
    @State private var selectedDate: Date?

    var body: some View {
        Group {
            if points.isEmpty {
                ContentUnavailableView("还没有历史记录", systemImage: "chart.xyaxis.line")
            } else {
                Chart {
                    ForEach(points) { record in
                        AreaMark(x: .value("时间", record.timestamp), yStart: .value("基线", 0),
                                 yEnd: .value("使用率", record.usedFraction * 100),
                                 series: .value("连续记录", segments[record.timestamp] ?? 0))
                            .foregroundStyle(LinearGradient(colors: [.cyan.opacity(0.22), .cyan.opacity(0.01)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", record.timestamp), y: .value("使用率", record.usedFraction * 100),
                                 series: .value("连续记录", segments[record.timestamp] ?? 0))
                            .foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth: 2))
                        if isolatedPoints.contains(record.timestamp) {
                            PointMark(x: .value("时间", record.timestamp), y: .value("使用率", record.usedFraction * 100))
                                .foregroundStyle(.cyan)
                        }
                    }
                    if let selectedDate, let nearest = points.min(by: {
                        abs($0.timestamp.timeIntervalSince(selectedDate)) < abs($1.timestamp.timeIntervalSince(selectedDate))
                    }) {
                        RuleMark(x: .value("时间", nearest.timestamp)).foregroundStyle(.secondary.opacity(0.4))
                            .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                Text("\(nearest.timestamp.formatted(date: .omitted, time: .shortened)) · \(Int(nearest.usedFraction * 100))%")
                                    .font(.caption).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            }
                    }
                }
                .chartXScale(domain: now.addingTimeInterval(-Double(hours) * 3600)...now)
                .chartYScale(domain: 0...100)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: compact ? 3 : 5)) {
                    AxisValueLabel(format: .dateTime.hour().minute())
                } }
                .chartYAxis {
                    AxisMarks(position: .leading, values: compact ? [0, 50, 100] : [0, 25, 50, 75, 100]) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel { if let number = value.as(Int.self) { Text("\(number)%") } }
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartXAxis(sparkline ? .hidden : .automatic)
                .chartYAxis(sparkline ? .hidden : .automatic)
            }
        }
        .onChange(of: records, initial: true) { rebuild() }
        .onChange(of: hours) { rebuild() }
        .onChange(of: now) { rebuild() }
    }

    private func rebuild() {
        points = DesktopPresentation.chartRecords(records, hours: hours, now: now)
        segments = DesktopPresentation.chartSegments(records, hours: hours, now: now)
        let counts = Dictionary(grouping: points, by: { segments[$0.timestamp] ?? 0 }).mapValues(\.count)
        isolatedPoints = Set(points.filter { counts[segments[$0.timestamp] ?? 0] == 1 }.map(\.timestamp))
    }
}

struct ProcessAppIcon: View {
    let process: ProcessSnapshot
    var body: some View {
        Image(nsImage: ProcessIconCache.shared.icon(for: process))
            .resizable().scaledToFit().frame(width: 27, height: 27)
            .accessibilityHidden(true)
    }
}

struct DesktopProcesses: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var navigation: DesktopNavigation
    @State private var query = ""
    @State private var includesSystem = false
    @State private var sort: DesktopProcessSort = .memory
    @State private var rows: [DesktopProcessGroup] = []
    @State private var expanded = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Picker("排序", selection: $sort) {
                    ForEach(DesktopProcessSort.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                Spacer(minLength: 0)
                TextField("搜索应用或进程…", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .accessibilityIdentifier("desktop-process-search")
            }
            if let notice = SimpleMonitorPresentation.listNotice(status: model.detailDataStatus(
                retainedItemCount: model.processes.count, targetPresent: !model.processes.isEmpty
            )) {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("应用 / 进程").frame(maxWidth: .infinity, alignment: .leading)
                Text("内存").frame(width: 86, alignment: .trailing)
                Text("CPU").frame(width: 64, alignment: .trailing)
                    .help("两次采样间的 CPU 占用；一个核心满载为 100%")
                Text("操作").frame(width: 32)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { group in
                        Button {
                            if group.members.count == 1 { navigation.selectedProcess = group.members.first?.identity }
                            else if expanded.contains(group.id) { expanded.remove(group.id) }
                            else { expanded.insert(group.id) }
                        } label: {
                            groupRow(group)
                        }.buttonStyle(.plain).monitorRowHover(selected: expanded.contains(group.id))
                        if expanded.contains(group.id) {
                            ForEach(group.members) { process in
                                Button { navigation.selectedProcess = process.identity } label: {
                                    processRow(process).padding(.leading, 20)
                                }.buttonStyle(.plain).monitorRowHover()
                            }
                        }
                    }
                    if rows.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "没有可显示的进程" : "没有搜索结果",
                                               systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                }
            }
            .accessibilityIdentifier("desktop-process-list")
            Divider()
            HStack {
                Text("\(rows.count) 组 · \(rows.reduce(0) { $0 + $1.members.count }) 个进程")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("显示系统进程", isOn: $includesSystem).toggleStyle(.checkbox).font(.caption)
            }
        }
        .padding(28)
        .onChange(of: model.processes, initial: true) { rebuild() }
        .onChange(of: model.groups) { rebuild() }
        .onChange(of: model.processCPUPercent) { rebuild() }
        .onChange(of: query) { rebuild() }
        .onChange(of: sort) { rebuild() }
        .onChange(of: includesSystem) { rebuild() }
    }

    private func groupRow(_ group: DesktopProcessGroup) -> some View {
        HStack(spacing: 8) {
            if let process = group.members.first { ProcessAppIcon(process: process) }
            VStack(alignment: .leading, spacing: 4) {
                Text(group.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(group.members.count > 1 ? "\(group.members.count) 个进程" : "PID \(group.members.first?.identity.pid ?? 0)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text((group.estimated ? "≈ " : "") + SimpleMonitorPresentation.memory(group.bytes))
                .frame(width: 86, alignment: .trailing).help("各成员内存占用之和，可能含共享部分")
            Text(group.cpu(model.processCPUPercent).map { String(format: "%.1f%%", $0) } ?? "--")
                .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Image(systemName: group.members.count == 1 ? "ellipsis.circle" : expanded.contains(group.id) ? "chevron.down" : "chevron.right")
                .foregroundStyle(.secondary).frame(width: 32)
        }.font(.system(size: 13)).monospacedDigit().padding(.horizontal, 10)
            .frame(height: 62).contentShape(Rectangle())
    }

    private func processRow(_ process: ProcessSnapshot) -> some View {
        HStack(spacing: 8) {
            ProcessAppIcon(process: process)
            VStack(alignment: .leading, spacing: 3) {
                Text(process.applicationName ?? process.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                Text("\(process.name) · PID \(process.identity.pid)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text((process.physicalFootprintIsEstimated ? "≈ " : "") + SimpleMonitorPresentation.memory(process.physicalFootprintBytes))
                .frame(width: 86, alignment: .trailing)
            Text(model.processCPUPercent[process.identity].map { String(format: "%.1f%%", $0) } ?? "--")
                .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Image(systemName: "ellipsis.circle").font(.system(size: 19)).foregroundStyle(.secondary)
                .frame(width: 32).help("进程详情与操作")
        }
        .font(.system(size: 12)).monospacedDigit()
        .padding(.horizontal, 10).frame(height: 53).contentShape(Rectangle())
    }

    private func rebuild() {
        rows = DesktopPresentation.groupedProcesses(model.groups, processes: model.processes, query: query,
            includeSystem: includesSystem, sort: sort, cpu: model.processCPUPercent)
    }
}

struct DesktopHistory: View {
    @ObservedObject var model: MonitorViewModel
    @State private var hours = 1
    @State private var initializedRange = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Picker("时间范围", selection: $hours) {
                    Text("1 小时").tag(1)
                    Text("6 小时").tag(6)
                    Text("24 小时").tag(24)
                }.pickerStyle(.segmented).labelsHidden()
                MemoryTrend(records: model.history, hours: hours, now: model.updatedAt ?? Date())
                    .frame(height: 245)
                HStack {
                    Label("内存使用率", systemImage: "circle.fill").foregroundStyle(.cyan)
                    Spacer()
                    Text("\(model.history.count) 条记录").foregroundStyle(.secondary)
                }.font(.caption)
                Divider()
                Text("当前内存").font(.headline)
                MemoryMetrics(system: model.systemDataIsUsable ? model.system : nil)
                if model.historyError != nil {
                    Label("历史记录暂时无法保存", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(28)
        }
        .onChange(of: model.history, initial: true) {
            guard !initializedRange, !model.history.isEmpty else { return }
            hours = DesktopPresentation.initialHistoryHours(model.history, now: model.updatedAt ?? Date())
            initializedRange = true
        }
    }
}

struct DesktopTestInstrument: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var test: MemoryTestController
    @State private var intensity: MemoryTestIntensity = .light

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 28) {
                    ZStack {
                        Circle().stroke(.cyan.opacity(0.12), lineWidth: 8)
                        Circle().trim(from: 0, to: Double(test.elapsed) / 30)
                            .stroke(.cyan, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "cpu").font(.system(size: 70, weight: .ultraLight)).foregroundStyle(.cyan)
                    }.padding(10).frame(width: 174, height: 174)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(test.isRunning ? "测试进行中" : "30 秒内存测试").font(.title2.weight(.semibold))
                        Text(test.isRunning ? "已分配 " + SimpleMonitorPresentation.memory(UInt64(test.allocatedBytes)) : "测试分配量")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Text(test.isRunning ? "\(test.elapsed) / 30 秒" : "\(intensity.rawValue) MB")
                            .font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                    }
                }
                Text("测试强度").font(.headline)
                Picker("测试强度", selection: $intensity) {
                    ForEach(MemoryTestIntensity.allCases) { Text("\($0.title) · \($0.rawValue) MB").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().disabled(test.isRunning)
                HStack {
                    Label("自动释放", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Label("压力过高时自动停止", systemImage: "shield.checkered").foregroundStyle(.secondary)
                }.font(.subheadline)
                if let message = test.message {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                }
                if !test.isRunning, let refusal = MemoryTestPolicy.refusal(
                    system: model.system, usable: model.systemDataIsUsable,
                    pressure: model.pressureLevel, requested: intensity.bytes
                ) {
                    Label(refusal, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                }
                HStack {
                    if test.isRunning {
                        Button("停止测试", systemImage: "stop.fill") { test.stop() }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    } else {
                        Button("开始测试", systemImage: "play.fill") {
                            test.start(system: model.system, usable: model.systemDataIsUsable,
                                       pressure: model.pressureLevel, intensity: intensity)
                        }
                        .buttonStyle(MonitorPrimaryButtonStyle())
                        .disabled(MemoryTestPolicy.refusal(system: model.system, usable: model.systemDataIsUsable,
                                                          pressure: model.pressureLevel, requested: intensity.bytes) != nil)
                    }
                    Spacer()
                }.controlSize(.large)
            }.padding(28)
        }
    }
}

struct DesktopPreferences: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var login: LoginLaunchCoordinator
    @ObservedObject var navigation: DesktopNavigation
    @AppStorage("desktopAppearance") private var appearance = "dark"
    @AppStorage("menuBarShowsPercentage") private var showsPercentage = true
    @State private var showsDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("通用").font(.headline)
                Toggle(isOn: Binding(get: { login.toggleValue }, set: { login.setEnabled($0) })) {
                    HStack { Text("登录时启动"); Spacer() }
                }
                    .toggleStyle(.switch).disabled(login.isUpdating)
                Text(login.status.detail).font(.caption).foregroundStyle(.secondary)
                if let error = login.lastError { Text(error).font(.caption).foregroundStyle(.orange) }
                Divider()
                Toggle(isOn: $showsPercentage) {
                    HStack { Text("菜单栏显示内存使用率"); Spacer() }
                }
                    .toggleStyle(.switch).accessibilityIdentifier("desktop-settings-percentage")
                HStack {
                    Text("外观")
                    Spacer()
                    HStack(spacing: 12) {
                        appearancePreview("dark", title: "深色")
                        appearancePreview("light", title: "浅色")
                    }
                }
                Divider()
                HStack {
                    Text("操作记录")
                    Spacer()
                    Button("查看记录", systemImage: "clock.arrow.circlepath") { navigation.showsAudit = true }
                }
                DisclosureGroup("运行诊断", isExpanded: $showsDiagnostics) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.healthSnapshot.items) { item in
                            HStack(alignment: .top) {
                                Text(item.title).frame(width: 90, alignment: .leading)
                                Text(item.status).foregroundStyle(.secondary)
                                Spacer()
                            }.font(.caption)
                        }
                        Button("重新检查", systemImage: "arrow.clockwise") { model.refreshHealth() }
                    }.padding(.top, 16)
                }
                Divider()
                HStack(alignment: .top) {
                    Image(systemName: "memorychip").font(.title).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Memory Monitor").font(.headline)
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }.font(.system(size: 14)).frame(maxWidth: 620, alignment: .leading)
                .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { login.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refreshStatus()
        }
    }

    private func appearancePreview(_ value: String, title: String) -> some View {
        Button { appearance = value } label: {
            VStack(spacing: 7) {
                HStack(spacing: 0) {
                    Rectangle().fill(value == "dark" ? Color(white: 0.14) : Color(white: 0.86)).frame(width: 25)
                    ZStack {
                        Rectangle().fill(value == "dark" ? Color(white: 0.23) : .white)
                        Image(systemName: "memorychip").foregroundStyle(.cyan).font(.system(size: 22))
                    }
                }.frame(width: 100, height: 58).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(appearance == value ? .blue : .gray.opacity(0.2), lineWidth: 2) }
                HStack(spacing: 4) {
                    Image(systemName: appearance == value ? "checkmark.circle.fill" : "circle").foregroundStyle(appearance == value ? .blue : .secondary)
                    Text(title)
                }.font(.system(size: 12))
            }
        }.buttonStyle(.plain).accessibilityLabel(title + "外观")
            .accessibilityIdentifier("desktop-appearance-" + value)
    }
}
