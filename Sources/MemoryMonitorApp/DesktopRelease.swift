import AppKit
import MemoryMonitorCore
import SwiftUI

struct DesktopRelease: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var cleanup: SmartCleanupController
    @ObservedObject var navigation: DesktopNavigation
    @State private var showsApplications = false
    @State private var showsResults = false
    @State private var preview: CleanupPreview?
    @State private var previewRequest: UUID?
    @State private var previewNotice: String?
    @AppStorage("desktopMotionEnabled") private var motionEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Label("当前工作优先", systemImage: "shield.lefthalf.filled").foregroundStyle(.secondary)
                    Spacer()
                    Button { showsApplications = true } label: {
                        Label("清理名单 · \(cleanup.authorizations.count)", systemImage: "slider.horizontal.3")
                    }.buttonStyle(.borderless).accessibilityIdentifier("cleanup-applications")
                }.font(.caption)
                instrument
                VStack(spacing: 6) {
                    Text(title).font(.title2.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).frame(minHeight: 18)
                }.frame(maxWidth: .infinity)
                HStack(spacing: 16) {
                    if cleanup.isBusy {
                        Button { cleanup.cancel() } label: { Label("停止", systemImage: "stop.fill") }
                            .buttonStyle(MonitorPrimaryButtonStyle()).accessibilityIdentifier("cleanup-stop")
                        if cleanup.phase == .waiting {
                            Button { cleanup.skipCurrent() } label: { Label("跳过", systemImage: "forward.end.fill") }
                                .buttonStyle(.borderless).accessibilityIdentifier("cleanup-skip")
                        }
                    } else {
                        Button {
                            if cleanup.authorizations.isEmpty {
                                showsApplications = true
                            } else {
                                previewNotice = nil
                                previewRequest = UUID()
                            }
                        } label: { Label("检查可退出应用", systemImage: "sparkles") }
                            .buttonStyle(MonitorPrimaryButtonStyle()).disabled(!cleanup.canStart || cleanup.isRefreshing)
                            .accessibilityIdentifier("cleanup-start")
                    }
                }.frame(height: 42)
                if cleanup.authorizations.isEmpty {
                    Text("先在清理名单中选择允许退出的应用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let reason = cleanup.startAvailability.reason, !cleanup.canStart {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let previewNotice {
                    Text(previewNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                if let notice = cleanup.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if let result = cleanup.result {
                    Text(changeDescription(result)).font(.subheadline.weight(.medium))
                        .foregroundStyle(result.hasMeasuredBenefit ? Color.green : .secondary)
                        .multilineTextAlignment(.center)
                }
                Divider().padding(.top, 4)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自动保护").font(.caption.weight(.medium))
                        Text("前台、近期使用与检测到忙碌的应用").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { navigation.page = .processes } label: {
                        Label("查看应用占用", systemImage: "list.bullet.rectangle")
                    }.buttonStyle(.borderless).font(.caption)
                }
                if !cleanup.entries.isEmpty {
                    DisclosureGroup("本次记录 · \(cleanup.entries.count)", isExpanded: $showsResults) {
                        VStack(spacing: 0) {
                            ForEach(cleanup.entries) { entry in
                                HStack(spacing: 10) {
                                    Image(systemName: entry.outcome == .exited ? "checkmark.circle.fill" : "minus.circle")
                                        .foregroundStyle(entry.outcome == .exited ? Color.green : .secondary)
                                    Text(entry.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(entry.detail).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                                }.font(.caption).padding(.vertical, 9)
                            }
                        }.padding(.top, 8)
                    }.font(.caption)
                }
            }.padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showsApplications) { CleanupApplicationsSheet(cleanup: cleanup) }
        .sheet(item: $preview) { frozen in
            CleanupPreviewSheet(
                preview: frozen,
                now: { cleanup.currentTime },
                onConfirm: { selected in
                    cleanup.start(preview: selected)
                },
                onCancel: {},
                onRecheck: { previewRequest = UUID() }
            )
        }
        .onChange(of: cleanup.phase) { if cleanup.phase == .scanning { showsResults = false } }
        .task(id: previewRequest) {
            guard previewRequest != nil else { return }
            cleanup.refreshApplications()
            await cleanup.waitUntilRefreshed()
            guard !Task.isCancelled else { return }
            if let frozen = cleanup.makePreview() {
                preview = frozen
                previewNotice = nil
            } else if let metrics = cleanup.inventory.metrics, !metrics.complete {
                previewNotice = "本次检查未完成，无法确定可退出对象；请重新检查。"
            } else if cleanup.confirmationApplications.isEmpty {
                previewNotice = "本次检查完成，但没有同时满足条件的应用；可查看清理名单或稍后重试。"
            } else {
                previewNotice = "检查未完成，请稍后重试。"
            }
            previewRequest = nil
        }
    }

    private var instrument: some View {
        ZStack {
            CleanupParticles(phase: cleanup.phase,
                tier: .resolve(enabled: motionEnabled && model.systemDataIsUsable && !showsApplications,
                               reduceMotion: reduceMotion, pressure: model.pressureLevel),
                pulse: cleanup.completionPulse, measuredBenefit: cleanup.result?.hasMeasuredBenefit == true)
                .allowsHitTesting(false).accessibilityHidden(true)
            ZStack {
            Circle().stroke(.primary.opacity(0.05), lineWidth: 16).padding(25)
            Circle().stroke(.cyan.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [2, 8])).padding(9)
            Circle().trim(from: 0, to: progress).stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(25)
            VStack(spacing: 9) {
                MemoryMonitorMark().fill(.cyan).frame(width: 56, height: 56)
                Text(model.systemDataIsUsable ? model.system.map { SimpleMonitorPresentation.memory($0.availableEstimateBytes) } ?? "--" : "--")
                    .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                Text("可用内存").font(.caption2).foregroundStyle(.secondary)
            }
            }.frame(width: 224, height: 224)
        }.frame(maxWidth: .infinity).frame(height: 224).accessibilityElement(children: .combine)
    }

    private var progress: CGFloat {
        guard model.systemDataIsUsable else { return 0 }
        return CGFloat(model.system?.availableFraction ?? 0)
    }

    private var title: String {
        switch cleanup.phase {
        case .idle: "准备释放内存"
        case .scanning: "正在检查可清理应用"
        case .quitting: "正在请求退出"
        case .waiting: "等待应用退出"
        case .measuring: "正在核验内存变化"
        case .finished: cleanup.result?.title ?? "检查已结束"
        }
    }

    private var detail: String {
        switch cleanup.phase {
        case .idle: return "仅正常退出清理名单中符合条件的应用"
        case .scanning: return "检查内存、应用活动与保护名单"
        case .quitting, .waiting: return "\(cleanup.currentName ?? "应用") · \(cleanup.completedCount)/\(cleanup.plannedCount)"
        case .measuring: return "正在读取清理后的可用内存"
        case .finished:
            if cleanup.result?.cancelled == true { return "已发出的退出请求仍可能生效" }
            if cleanup.result?.exitedCount == 0 { return "没有合适的应用，或应用尚未退出" }
            return "已保留当前使用和需要保护的应用"
        }
    }

    private func changeDescription(_ result: CleanupResult) -> String {
        guard let change = result.observedChangeBytes else { return result.cancelled ? "本次未完成内存核验" : "暂时无法核验内存变化" }
        if abs(change) < 16 * 1024 * 1024 { return "可用内存暂无明显变化" }
        let amount = SimpleMonitorPresentation.memory(UInt64(abs(change)))
        return "可用内存较操作前\(change > 0 ? "增加" : "减少")约 \(amount)"
    }
}

private enum CleanupAuthorizationTab: String, CaseIterable, Identifiable {
    case authorized
    case addable

    var id: String { rawValue }
    var title: String { self == .authorized ? "已授权" : "可添加" }
}

struct CleanupApplicationsSheet: View {
    @ObservedObject var cleanup: SmartCleanupController
    @Environment(\.dismiss) private var dismiss
    @State private var tab: CleanupAuthorizationTab = .authorized
    @State private var query = ""

    private var authorizedEntries: [CleanupAuthorizationEntry] {
        let entries = cleanup.authorizationEntries
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.authorization.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    private var addableApplications: [CleanupObservation] {
        let apps = cleanup.applications.filter { !cleanup.isAuthorized($0.application) }
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.application.name.localizedCaseInsensitiveContains(query)
                || $0.application.authorization.bundleIdentifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("清理名单").font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("关闭").accessibilityLabel("关闭清理名单")
            }
            Text("已授权名单独立于当前运行应用。仅勾选可以随时退出的应用；清理会请求正常退出，可能询问是否保存。未运行条目可以单独撤销，不会自动启动应用。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let counts = cleanup.authorizationCounts
            Text("已授权 \(counts.total) · 本次运行匹配 \(counts.runningMatched) · 本次符合条件 \(counts.eligible)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("cleanup-authorization-counts")

            Picker("名单", selection: $tab) {
                ForEach(CleanupAuthorizationTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("cleanup-authorization-tab")

            HStack {
                TextField("搜索名称或 bundle 标识", text: $query)
                    .textFieldStyle(.roundedBorder)
                if !query.isEmpty {
                    Button("清除搜索", systemImage: "xmark.circle") { query = "" }
                        .buttonStyle(.borderless)
                }
                Button { cleanup.refreshApplications() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新应用")
                .disabled(cleanup.isRefreshing || cleanup.isBusy)
            }
            if cleanup.isRefreshing {
                Text("正在刷新；当前列表仍是上次读取结果")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if tab == .authorized {
                        if authorizedEntries.isEmpty {
                            emptyState(
                                title: cleanup.authorizations.isEmpty ? "还没有已授权应用" : "没有匹配的已授权应用",
                                detail: cleanup.authorizations.isEmpty
                                    ? "在“可添加”中选择应用，授权只影响之后明确确认的清理。"
                                    : "尝试清除搜索或切换到“可添加”。"
                            )
                        } else {
                            ForEach(authorizedEntries) { entry in
                                authorizedRow(entry)
                                Divider()
                            }
                        }
                    } else if addableApplications.isEmpty {
                        emptyState(
                            title: cleanup.applications.isEmpty
                                ? (cleanup.isRefreshing ? "正在读取应用…" : "没有可添加的应用")
                                : "没有匹配的可添加应用",
                            detail: cleanup.applications.isEmpty
                                ? "应用读取完成后会显示在这里；系统保护对象不会出现。"
                                : "尝试清除搜索；已授权应用请在“已授权”中管理。"
                        )
                    } else {
                        ForEach(addableApplications) { observation in
                            addableRow(observation)
                            Divider()
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: .infinity)

            if let summary = cleanup.inventory.skippedSummary {
                Text("另有 \(cleanup.inventory.skippedCount) 个应用无法评估：\(summary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let metrics = cleanup.inventory.metrics {
                DisclosureGroup("技术详情") {
                    let budget = metrics.budgetExhausted ? " · 预算耗尽" : ""
                    let completeness = metrics.complete ? "" : " · 结果不完整"
                    let cancellation = metrics.cancellationLatencyMilliseconds.map {
                        " · 取消延迟 \(Int($0)) ms"
                    } ?? ""
                    Text("扫描 \(metrics.scanCount) 次 · \(metrics.memberCount) 个成员 · \(Int(metrics.durationMilliseconds)) ms\(cancellation)\(budget)\(completeness)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption2)
                .accessibilityIdentifier("cleanup-technical-details")
            }
            HStack {
                Button("全部取消授权") { cleanup.revokeAll() }.buttonStyle(.borderless)
                    .disabled(cleanup.authorizations.isEmpty)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 540, height: 500)
            .task { cleanup.refreshApplications() }
    }

    @ViewBuilder
    private func authorizedRow(_ entry: CleanupAuthorizationEntry) -> some View {
        HStack(spacing: 10) {
            if let observation = entry.observation {
                ProcessAppIcon(process: observation.application.process)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 27, height: 27)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName).font(.subheadline).lineLimit(1)
                Text(entry.detail)
                    .font(.caption2)
                    .foregroundStyle(entry.state == .identityChanged ? .orange : .secondary)
            }
            Spacer()
            Button("撤销", role: .destructive) {
                cleanup.revoke(entry.authorization)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("撤销 \(entry.displayName)")
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func addableRow(_ observation: CleanupObservation) -> some View {
        let app = observation.application
        Toggle(isOn: Binding(get: { cleanup.isAuthorized(app) }, set: { cleanup.setAuthorized(app, $0) })) {
            HStack(spacing: 10) {
                ProcessAppIcon(process: app.process)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.subheadline).lineLimit(1)
                    Text(observation.protection ?? "允许后可正常退出")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(SimpleMonitorPresentation.memory(app.process.physicalFootprintBytes))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }.toggleStyle(.checkbox).padding(.vertical, 9).disabled(cleanup.isBusy)
            .accessibilityIdentifier("cleanup-allow-\(app.authorization.bundleIdentifier)")
    }

    private func emptyState(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}
