import AppKit
import MemoryMonitorCore
import SwiftUI

struct DesktopShell: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var navigation: DesktopNavigation
    @ObservedObject var memoryTest: MemoryTestController
    @AppStorage("desktopAppearance") private var appearance = "dark"
    @AppStorage("desktopMotionEnabled") private var motionEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = NSRunningApplication.current.isActive

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pageTitle).font(.title2.weight(.semibold))
                        Text(pageSubtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if memoryTest.isRunning {
                        Label("测试中", systemImage: "cpu").font(.caption).foregroundStyle(.orange)
                    }
                    Label(model.pressure.title, systemImage: "circle.fill")
                        .font(.subheadline.weight(.medium)).foregroundStyle(model.pressure.color)
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
                    case .cleanup: DesktopRelease(model: model, cleanup: model.smartCleanup, navigation: navigation)
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
        .environment(\.monitorMotionAllowed, motionEnabled && !reduceMotion && appActive &&
                     model.systemDataIsUsable && model.pressureLevel == .normal &&
                     navigation.selectedProcess == nil && !navigation.showsAudit)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in appActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in appActive = false }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                MemoryMonitorMark().fill(.cyan).frame(width: 28, height: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory Monitor").font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text("Mac 内存管理").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.top, 24).padding(.bottom, 22)
            ForEach(DesktopPage.allCases) { page in
                Button {
                    navigation.page = page
                } label: {
                    Label(page.title, systemImage: page.symbol)
                        .font(.callout.weight(navigation.page == page ? .semibold : .regular))
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
        let decision = MonitorStatusProjection.overview(
            usable: model.systemDataIsUsable,
            level: model.pressureLevel,
            sampleAt: model.updatedAt
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: decision.status.tone == .normal ? "checkmark.circle.fill" : "info.circle.fill")
                            .foregroundStyle(monitorStatusColor(decision.status.tone))
                        Text(decision.status.title)
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text(decision.sampleTime)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(decision.status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(decision.primaryTitle) {
                            navigate(decision.primaryDestination)
                        }
                        .buttonStyle(MonitorPrimaryButtonStyle())
                        if let title = decision.secondaryTitle,
                           let destination = decision.secondaryDestination {
                            Button(title) { navigate(destination) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(16)
                .glassSurface(accent: monitorStatusColor(decision.status.tone))
                .accessibilityElement(children: .contain)
                HStack(spacing: 30) {
                    MemoryUsageRing(system: model.systemDataIsUsable ? model.system : nil)
                        .frame(width: 216, height: 216)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("最近 1 小时").font(.subheadline.weight(.medium))
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
                HStack {
                    Label("\(model.processes.count) 个进程", systemImage: "square.stack.3d.up")
                    Spacer()
                    Text("内存压力与读数来自同一系统样本")
                }.font(.caption).foregroundStyle(.secondary)
                if let notice = SimpleMonitorPresentation.listNotice(status: model.detailDataStatus(
                    retainedItemCount: model.processes.count, targetPresent: !model.processes.isEmpty
                )) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
    }

    private func navigate(_ destination: MonitorPrimaryDestination) {
        switch destination {
        case .processes:
            navigation.page = .processes
        case .cleanup:
            navigation.page = .cleanup
        case .retry:
            model.refreshHealth()
        }
    }
}

func monitorStatusColor(_ tone: MonitorStatusTone) -> Color {
    switch tone {
    case .normal: return .green
    case .loading: return .secondary
    case .partial: return .orange
    case .attention: return .orange
    case .critical: return .red
    case .unavailable: return .secondary
    }
}

struct MemoryUsageRing: View {
    let system: SystemMemorySnapshot?
    @Environment(\.monitorMotionAllowed) private var motion
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 44

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
                Text("内存使用率").font(.subheadline).foregroundStyle(.secondary)
                Text(system.map { "\(Int($0.usedFraction * 100))%" } ?? "--")
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(system.map {
                    "\(SimpleMonitorPresentation.memory($0.usedEstimateBytes)) / \(SimpleMonitorPresentation.memory($0.totalBytes))"
                } ?? "等待数据")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }.padding(20)
        }
        .padding(16)
        .animation(motion ? .easeOut(duration: 0.22) : nil, value: system?.usedFraction)
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
    @Environment(\.monitorMotionAllowed) private var motion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(bytes.map(SimpleMonitorPresentation.memory) ?? "--")
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                .contentTransition(.numericText()).animation(motion ? .easeOut(duration: 0.2) : nil, value: bytes)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(accent: color)
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
                Text(group.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(group.members.count > 1 ? "\(group.members.count) 个进程" : "PID \(group.members.first?.identity.pid ?? 0)")
                    .font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text((group.estimated ? "≈ " : "") + SimpleMonitorPresentation.memory(group.bytes))
                .frame(width: 86, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8)
                .help("各成员内存占用之和，可能含共享部分")
            Text(group.cpu(model.processCPUPercent).map { String(format: "%.1f%%", $0) } ?? "--")
                .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                .lineLimit(1).minimumScaleFactor(0.8)
            Image(systemName: group.members.count == 1 ? "ellipsis.circle" : expanded.contains(group.id) ? "chevron.down" : "chevron.right")
                .foregroundStyle(.secondary).frame(width: 32)
        }.font(.callout).monospacedDigit().padding(.horizontal, 10)
            .frame(minHeight: 62).contentShape(Rectangle())
    }

    private func processRow(_ process: ProcessSnapshot) -> some View {
        HStack(spacing: 8) {
            ProcessAppIcon(process: process)
            VStack(alignment: .leading, spacing: 3) {
                Text(process.applicationName ?? process.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                Text("\(process.name) · PID \(process.identity.pid)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text((process.physicalFootprintIsEstimated ? "≈ " : "") + SimpleMonitorPresentation.memory(process.physicalFootprintBytes))
                .frame(width: 86, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.8)
            Text(model.processCPUPercent[process.identity].map { String(format: "%.1f%%", $0) } ?? "--")
                .foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                .lineLimit(1).minimumScaleFactor(0.8)
            Image(systemName: "ellipsis.circle").font(.system(size: 19)).foregroundStyle(.secondary)
                .frame(width: 32).help("进程详情与操作")
        }
        .font(.callout).monospacedDigit()
        .padding(.horizontal, 10).frame(minHeight: 53).contentShape(Rectangle())
    }

    private func rebuild() {
        rows = DesktopPresentation.groupedProcesses(model.groups, processes: model.processes, query: query,
            includeSystem: includesSystem, sort: sort, cpu: model.processCPUPercent)
    }
}

struct DesktopTestInstrument: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var test: MemoryTestController
    @State private var intensity: MemoryTestIntensity = .light
    @Environment(\.monitorMotionAllowed) private var motion

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
                        .overlay { MonitorParticles(mode: .running, running: test.isRunning).allowsHitTesting(false).accessibilityHidden(true) }
                        .animation(motion ? .easeOut(duration: 0.22) : nil, value: test.elapsed)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(test.isRunning ? "测试进行中" : "30 秒内存测试").font(.title2.weight(.semibold))
                        Text(test.isRunning ? "已分配 " + SimpleMonitorPresentation.memory(UInt64(test.allocatedBytes)) : "测试分配量")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(test.isRunning ? "\(test.elapsed) / 30 秒" : "\(intensity.rawValue) MB")
                            .font(.system(.title, design: .rounded, weight: .medium)).monospacedDigit()
                    }
                }
                Text("测试强度").font(.headline)
                Picker("测试强度", selection: $intensity) {
                    ForEach(MemoryTestIntensity.allCases) { Text("\($0.title) · \($0.rawValue) MB").tag($0) }
                }.pickerStyle(.segmented).labelsHidden().disabled(test.isRunning || !test.isEnabled)
                HStack {
                    Label("自动释放", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Label("压力过高时自动停止", systemImage: "shield.checkered").foregroundStyle(.secondary)
                }.font(.subheadline)
                if !test.isEnabled {
                    Label("当前模式不允许运行内存测试。", systemImage: "lock")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("memory-test-disabled")
                }
                if let message = test.message {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                }
                if test.isEnabled, !test.isRunning, let refusal = MemoryTestPolicy.refusal(
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
                        .disabled(!test.isEnabled || MemoryTestPolicy.refusal(
                            system: model.system, usable: model.systemDataIsUsable,
                            pressure: model.pressureLevel, requested: intensity.bytes
                        ) != nil)
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
    @AppStorage("desktopMotionEnabled") private var motionEnabled = true
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
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("打开登录项设置", systemImage: "arrow.up.forward.app") {
                        login.openSystemSettings()
                    }
                    .buttonStyle(.borderless)
                    if login.isUpdating {
                        Button("取消", systemImage: "xmark.circle") {
                            login.cancelUpdate()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("desktop-settings-login-cancel")
                    }
                }.font(.caption)
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
                Toggle(isOn: $motionEnabled) {
                    HStack { Text("界面动效"); Spacer() }
                }.toggleStyle(.switch)
                    .accessibilityIdentifier("desktop-settings-motion")
                HStack {
                    Text("操作记录")
                    Spacer()
                    Button("查看记录", systemImage: "clock.arrow.circlepath") { navigation.showsAudit = true }
                }
                HStack {
                    Text("本地数据与隐私")
                    Spacer()
                    Button("查看说明与诊断", systemImage: "externaldrive.badge.checkmark") {
                        navigation.showsLocalData = true
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("desktop-settings-local-data")
                }
                HStack {
                    Text("系统隐私权限")
                    Spacer()
                    Button("查看系统设置", systemImage: "lock.shield") {
                        openPrivacySettings()
                    }
                    .buttonStyle(.borderless)
                }
                DisclosureGroup("运行诊断", isExpanded: $showsDiagnostics) {
                    VStack(alignment: .leading, spacing: 14) {
                        healthHeader
                        ForEach(health.items) { item in
                            healthRow(item)
                        }
                        Button("重新检查", systemImage: "arrow.clockwise") { model.refreshHealth() }
                    }.padding(.top, 16)
                }
                Divider()
                HStack(alignment: .top) {
                    MemoryMonitorMark().fill(.cyan).frame(width: 30, height: 30).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Memory Monitor").font(.headline)
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }.font(.body).frame(maxWidth: 620, alignment: .leading)
                .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { login.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refreshStatus()
        }
    }

    private var health: MonitorHealthSnapshot { model.healthSnapshot }

    private var healthHeader: some View {
        let snapshot = health
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: snapshot.overall.iconName)
                .foregroundStyle(healthLevelColor(snapshot.overall))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("运行健康").font(.caption.weight(.semibold))
                    Text(snapshot.overall.title)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(healthLevelColor(snapshot.overall))
                    Spacer()
                    Text(snapshot.checkedAt, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("诊断只读取当前状态，不会修改权限或结束进程。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func healthRow(_ item: MonitorHealthItem) -> some View {
        let content = HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.level.iconName)
                .foregroundStyle(healthLevelColor(item.level))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).font(.caption.weight(.medium))
                    Text(item.status)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(healthLevelColor(item.level))
                    Spacer()
                }
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if MonitorStatusProjection.healthRoute(for: item.id) != nil {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        if let route = MonitorStatusProjection.healthRoute(for: item.id) {
            Button {
                navigate(to: route)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityHint("打开对应的状态或诊断区域")
        } else {
            content
        }
    }

    private func navigate(to route: MonitorHealthRoute) {
        switch route {
        case .audit:
            navigation.showsAudit = true
        case .localData:
            navigation.showsLocalData = true
        case .processes:
            navigation.page = .processes
        case .login:
            break
        case .runtime:
            break
        }
    }

    private func appearancePreview(_ value: String, title: String) -> some View {
        Button { appearance = value } label: {
            VStack(spacing: 7) {
                HStack(spacing: 0) {
                    Rectangle().fill(value == "dark" ? Color(white: 0.14) : Color(white: 0.86)).frame(width: 25)
                    ZStack {
                        Rectangle().fill(value == "dark" ? Color(white: 0.23) : .white)
                        MemoryMonitorMark().fill(.cyan).frame(width: 22, height: 22).accessibilityHidden(true)
                    }
                }.frame(width: 100, height: 58).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(appearance == value ? .blue : .gray.opacity(0.2), lineWidth: 2) }
                HStack(spacing: 4) {
                    Image(systemName: appearance == value ? "checkmark.circle.fill" : "circle").foregroundStyle(appearance == value ? .blue : .secondary)
                    Text(title)
                }.font(.caption)
            }
        }.buttonStyle(.plain).accessibilityLabel(title + "外观")
            .accessibilityIdentifier("desktop-appearance-" + value)
    }
}
