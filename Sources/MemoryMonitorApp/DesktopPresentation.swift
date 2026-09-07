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

struct DesktopProcessGroup: Identifiable {
    let id: String
    let title: String
    let members: [ProcessSnapshot]
    var bytes: UInt64 { members.reduce(0) { $0 &+ $1.physicalFootprintBytes } }
    var estimated: Bool { members.contains { $0.physicalFootprintIsEstimated } }
    func cpu(_ samples: [ProcessIdentity: Double]) -> Double? {
        let values = members.compactMap { samples[$0.identity] }
        return values.count == members.count ? values.reduce(0, +) : nil
    }
}

enum DesktopPresentation {
    static func groupedProcesses(
        _ groups: [WorkloadGroupSnapshot], processes: [ProcessSnapshot], query: String,
        includeSystem: Bool, sort: DesktopProcessSort, cpu: [ProcessIdentity: Double]
    ) -> [DesktopProcessGroup] {
        let visible = Self.processes(processes, query: "", includeSystem: includeSystem, sort: .memory, cpu: cpu)
        let byID = Dictionary(visible.map { ($0.identity, $0) }, uniquingKeysWith: { _, new in new })
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<ProcessIdentity>()
        var result: [DesktopProcessGroup] = []
        for group in groups {
            let members = group.memberProcessIdentities.compactMap { byID[$0] }.filter { seen.insert($0.identity).inserted }
            guard !members.isEmpty else { continue }
            result.append(.init(id: group.id, title: group.title,
                                members: members.sorted(by: ProcessSnapshot.memoryDescending)))
        }
        for process in visible where !seen.contains(process.identity) {
            result.append(.init(id: "process-\(process.identity)", title: process.applicationName ?? process.name, members: [process]))
        }
        return result.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) ||
            !Self.processes($0.members, query: query, includeSystem: true, sort: .memory, cpu: cpu).isEmpty
        }.sorted {
            switch sort {
            case .memory:
                if $0.estimated != $1.estimated { return !$0.estimated }
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            case .cpu:
                let lhs = $0.cpu(cpu) ?? -1, rhs = $1.cpu(cpu) ?? -1
                if lhs != rhs { return lhs > rhs }
            case .name:
                let order = $0.title.localizedStandardCompare($1.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return $0.id < $1.id
        }
    }

    static func initialHistoryHours(_ records: [MemoryHistoryRecord], now: Date) -> Int {
        guard let first = records.filter({ $0.timestamp <= now }).map(\.timestamp).min() else { return 1 }
        let span = now.timeIntervalSince(first)
        return span <= 3600 ? 1 : span <= 21600 ? 6 : 24
    }

    /// Segment before downsampling so the point budget cannot create artificial gaps.
    static func chartSegments(_ records: [MemoryHistoryRecord], hours: Int, now: Date) -> [Date: Int] {
        let ordered = records.filter { $0.timestamp >= now.addingTimeInterval(-Double(hours) * 3600) && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        var result: [Date: Int] = [:]
        var previous: Date?
        var segment = 0
        for record in ordered {
            if let previous, record.timestamp.timeIntervalSince(previous) > 120 { segment += 1 }
            result[record.timestamp] = segment
            previous = record.timestamp
        }
        return result
    }
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
            ?? applicationIcon(path: process.executablePath)
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
        cache.setObject(image, forKey: key)
        return image
    }

    private func applicationIcon(path: String?) -> NSImage? {
        guard let path else { return nil }
        var url = URL(fileURLWithPath: path)
        while url.path != "/" {
            if url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
