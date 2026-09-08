import AppKit
import MemoryMonitorCore
import SwiftUI

struct DesktopRelease: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var cleanup: SmartCleanupController
    @ObservedObject var navigation: DesktopNavigation
    @State private var showsApplications = false
    @State private var showsResults = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Label("当前工作优先", systemImage: "shield.lefthalf.filled").foregroundStyle(.secondary)
                    Spacer()
                    Button { showsApplications = true } label: {
                        Label("清理名单 · \(cleanup.authorizations.count)", systemImage: "slider.horizontal.3")
                    }.buttonStyle(.borderless).accessibilityIdentifier("cleanup-applications")
                }.font(.system(size: 12))
                instrument
                VStack(spacing: 6) {
                    Text(title).font(.system(size: 21, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
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
                            if cleanup.authorizations.isEmpty { showsApplications = true }
                            else { cleanup.start() }
                        } label: { Label("智能释放", systemImage: "sparkles") }
                            .buttonStyle(MonitorPrimaryButtonStyle()).disabled(!cleanup.canStart)
                            .accessibilityIdentifier("cleanup-start")
                    }
                }.frame(height: 42)
                if let notice = cleanup.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if let result = cleanup.result {
                    Text(changeDescription(result)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(result.hasMeasuredBenefit ? Color.green : .secondary)
                        .multilineTextAlignment(.center)
                }
                Divider().padding(.top, 4)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("自动保护").font(.system(size: 12, weight: .medium))
                        Text("前台、近期使用与检测到忙碌的应用").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { navigation.page = .processes } label: {
                        Label("查看应用占用", systemImage: "list.bullet.rectangle")
                    }.buttonStyle(.borderless).font(.system(size: 12))
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
                                }.font(.system(size: 12)).padding(.vertical, 9)
                            }
                        }.padding(.top, 8)
                    }.font(.system(size: 12))
                }
            }.padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showsApplications) { CleanupApplicationsSheet(cleanup: cleanup) }
        .onChange(of: cleanup.phase) { if cleanup.phase == .scanning { showsResults = false } }
    }

    private var instrument: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.05), lineWidth: 16).padding(25)
            Circle().stroke(.cyan.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [2, 8])).padding(9)
            Circle().trim(from: 0, to: progress).stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(25)
            VStack(spacing: 9) {
                MemoryMonitorMark().fill(.cyan).frame(width: 56, height: 56)
                Text(model.systemDataIsUsable ? model.system.map { SimpleMonitorPresentation.memory($0.availableEstimateBytes) } ?? "--" : "--")
                    .font(.system(size: 29, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("可用内存").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(width: 224, height: 224).accessibilityElement(children: .combine)
    }

    private var progress: CGFloat {
        guard cleanup.isBusy, cleanup.plannedCount > 0 else { return 0.72 }
        return CGFloat(cleanup.completedCount) / CGFloat(cleanup.plannedCount)
    }

    private var title: String {
        switch cleanup.phase {
        case .idle: "让内存轻松一点"
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

struct CleanupApplicationsSheet: View {
    @ObservedObject var cleanup: SmartCleanupController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("清理名单").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }
                    .buttonStyle(.borderless).help("关闭").accessibilityLabel("关闭清理名单")
            }
            Text("仅勾选可以随时退出的应用。清理会请求正常退出，可能询问是否保存；正在使用和近期使用的应用会自动跳过。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("搜索应用", text: $query).textFieldStyle(.roundedBorder)
                Button { cleanup.refreshApplications() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新应用").disabled(cleanup.isRefreshing || cleanup.isBusy)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(cleanup.applications.filter { query.isEmpty || $0.application.name.localizedCaseInsensitiveContains(query) }) { observation in
                        let app = observation.application
                        Toggle(isOn: Binding(get: { cleanup.isAuthorized(app) }, set: { cleanup.setAuthorized(app, $0) })) {
                            HStack(spacing: 10) {
                                ProcessAppIcon(process: app.process)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.name).font(.system(size: 13)).lineLimit(1)
                                    Text(observation.protection ?? "允许后可正常退出")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(SimpleMonitorPresentation.memory(app.process.physicalFootprintBytes))
                                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox).padding(.vertical, 10).disabled(cleanup.isBusy)
                            .accessibilityIdentifier("cleanup-allow-\(app.authorization.bundleIdentifier)")
                        Divider()
                    }
                    if cleanup.applications.isEmpty {
                        Text(cleanup.isRefreshing ? "正在读取应用…" : "没有可添加的应用")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 40)
                    }
                }
            }.frame(minHeight: 180, maxHeight: .infinity)
            HStack {
                Button("全部取消授权") { cleanup.revokeAll() }.buttonStyle(.borderless)
                    .disabled(cleanup.authorizations.isEmpty)
                Spacer()
                Text("已允许 \(cleanup.authorizations.count) 个应用").font(.caption).foregroundStyle(.secondary)
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520, height: 480)
            .task { cleanup.refreshApplications() }
    }
}
