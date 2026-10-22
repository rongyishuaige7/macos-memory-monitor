import AppKit
import MemoryMonitorCore
import SwiftUI

private enum AuditViewMode: String, CaseIterable, Identifiable {
    case operations
    case events

    var id: String { rawValue }
    var title: String {
        switch self {
        case .operations: return "操作"
        case .events: return "事件"
        }
    }
}

struct OperationsAuditPanel: View {
    @ObservedObject var actions: ProcessActionController
    @Environment(\.dismiss) private var dismiss
    @State private var mode: AuditViewMode = .operations
    @State private var filter: AuditEventFilter = .all
    @State private var query = ""
    @State private var isRefreshing = false

    private var projections: [AuditOperationProjection] {
        let all = AuditOperationProjector.project(
            events: actions.recentEvents,
            activeOperationIDs: actions.activeAuditOperationIDs
        )
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.processLabel.localizedCaseInsensitiveContains(query)
                || ($0.applicationName?.localizedCaseInsensitiveContains(query) ?? false)
                || $0.action.displayName.localizedCaseInsensitiveContains(query)
                || $0.state.displayName.localizedCaseInsensitiveContains(query)
        }
    }

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
                    Text("操作记录")
                        .font(.title3.weight(.semibold))
                    Text("最近 7 天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("共 " + String(mode == .operations ? projections.count : events.count) + " 条")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task {
                            isRefreshing = true
                            await actions.refreshAudit()
                            isRefreshing = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("重新读取操作记录")
                    .accessibilityLabel("重新读取操作记录")
                }
            }

            Picker("视图", selection: $mode) {
                ForEach(AuditViewMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if actions.pendingAuditCount > 0 {
                Label(
                    "待写入审计 \(actions.pendingAuditCount) 条" +
                        (actions.auditQueueIsFull ? " · 队列已满，新操作暂停" : ""),
                    systemImage: "tray.and.arrow.down"
                )
                .font(.caption)
                .foregroundStyle(actions.auditQueueIsFull ? .red : .orange)
            }

            TextField("搜索进程、操作或结果", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            if mode == .events {
                Picker("筛选", selection: $filter) {
                    ForEach(AuditEventFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if let error = actions.auditError {
                Label("记录受限：\(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if mode == .operations {
                if projections.isEmpty {
                    ContentUnavailableView(
                        "暂无操作记录",
                        systemImage: "list.bullet.clipboard",
                        description: Text(actions.recentEvents.isEmpty
                            ? "确认进程操作后，操作级结果会显示在这里。"
                            : "尝试清除搜索。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(projections) { projection in
                                AuditOperationRow(projection: projection)
                                if projection.id != projections.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            } else if events.isEmpty {
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
            Image(systemName: event.phase == .terminal && event.outcome == .completed
                ? "checkmark.circle"
                : event.phase == .intent
                    ? "checkmark.seal"
                    : event.phase == .signalSent
                        ? "paperplane.circle"
                        : "exclamationmark.triangle")
                .foregroundStyle(auditEventColor(event))
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.action.displayName)
                        .font(.caption.weight(.medium))
                    Text(event.processLabel)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(event.statusDisplayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(auditEventColor(event))
                }
                Text(event.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 9)
    }
}

private struct AuditOperationRow: View {
    let projection: AuditOperationProjection

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: auditOperationIcon(projection.state))
                .foregroundStyle(auditOperationColor(projection.state))
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(projection.action.displayName)
                        .font(.caption.weight(.medium))
                    Text(projection.applicationName ?? projection.processLabel)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(projection.state.displayName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(auditOperationColor(projection.state))
                }
                Text(operationDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(projection.lastEventAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private var operationDetail: String {
        var parts = ["\(projection.eventCount) 条事件"]
        if projection.isLegacyTerminalOnly {
            parts.append("旧格式终态记录")
        }
        if projection.isIncomplete {
            parts.append("缺少前序事件")
        }
        if projection.hasSignalSent && !projection.hasTerminal {
            parts.append("请求已发出，退出结果未确认")
        } else if projection.hasIntent && !projection.hasSignalSent && !projection.hasTerminal {
            parts.append("已确认，尚未发送请求")
        }
        return parts.joined(separator: " · ")
    }
}

private func auditOperationIcon(_ state: AuditOperationState) -> String {
    switch state {
    case .completed: return "checkmark.circle"
    case .denied, .failed: return "xmark.octagon"
    case .timedOut: return "clock.badge.exclamationmark"
    case .inProgress: return "arrow.triangle.2.circlepath"
    case .incomplete: return "exclamationmark.triangle"
    case .intentRecorded, .requestSentUnconfirmed, .resultUnconfirmed:
        return "questionmark.circle"
    case .cancelled: return "stop.circle"
    }
}

private func auditOperationColor(_ state: AuditOperationState) -> Color {
    switch state {
    case .completed: return .green
    case .denied, .failed: return .red
    case .timedOut: return .orange
    case .inProgress: return .blue
    case .intentRecorded, .requestSentUnconfirmed, .resultUnconfirmed:
        return .orange
    case .incomplete, .cancelled: return .secondary
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

private func auditEventColor(_ event: ProcessActionAuditEvent) -> Color {
    switch event.phase {
    case .intent:
        return .secondary
    case .signalSent:
        return .orange
    case .terminal:
        return auditOutcomeColor(event.outcome)
    }
}

func openPrivacySettings() {
    // The preference pane identifier changed in macOS 13. Try the modern
    // Privacy & Security route first, then retain the legacy URL for older
    // systems. `open` reports whether Launch Services accepted the URL, so a
    // failed modern route does not prevent the fallback from being tried.
    let candidates = [
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity"
    ].compactMap(URL.init(string:))

    for url in candidates where NSWorkspace.shared.open(url) {
        break
    }
}
