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
                        Text(pageTitle).font(.system(size: 23, weight: .semibold))
                        Text(pageSubtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if memoryTest.isRunning {
                        Label("测试中", systemImage: "cpu").font(.caption).foregroundStyle(.orange)
                    }
                    Label(model.pressure.title, systemImage: "circle.fill")
                        .font(.caption).foregroundStyle(model.pressure.color)
                    Button { model.refreshHealth() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.borderless).help("刷新数据")
                    .accessibilityLabel("刷新数据")
                }
                .padding(.horizontal, 28).padding(.vertical, 24)
                Divider().padding(.horizontal, 28)
                Group {
                    switch navigation.page {
                    case .overview: DesktopOverview(model: model, navigation: navigation)
                    case .processes: DesktopProcesses(model: model, navigation: navigation, cleanup: false)
                    case .cleanup: DesktopProcesses(model: model, navigation: navigation, cleanup: true)
                    case .history: DesktopHistory(model: model)
                    case .stress: DesktopMemoryTest(model: model, test: memoryTest)
                    case .settings: DesktopSettings(model: model, login: model.loginLaunch, navigation: navigation)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
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
                    Text("Memory Monitor").font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text("Mac 内存管理").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 24).padding(.bottom, 22)
            ForEach(DesktopPage.allCases) { page in
                Button {
                    navigation.page = page
                } label: {
                    Label(page.title, systemImage: page.symbol)
                        .font(.system(size: 13, weight: navigation.page == page ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 13).frame(height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(navigation.page == page ? Color.primary : Color.secondary)
                .background(navigation.page == page ? Color.blue.opacity(0.22) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
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
        .frame(width: 178)
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
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 28) {
                    MemoryUsageRing(system: model.systemDataIsUsable ? model.system : nil)
                        .frame(width: 208, height: 208)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("最近 1 小时").font(.subheadline)
                            Spacer()
                            Button { navigation.page = .history } label: {
                                Image(systemName: "arrow.up.right")
                            }.buttonStyle(.borderless).help("查看内存历史")
                        }
                        MemoryTrend(records: model.history, hours: 1, now: model.updatedAt ?? Date(), compact: true)
                            .frame(height: 155)
                    }
                    .frame(maxWidth: .infinity)
                }
                MemoryMetrics(system: model.systemDataIsUsable ? model.system : nil)
                HStack(spacing: 12) {
                    Button {
                        navigation.page = .cleanup
                    } label: {
                        Label("释放内存", systemImage: "sparkles")
                            .frame(minWidth: 140).padding(.vertical, 7)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Button("查看进程", systemImage: "list.bullet.rectangle") { navigation.page = .processes }
                        .buttonStyle(.bordered).controlSize(.large)
                    Spacer()
                }
                Divider()
                HStack {
                    Text("占用最多").font(.headline)
                    Spacer()
                    Text("内存").font(.caption).foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(model.processes.filter { !$0.isSystem && $0.userID != 0 }.prefix(3)) { process in
                        Button {
                            navigation.selectedProcess = process.identity
                        } label: {
                            HStack(spacing: 12) {
                                ProcessAppIcon(process: process)
                                Text(process.applicationName ?? process.name).lineLimit(1)
                                Spacer()
                                Text(SimpleMonitorPresentation.memory(process.physicalFootprintBytes)).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 9).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if model.processes.isEmpty {
                        Text("正在读取进程…").foregroundStyle(.secondary).padding(.vertical, 18)
                    }
                }
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
            Circle().stroke(.blue.opacity(0.15), lineWidth: 15)
            Circle().trim(from: 0, to: system?.usedFraction ?? 0)
                .stroke(AngularGradient(colors: [.cyan, .blue, .indigo], center: .center,
                                        startAngle: .degrees(0), endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: 15, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 9) {
                Text("内存使用率").font(.subheadline).foregroundStyle(.secondary)
                Text(system.map { "\(Int($0.usedFraction * 100))%" } ?? "--")
                    .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(system.map {
                    "\(SimpleMonitorPresentation.memory($0.usedEstimateBytes)) / \(SimpleMonitorPresentation.memory($0.totalBytes))"
                } ?? "等待数据")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(20)
        }
        .padding(9)
        .accessibilityElement(children: .combine)
        .help("使用量为扣除估算可用内存后的值")
    }
}

struct MemoryMetrics: View {
    let system: SystemMemorySnapshot?

    var body: some View {
        HStack(spacing: 10) {
            MemoryMetric(title: "已使用", bytes: system?.usedEstimateBytes, color: .cyan)
            MemoryMetric(title: "系统保留", bytes: system?.wiredBytes, color: .purple)
                .help("macOS 及驱动保留、不能换出的内存；已包含在使用量中")
            MemoryMetric(title: "已压缩", bytes: system?.compressedBytes, color: .orange)
                .help("压缩后实际占用的内存；已包含在使用量中")
            MemoryMetric(title: "可用", bytes: system?.availableEstimateBytes, color: .green)
                .help("包括可回收部分的估算值")
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
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(bytes.map(SimpleMonitorPresentation.memory) ?? "--")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MemoryTrend: View {
    let records: [MemoryHistoryRecord]
    let hours: Int
    let now: Date
    var compact = false
    @State private var points: [MemoryHistoryRecord] = []
    @State private var selectedDate: Date?

    var body: some View {
        Group {
            if points.isEmpty {
                ContentUnavailableView("还没有历史记录", systemImage: "chart.xyaxis.line")
            } else {
                Chart {
                    ForEach(points) { record in
                        AreaMark(x: .value("时间", record.timestamp), yStart: .value("基线", 0),
                                 yEnd: .value("使用率", record.usedFraction * 100))
                            .foregroundStyle(LinearGradient(colors: [.cyan.opacity(0.22), .cyan.opacity(0.01)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("时间", record.timestamp), y: .value("使用率", record.usedFraction * 100))
                            .foregroundStyle(.cyan).lineStyle(StrokeStyle(lineWidth: 2))
                        if points.count == 1 {
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
            }
        }
        .onChange(of: records, initial: true) { rebuild() }
        .onChange(of: hours) { rebuild() }
        .onChange(of: now) { rebuild() }
    }

    private func rebuild() {
        points = DesktopPresentation.chartRecords(records, hours: hours, now: now)
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
    let cleanup: Bool
    @State private var query = ""
    @State private var includesSystem = false
    @State private var sort: DesktopProcessSort = .memory
    @State private var rows: [ProcessSnapshot] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if cleanup {
                HStack(spacing: 16) {
                    Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("选择不再使用的应用").font(.headline)
                        Text("退出前请保存工作。系统会自行回收可用缓存。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("当前可用").font(.caption).foregroundStyle(.secondary)
                        Text(model.systemDataIsUsable ? model.system.map {
                            SimpleMonitorPresentation.memory($0.availableEstimateBytes)
                        } ?? "--" : "--").font(.title2.monospacedDigit())
                    }
                }
                .padding(.bottom, 8)
            }
            HStack(spacing: 16) {
                Picker("排序", selection: $sort) {
                    ForEach(DesktopProcessSort.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                Spacer(minLength: 0)
                TextField("搜索进程…", text: $query)
                    .textFieldStyle(.roundedBorder).frame(width: 180)
                    .accessibilityIdentifier("desktop-process-search")
            }
            if let notice = SimpleMonitorPresentation.listNotice(status: model.detailDataStatus(
                retainedItemCount: model.processes.count, targetPresent: !model.processes.isEmpty
            )) {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("进程名称").frame(maxWidth: .infinity, alignment: .leading)
                Text("内存").frame(width: 86, alignment: .trailing)
                Text("CPU").frame(width: 64, alignment: .trailing)
                    .help("两次采样间的 CPU 占用；一个核心满载为 100%")
                Text("进程号").frame(width: 58, alignment: .trailing)
                Text("操作").frame(width: 32)
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { process in
                        Button { navigation.selectedProcess = process.identity } label: {
                            processRow(process)
                        }.buttonStyle(.plain)
                        Divider().opacity(0.55)
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
                Text("\(rows.count) 个进程").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !cleanup {
                    Toggle("显示系统进程", isOn: $includesSystem).toggleStyle(.checkbox).font(.caption)
                }
            }
        }
        .padding(28)
        .onChange(of: model.processes, initial: true) { rebuild() }
        .onChange(of: model.processCPUPercent) { rebuild() }
        .onChange(of: query) { rebuild() }
        .onChange(of: sort) { rebuild() }
        .onChange(of: includesSystem) { rebuild() }
        .onChange(of: cleanup) { rebuild() }
    }

    private func processRow(_ process: ProcessSnapshot) -> some View {
        HStack(spacing: 8) {
            ProcessAppIcon(process: process)
            VStack(alignment: .leading, spacing: 3) {
                Text(process.applicationName ?? process.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                if process.applicationName != nil && process.applicationName != process.name {
                    Text(process.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text((process.physicalFootprintIsEstimated ? "≈ " : "") + SimpleMonitorPresentation.memory(process.physicalFootprintBytes))
                .frame(width: 86, alignment: .trailing)
            Text(model.processCPUPercent[process.identity].map { String(format: "%.1f%%", $0) } ?? "--")
                .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Text(String(process.identity.pid)).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
            Image(systemName: "ellipsis.circle").font(.system(size: 19)).foregroundStyle(.secondary)
                .frame(width: 32).help(cleanup ? "查看并退出应用" : "进程详情与操作")
        }
        .font(.system(size: 12)).monospacedDigit()
        .padding(.horizontal, 10).frame(height: 53).contentShape(Rectangle())
    }

    private func rebuild() {
        let candidates = cleanup ? model.processes.filter {
            !$0.isSystem && $0.userID != 0 && model.processActions.eligibility(for: $0).allowed
        } : model.processes
        rows = DesktopPresentation.processes(candidates, query: query,
            includeSystem: includesSystem && !cleanup, sort: sort, cpu: model.processCPUPercent)
    }
}

struct DesktopHistory: View {
    @ObservedObject var model: MonitorViewModel
    @State private var hours = 24

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
                HStack {
                    Text("磁盘交换").foregroundStyle(.secondary)
                    Spacer()
                    Text(model.systemDataIsUsable ? model.system.map {
                        SimpleMonitorPresentation.memory($0.swapUsedBytes)
                    } ?? "--" : "--").monospacedDigit()
                }.font(.subheadline)
                if model.historyError != nil {
                    Label("历史记录暂时无法保存", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }.padding(28)
        }
    }
}

struct DesktopMemoryTest: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var test: MemoryTestController
    @State private var intensity: MemoryTestIntensity = .light

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 24) {
                    Image(systemName: "cpu").font(.system(size: 66, weight: .ultraLight)).foregroundStyle(.cyan)
                        .frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(test.isRunning ? "测试进行中" : "30 秒内存测试").font(.title2.weight(.semibold))
                        Text("测试结束或停止后，分配的内存会自动释放。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("测试强度").font(.headline)
                Picker("测试强度", selection: $intensity) {
                    ForEach(MemoryTestIntensity.allCases) { Text("\($0.title) · \($0.rawValue) MB").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().disabled(test.isRunning)
                HStack {
                    Label("自动释放", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Label("压力过高时自动停止", systemImage: "shield.checkered").foregroundStyle(.secondary)
                }.font(.subheadline)
                if test.isRunning {
                    ProgressView(value: Double(test.elapsed), total: 30).tint(.cyan)
                    HStack {
                        Text("已分配 \(SimpleMonitorPresentation.memory(UInt64(test.allocatedBytes)))")
                        Spacer()
                        Text("\(test.elapsed) / 30 秒")
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
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
                        .buttonStyle(.borderedProminent)
                        .disabled(MemoryTestPolicy.refusal(system: model.system, usable: model.systemDataIsUsable,
                                                          pressure: model.pressureLevel, requested: intensity.bytes) != nil)
                    }
                    Spacer()
                }.controlSize(.large)
            }.padding(28)
        }
    }
}

struct DesktopSettings: View {
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
                Divider()
                HStack {
                    Text("外观")
                    Spacer()
                    Picker("外观", selection: $appearance) {
                        Text("深色").tag("dark")
                        Text("浅色").tag("light")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
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
            }.padding(28)
        }
        .onAppear { login.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refreshStatus()
        }
    }
}
