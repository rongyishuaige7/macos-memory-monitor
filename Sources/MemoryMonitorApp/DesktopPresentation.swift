import AppKit
import MemoryMonitorCore

struct ProcessCPUBaseline {
    private var timestamp: Date?
    private var times: [ProcessIdentity: UInt64] = [:]

    mutating func update(_ processes: [ProcessSnapshot], at date: Date) -> [ProcessIdentity: Double] {
        defer {
            timestamp = date
            times = Dictionary(processes.map { ($0.identity, $0.cpuTimeNanos) }, uniquingKeysWith: { _, new in new })
        }
        guard let timestamp else { return [:] }
        let elapsed = date.timeIntervalSince(timestamp)
        guard elapsed.isFinite, elapsed > 0, elapsed <= 120 else { return [:] }
        return processes.reduce(into: [:]) { result, process in
            guard let previous = times[process.identity], process.cpuTimeNanos >= previous else { return }
            result[process.identity] = Double(process.cpuTimeNanos - previous) / 1_000_000_000 / elapsed * 100
        }
    }
}

enum DesktopProcessSort: String, CaseIterable, Identifiable {
    case memory = "内存占用", cpu = "CPU 占用", name = "名称"
    var id: Self { self }
}

enum DesktopPresentation {
    static func processes(
        _ processes: [ProcessSnapshot], query: String, includeSystem: Bool,
        sort: DesktopProcessSort, cpu: [ProcessIdentity: Double]
    ) -> [ProcessSnapshot] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return processes.filter {
            (includeSystem || (!$0.isSystem && $0.userID != 0)) &&
            (query.isEmpty || ($0.applicationName ?? $0.name).localizedCaseInsensitiveContains(query)
             || $0.name.localizedCaseInsensitiveContains(query) || String($0.identity.pid).contains(query))
        }.sorted {
            switch sort {
            case .memory: return ProcessSnapshot.memoryDescending($0, $1)
            case .cpu:
                let lhs = cpu[$0.identity] ?? -1
                let rhs = cpu[$1.identity] ?? -1
                return lhs == rhs ? ProcessSnapshot.memoryDescending($0, $1) : lhs > rhs
            case .name:
                let result = ($0.applicationName ?? $0.name).localizedStandardCompare($1.applicationName ?? $1.name)
                return result == .orderedSame ? ProcessSnapshot.memoryDescending($0, $1) : result == .orderedAscending
            }
        }
    }

    /// Keep each bucket's extrema so brief peaks survive the chart point budget.
    static func chartRecords(_ records: [MemoryHistoryRecord], hours: Int, now: Date) -> [MemoryHistoryRecord] {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        let records = records.filter { $0.timestamp >= start && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        guard records.count > 240 else { return records }
        let bucketSize = Int(ceil(Double(records.count) / 118))
        var result = [records[0]]
        for offset in stride(from: 1, to: records.count - 1, by: bucketSize) {
            let bucket = records[offset..<min(offset + bucketSize, records.count - 1)]
            if let low = bucket.min(by: { $0.usedFraction < $1.usedFraction }),
               let high = bucket.max(by: { $0.usedFraction < $1.usedFraction }) {
                result.append(contentsOf: low.timestamp == high.timestamp ? [low] : [low, high].sorted { $0.timestamp < $1.timestamp })
            }
        }
        result.append(records[records.count - 1])
        return result
    }
}

@MainActor
final class ProcessIconCache {
    static let shared = ProcessIconCache()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 256 }

    func icon(for process: ProcessSnapshot) -> NSImage {
        let key = "\(process.identity.pid):\(process.identity.startTimeSeconds):\(process.identity.startTimeMicroseconds)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSRunningApplication(processIdentifier: process.identity.pid)?.icon
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
        cache.setObject(image, forKey: key)
        return image
    }
}
