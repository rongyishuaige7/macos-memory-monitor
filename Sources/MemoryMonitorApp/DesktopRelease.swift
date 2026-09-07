import MemoryMonitorCore
import SwiftUI

struct DesktopRelease: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var actions: ProcessActionController
    @ObservedObject var navigation: DesktopNavigation
    @State private var selected: ProcessIdentity?
    @State private var candidates: [ProcessSnapshot] = []
    @State private var query = ""
    @State private var reviewed: ProcessIdentity?
    @State private var result: String?

    private var process: ProcessSnapshot? { candidates.first { $0.identity == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                step("选择", number: 1, active: selected == nil && result == nil)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                step("确认退出", number: 2, active: selected != nil && result == nil)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                step("完成", number: 3, active: result != nil)
                Spacer()
            }.font(.system(size: 12))
            HStack(spacing: 20) {
                Image(systemName: result == nil ? "square.stack.3d.up" : "checkmark.circle")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(result == nil ? .cyan : .green)
                    .frame(width: 74, height: 84)
                VStack(alignment: .leading, spacing: 7) {
                    Text(result == nil ? "选中进程占用" : "进程已退出")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(result == nil ? process.map { SimpleMonitorPresentation.memory($0.physicalFootprintBytes) } ?? "--" : "完成")
                        .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(result == nil ? process.map { $0.applicationName ?? $0.name } ?? "尚未选择" : result ?? "")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("应用与后台进程").font(.system(size: 14, weight: .semibold))
                Spacer()
                TextField("搜索…", text: $query).textFieldStyle(.roundedBorder).frame(width: 160)
            }
            if let notice = SimpleMonitorPresentation.listNotice(status: model.detailDataStatus(
                retainedItemCount: model.processes.count, targetPresent: !model.processes.isEmpty
            )) {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(candidates) { candidate in
                        Button {
                            selected = candidate.identity
                            result = nil
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selected == candidate.identity ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected == candidate.identity ? .blue : .secondary)
                                ProcessAppIcon(process: candidate)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.applicationName ?? candidate.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text("PID \(candidate.identity.pid) · \(candidate.name)")
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text((candidate.physicalFootprintIsEstimated ? "≈ " : "") + SimpleMonitorPresentation.memory(candidate.physicalFootprintBytes))
                                    .font(.system(size: 13)).monospacedDigit()
                            }.padding(.horizontal, 10).frame(height: 56).contentShape(Rectangle())
                        }.buttonStyle(.plain).monitorRowHover(selected: selected == candidate.identity)
                            .accessibilityIdentifier("release-select-\(candidate.identity.pid)")
                    }
                    if candidates.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "没有可退出的进程" : "没有搜索结果", systemImage: "square.stack.3d.up")
                    }
                }
            }.frame(minHeight: 95)
            Divider()
            HStack(spacing: 16) {
                Text("退出前请保存工作\n实际释放量由 macOS 决定")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    guard let process else { return }
                    reviewed = process.identity
                    navigation.selectedProcess = process.identity
                } label: {
                    Label("检查并退出", systemImage: "arrow.up.right.square")
                }.buttonStyle(MonitorPrimaryButtonStyle()).disabled(process == nil || actions.isBusy)
                    .accessibilityIdentifier("release-review")
            }
        }.padding(28)
            .onChange(of: model.processes, initial: true) { rebuild() }
            .onChange(of: query) { rebuild() }
            .onChange(of: actions.state) {
                if case let .completed(identity, _, message) = actions.state, identity == reviewed {
                    result = message
                    selected = nil
                }
            }
    }

    private func step(_ title: String, number: Int, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text("\(number)").font(.system(size: 11, weight: .semibold)).frame(width: 20, height: 20)
                .background(active ? Color.blue.opacity(0.22) : .primary.opacity(0.045), in: Circle())
            Text(title)
        }.foregroundStyle(active ? .primary : .secondary)
    }

    private func rebuild() {
        candidates = DesktopPresentation.processes(model.processes, query: query, includeSystem: false, sort: .memory, cpu: [:])
            .filter { actions.eligibility(for: $0).allowed }
        if let selected, !candidates.contains(where: { $0.identity == selected }) { self.selected = nil }
    }
}
