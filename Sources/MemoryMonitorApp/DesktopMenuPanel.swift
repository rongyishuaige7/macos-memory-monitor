import MemoryMonitorCore
import SwiftUI

struct DesktopMenuPanel: View {
    @ObservedObject var model: MonitorViewModel
    let openDesktop: (DesktopPage) -> Void
    let openAudit: () -> Void
    let terminationAction: ApplicationTerminationAction
    @AppStorage("desktopAppearance") private var appearance = "dark"

    init(
        model: MonitorViewModel,
        openDesktop: @escaping (DesktopPage) -> Void,
        terminationAction: ApplicationTerminationAction,
        openAudit: (() -> Void)? = nil
    ) {
        self._model = ObservedObject(wrappedValue: model)
        self.openDesktop = openDesktop
        self.terminationAction = terminationAction
        self.openAudit = openAudit ?? { openDesktop(.settings) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("内存使用率").foregroundStyle(.secondary)
                        Spacer()
                        Text(model.systemDataIsUsable ? model.system.map { "\(Int($0.usedFraction * 100))%" } ?? "--" : "--")
                            .fontWeight(.semibold).monospacedDigit()
                    }
                    ProgressView(value: model.systemDataIsUsable ? model.system?.usedFraction ?? 0 : 0).tint(.blue)
                    HStack {
                        Text(model.systemDataIsUsable ? model.system.map {
                            "\(SimpleMonitorPresentation.memory($0.usedEstimateBytes)) / \(SimpleMonitorPresentation.memory($0.totalBytes))"
                        } ?? "--" : "等待数据")
                        Spacer()
                        Text(model.pressure.title).foregroundStyle(model.pressure.color)
                    }.font(.caption).foregroundStyle(.secondary)
                    MemoryTrend(records: model.history, hours: 1, now: model.updatedAt ?? Date(), compact: true, sparkline: true)
                        .frame(height: 64)
                    VStack(spacing: 9) {
                        metric("系统保留", bytes: model.system?.wiredBytes, color: .purple)
                        metric("已压缩", bytes: model.system?.compressedBytes, color: .orange)
                        metric("可用", bytes: model.system?.availableEstimateBytes, color: .green)
                    }
                    Button { openDesktop(.cleanup) } label: {
                        Label("释放内存", systemImage: "sparkles").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }.buttonStyle(MonitorPrimaryButtonStyle())
                    Divider()
                    route("打开主窗口", symbol: "macwindow", page: .overview)
                    route("查看进程", symbol: "list.bullet.rectangle", page: .processes)
                    route("统计", symbol: "chart.xyaxis.line", page: .history)
                    route("内存压力测试", symbol: "cpu", page: .stress)
                    route("设置", symbol: "gearshape", page: .settings)
                    if model.processActions.auditError != nil {
                        Button { openDesktop(.settings) } label: {
                            Label("操作记录暂时不可用", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("直接打开操作记录和待写状态")
                    }
                }
                .padding(18)
            }
            .frame(maxHeight: 430)
            Divider()
            Button { terminationAction() } label: {
                Label("退出", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .font(.callout)
        .frame(width: 290)
        .background(.regularMaterial)
        .environment(\.colorScheme, appearance == "light" ? .light : .dark)
    }

    private func metric(_ title: String, bytes: UInt64?, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(model.systemDataIsUsable ? bytes.map(SimpleMonitorPresentation.memory) ?? "--" : "--").monospacedDigit()
        }
    }

    private func route(_ title: String, symbol: String, page: DesktopPage) -> some View {
        Button { openDesktop(page) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary).monitorRowHover()
        .accessibilityIdentifier("menu-route-" + page.rawValue)
    }
}
