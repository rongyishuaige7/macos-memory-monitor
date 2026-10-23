import SwiftUI

struct CleanupPreviewSheet: View {
    let now: () -> TimeInterval
    let onConfirm: (CleanupPreview) -> Void
    let onCancel: () -> Void
    let onRecheck: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working: CleanupPreview
    @State private var tick: TimeInterval

    init(
        preview: CleanupPreview,
        now: @escaping () -> TimeInterval,
        onConfirm: @escaping (CleanupPreview) -> Void,
        onCancel: @escaping () -> Void,
        onRecheck: @escaping () -> Void
    ) {
        self.now = now
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.onRecheck = onRecheck
        _working = State(initialValue: preview)
        _tick = State(initialValue: now())
    }

    var body: some View {
        let valid = working.isValid(at: tick)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本次可请求退出 \(working.selectedApplications.count) 个应用")
                        .font(.title3.weight(.semibold))
                    Text("检查完成；预览还剩 \(max(0, Int(working.expiresAt - tick))) 秒有效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { onCancel(); dismiss() } label: {
                    Image(systemName: "xmark").frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("取消本次清理")
            }

            Text("只发送正常退出请求，不会强制结束。应用可能拒绝或询问是否保存；取消勾选后不会从后续候选中补位。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(working.candidates) { app in
                        Toggle(isOn: Binding(
                            get: { working.selectedIDs.contains(app.id) },
                            set: { enabled in
                                if enabled != working.selectedIDs.contains(app.id) {
                                    working = working.toggling(app.id, at: tick)
                                }
                            }
                        )) {
                            HStack(spacing: 9) {
                                ProcessAppIcon(process: app.process)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).lineLimit(1)
                                    Text("已读取占用 \(SimpleMonitorPresentation.memory(app.process.physicalFootprintBytes))（参考，不是预计释放量）")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 8)
                        .disabled(!valid)
                        if app.id != working.candidates.last?.id { Divider() }
                    }
                }
            }
            .frame(minHeight: 160, maxHeight: 300)

            if let summary = working.skippedSummary {
                Text("另有无法评估或自动跳过的应用：\(summary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !valid {
                Label("预览已过期，请重新检查；旧名单不会执行。", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("取消", role: .cancel) { onCancel(); dismiss() }
                Button("重新检查", systemImage: "arrow.clockwise") { onRecheck(); dismiss() }
                Spacer()
                Button("请求正常退出 \(working.selectedApplications.count) 个应用", role: .destructive) {
                    guard valid, !working.selectedApplications.isEmpty else { return }
                    onConfirm(working)
                    dismiss()
                }
                .disabled(!valid || working.selectedApplications.isEmpty)
                .accessibilityIdentifier("cleanup-preview-confirm")
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 480)
        .task {
            while !Task.isCancelled {
                tick = now()
                if !working.isValid(at: tick) { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
