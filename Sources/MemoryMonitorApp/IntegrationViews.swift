import AppKit
import MemoryMonitorCore
import SwiftUI

struct MonitorHealthPanel: View {
    @ObservedObject var model: MonitorViewModel
    @ObservedObject var loginLaunch: LoginLaunchCoordinator
    @Environment(\.dismiss) private var dismiss

    private var snapshot: MonitorHealthSnapshot { model.healthSnapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                healthRows
                loginControls
                privacyNotice
            }
            .padding(20)
        }
        .frame(minWidth: 500, idealWidth: 560, minHeight: 520, idealHeight: 620)
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

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: snapshot.overall.iconName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(healthLevelColor(snapshot.overall))
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text("运行健康")
                    .font(.title3.weight(.semibold))
                Text(snapshot.overall.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(healthLevelColor(snapshot.overall))
                Text("诊断只读取当前状态，不会修改权限或结束进程。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Button {
                    model.refreshHealth()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新检查")
                Text(snapshot.checkedAt, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var healthRows: some View {
        DetailSection(title: "状态检查") {
            ForEach(snapshot.items) { item in
                HealthCheckRow(item: item)
                if item.id != snapshot.items.last?.id {
                    Divider()
                }
            }
        }
    }

    private var loginControls: some View {
        DetailSection(title: "系统集成") {
            Toggle(isOn: Binding(
                get: { loginLaunch.toggleValue },
                set: { loginLaunch.setEnabled($0) }
            )) {
                Label("登录时启动", systemImage: "power.circle")
            }
            .toggleStyle(.switch)
            .disabled(loginLaunch.isUpdating)

            HStack(spacing: 8) {
                Image(systemName: loginLaunch.status.isRegistered
                    ? "checkmark.circle"
                    : "info.circle")
                    .foregroundStyle(loginLaunch.status.isRegistered ? .green : .secondary)
                Text(loginLaunch.status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
            }

            if let error = loginLaunch.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                loginLaunch.openSystemSettings()
            } label: {
                Label("打开登录项设置", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.bordered)
            .disabled(loginLaunch.isUpdating)
        }
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("进程读取受 macOS 权限和进程自身状态影响；部分可用时仍会保留成功读取的条目。", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openPrivacySettings()
            } label: {
                Label("查看隐私设置", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct HealthCheckRow: View {
    let item: MonitorHealthItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: item.level.iconName)
                .foregroundStyle(healthLevelColor(item.level))
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.caption.weight(.medium))
                    Text(item.status)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(healthLevelColor(item.level))
                }
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
        }
    }
}

struct OperationsAuditPanel: View {
    @ObservedObject var actions: ProcessActionController
    @Environment(\.dismiss) private var dismiss
    @State private var filter: AuditEventFilter = .all
    @State private var query = ""

    private var events: [ProcessActionAuditEvent] {
        AuditEventFiltering.apply(
            events: actions.recentEvents,
            filter: filter,
            query: query
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("操作审计")
                        .font(.title3.weight(.semibold))
                    Text("仅显示本地脱敏记录，最多保留最近 7 天。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("共 " + String(events.count) + " 条")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Picker("筛选", selection: $filter) {
                ForEach(AuditEventFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("搜索进程或记录内容", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if let error = actions.auditError {
                Label("记录受限：\(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if events.isEmpty {
                ContentUnavailableView(
                    "暂无匹配记录",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(actions.recentEvents.isEmpty
                        ? "确认进程操作后，结果会显示在这里。"
                        : "尝试切换筛选条件或清除搜索。")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            AuditEventRow(event: event)
                            if event.id != events.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 580, minHeight: 500, idealHeight: 600)
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
}

private struct AuditEventRow: View {
    let event: ProcessActionAuditEvent

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: event.outcome == .completed
                ? "checkmark.circle"
                : "exclamationmark.triangle")
                .foregroundStyle(auditOutcomeColor(event.outcome))
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.action.displayName)
                        .font(.caption.weight(.medium))
                    Text(event.processLabel)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(event.outcome.displayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(auditOutcomeColor(event.outcome))
                }
                Text(event.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(event.timestamp, style: .date)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 9)
    }
}

func healthLevelColor(_ level: MonitorHealthLevel) -> Color {
    switch level {
    case .healthy: return .green
    case .degraded: return .orange
    case .attention: return .red
    }
}

private func auditOutcomeColor(_ outcome: ProcessActionOutcome) -> Color {
    switch outcome {
    case .completed: return .green
    case .timedOut: return .orange
    case .denied, .failed: return .red
    case .cancelled: return .secondary
    }
}

private func openPrivacySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
        return
    }
    NSWorkspace.shared.open(url)
}
