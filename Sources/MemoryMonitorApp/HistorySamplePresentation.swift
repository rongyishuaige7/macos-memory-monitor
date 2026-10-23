import Foundation
import MemoryMonitorCore

enum HistoryWorkloadQuality: Equatable, Sendable {
    case complete
    case partial
    case unknown
    case estimated

    var title: String {
        switch self {
        case .complete: return "当时记录的主要工作组"
        case .partial: return "当时仅有部分工作组数据"
        case .unknown: return "当时未记录足够的进程归因"
        case .estimated: return "当时部分占用使用估算口径"
        }
    }
}

struct HistorySamplePresentation: Equatable, Sendable {
    static let comparisonInterval: TimeInterval = 120

    let record: MemoryHistoryRecord
    let compressedDelta: Int64?
    let swapDelta: Int64?
    let comparisonInterval: TimeInterval?
    let workloadQuality: HistoryWorkloadQuality
    let workloads: [PersistedWorkloadRecord]

    init(record: MemoryHistoryRecord, previous: MemoryHistoryRecord?) {
        self.record = record
        if let previous {
            let interval = record.timestamp.timeIntervalSince(previous.timestamp)
            if interval > 0, interval <= Self.comparisonInterval {
                compressedDelta = Int64(clamping: record.compressedBytes)
                    - Int64(clamping: previous.compressedBytes)
                swapDelta = Int64(clamping: record.swapUsedBytes)
                    - Int64(clamping: previous.swapUsedBytes)
                comparisonInterval = interval
            } else {
                compressedDelta = nil
                swapDelta = nil
                comparisonInterval = nil
            }
        } else {
            compressedDelta = nil
            swapDelta = nil
            comparisonInterval = nil
        }

        if let workloadSample = record.workloadsSampledAt {
            let skew = workloadSample.timeIntervalSince(record.timestamp)
            if !skew.isFinite
                || abs(skew) > HistoryStore.maximumFreshnessMarkerRecordSkew {
                // The attribution belongs to a different wall-clock era; it
                // cannot be presented as the workload ranking at this point.
                workloadQuality = .unknown
            } else if record.workloadInventoryIsComplete == false {
                workloadQuality = .partial
            } else if record.workloadInventoryIsComplete == true {
                workloadQuality = record.workloads.contains { $0.containsEstimatedFootprint }
                    ? .estimated : .complete
            } else {
                workloadQuality = .unknown
            }
        } else {
            workloadQuality = .unknown
        }
        workloads = record.workloads
            .sorted { $0.attributedFootprintBytes > $1.attributedFootprintBytes }
    }

    var topWorkloads: [PersistedWorkloadRecord] { Array(workloads.prefix(3)) }
    var additionalWorkloadCount: Int { max(workloads.count - 3, 0) }
}

extension HistoryTrendData {
    var gapCount: Int {
        guard records.count > 1 else { return 0 }
        return zip(records, records.dropFirst()).filter {
            $1.timestamp.timeIntervalSince($0.timestamp) > 120
        }.count
    }

    var coverageText: String {
        guard let first = records.first?.timestamp, let last = records.last?.timestamp else {
            return "此时段暂无有效记录"
        }
        let formatter = Date.FormatStyle.dateTime.month().day().hour().minute()
        return "\(records.count) 个有效样本 · \(first.formatted(formatter))–\(last.formatted(formatter)) · \(gapCount) 处断档"
    }

    func presentation(for record: MemoryHistoryRecord) -> HistorySamplePresentation {
        let previous = records.last { $0.timestamp < record.timestamp }
        return HistorySamplePresentation(record: record, previous: previous)
    }

    func exactRecord(at timestamp: Date) -> MemoryHistoryRecord? {
        records.first { $0.timestamp == timestamp }
    }

    func adjacentRecord(to timestamp: Date, direction: Int) -> MemoryHistoryRecord? {
        guard let index = records.firstIndex(where: { $0.timestamp == timestamp }) else { return nil }
        let next = index + direction
        guard records.indices.contains(next) else { return nil }
        return records[next]
    }
}
