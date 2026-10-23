import AppKit
import MemoryMonitorCore
import SwiftUI
import UniformTypeIdentifiers

struct LocalDataPanel: View {
    @StateObject private var diagnostics: LocalDataDiagnosticsController
    @State private var exportMessage: String?

    init(root: URL = MemoryMonitorStoragePaths.currentRootURL) {
        _diagnostics = StateObject(wrappedValue: LocalDataDiagnosticsController(root: root))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地数据与隐私")
                .font(.headline)
            Text("历史样本只保存在这台 Mac，默认保留 24 小时；操作记录保留最近 7 天、最多 200 条。检查只读取状态，不修复、不清空、不上传，也不会结束进程。系统隐私权限与本地数据是两件事。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if diagnostics.hasPendingRecovery {
                Label("检测到未完成的数据恢复事务。相关存储操作已暂停；请保留现场并按恢复说明处理，不要删除标记或副本。", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("检查本地数据", systemImage: "checkmark.shield") {
                    diagnostics.inspect()
                }
                .disabled(diagnostics.isInspecting)
                .accessibilityIdentifier("local-data-inspect")
                if diagnostics.isInspecting {
                    ProgressView().controlSize(.small)
                }
                Button("导出脱敏摘要", systemImage: "square.and.arrow.up") {
                    exportSummary()
                }
                .disabled(diagnostics.report == nil || diagnostics.isInspecting)
                .accessibilityIdentifier("local-data-export")
            }
            .font(.caption)

            if let report = diagnostics.report {
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle(report.status))
                        .font(.caption.weight(.medium))
                    Text("记录 \(report.recordCount) · 分段 \(report.segmentCount) · 待合并 \(report.journalRecordCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !report.issues.isEmpty {
                        Text("检查发现：" + report.issues.map(\.code).joined(separator: "、"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("local-data-result")
            }
            if let error = diagnostics.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let exportMessage {
                Text(exportMessage).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func statusTitle(_ status: HistoryInspectionStatus) -> String {
        switch status {
        case .healthy: return "本地数据正常"
        case .legacy: return "旧版历史仍可读取"
        case .empty: return "还没有本地历史"
        case .busy: return "本地数据正在被使用，请稍后重试"
        case .changedDuringInspection: return "数据正在变化，请重新检查"
        case .permissionDenied: return "没有权限读取本地数据"
        case .missingIndex, .missingSegment: return "历史文件不完整，未自动修复"
        case .checksumMismatch: return "历史校验失败，未自动修复"
        case .tornJournal: return "历史日志有未完成写入，未自动修复"
        case .unsupportedVersion: return "历史版本不受支持"
        case .unsafePath: return "历史路径不安全，未读取"
        case .invalidData, .fileTooLarge: return "历史数据异常，未自动修复"
        }
    }

    private func exportSummary() {
        guard let summary = diagnostics.makeSummary(),
              let data = try? summary.encoded() else {
            exportMessage = "没有可导出的检查结果。"
            return
        }
        let panel = NSSavePanel()
        panel.title = "导出脱敏诊断摘要"
        panel.nameFieldStringValue = "memory-monitor-summary.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try SupportSummaryExporter.write(data, to: url)
            exportMessage = "摘要已导出，仅含版本、平台、状态和计数。"
        } catch SupportSummaryExporter.ExportError.alreadyExists {
            exportMessage = "目标文件已存在，未覆盖。请换一个文件名。"
        } catch {
            exportMessage = "导出失败，未写入目标文件。"
        }
    }
}
