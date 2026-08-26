import Darwin
import Foundation

public enum MemoryMonitorError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case systemCall(name: String, code: Int32)
    case invalidData(description: String)

    public var description: String {
        switch self {
        case let .systemCall(name, code):
            return "\(name) failed with code \(code)"
        case let .invalidData(description):
            return description
        }
    }

    public var errorDescription: String? { description }
}

public struct SystemMemorySnapshot: Codable, Sendable {
    public let timestamp: Date
    public let totalBytes: UInt64
    public let pageSize: UInt64
    public let freeBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let speculativeBytes: UInt64
    public let wiredBytes: UInt64
    public let purgeableBytes: UInt64
    public let compressedBytes: UInt64
    public let throttledPages: UInt64
    public let swapTotalBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapFreeBytes: UInt64

    public var availableEstimateBytes: UInt64 {
        // Darwin's free_count already includes speculative pages. Counting it
        // again would overstate the amount that can be made available.
        let (freeAndInactive, firstOverflow) = freeBytes.addingReportingOverflow(inactiveBytes)
        let (available, secondOverflow) = freeAndInactive.addingReportingOverflow(purgeableBytes)
        guard !firstOverflow, !secondOverflow else { return totalBytes }
        return min(totalBytes, available)
    }

    public var usedEstimateBytes: UInt64 {
        totalBytes > availableEstimateBytes ? totalBytes - availableEstimateBytes : 0
    }

    public var availableFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(availableEstimateBytes) / Double(totalBytes), 0), 1)
    }

    public init(
        timestamp: Date = Date(),
        totalBytes: UInt64,
        pageSize: UInt64,
        freeBytes: UInt64,
        activeBytes: UInt64,
        inactiveBytes: UInt64,
        speculativeBytes: UInt64,
        wiredBytes: UInt64,
        purgeableBytes: UInt64,
        compressedBytes: UInt64,
        throttledPages: UInt64,
        swapTotalBytes: UInt64,
        swapUsedBytes: UInt64,
        swapFreeBytes: UInt64
    ) {
        self.timestamp = timestamp
        self.totalBytes = totalBytes
        self.pageSize = pageSize
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.speculativeBytes = speculativeBytes
        self.wiredBytes = wiredBytes
        self.purgeableBytes = purgeableBytes
        self.compressedBytes = compressedBytes
        self.throttledPages = throttledPages
        self.swapTotalBytes = swapTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapFreeBytes = swapFreeBytes
    }
}

public struct SystemMemorySampler: Sendable {
    public init() {}

    public func sample() throws -> SystemMemorySnapshot {
        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(mach_host_self(), &pageSize)
        guard pageStatus == KERN_SUCCESS else {
            throw MemoryMonitorError.systemCall(name: "host_page_size", code: pageStatus)
        }

        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let statisticsStatus = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard statisticsStatus == KERN_SUCCESS else {
            throw MemoryMonitorError.systemCall(name: "host_statistics64", code: statisticsStatus)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapStatus = withUnsafeMutablePointer(to: &swap) { pointer in
            "vm.swapusage".withCString { name in
                sysctlbyname(name, pointer, &swapSize, nil, 0)
            }
        }
        guard swapStatus == 0 else {
            throw MemoryMonitorError.systemCall(name: "sysctl(vm.swapusage)", code: swapStatus)
        }

        let pageBytes = UInt64(pageSize)
        return SystemMemorySnapshot(
            totalBytes: try sysctlUInt64(named: "hw.memsize"),
            pageSize: pageBytes,
            freeBytes: UInt64(statistics.free_count) * pageBytes,
            activeBytes: UInt64(statistics.active_count) * pageBytes,
            inactiveBytes: UInt64(statistics.inactive_count) * pageBytes,
            speculativeBytes: UInt64(statistics.speculative_count) * pageBytes,
            wiredBytes: UInt64(statistics.wire_count) * pageBytes,
            purgeableBytes: UInt64(statistics.purgeable_count) * pageBytes,
            compressedBytes: UInt64(statistics.compressor_page_count) * pageBytes,
            throttledPages: UInt64(statistics.throttled_count),
            swapTotalBytes: swap.xsu_total,
            swapUsedBytes: swap.xsu_used,
            swapFreeBytes: swap.xsu_avail
        )
    }
}

public struct ProcessIdentity: Hashable, Codable, Sendable {
    public let pid: Int32
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(pid: Int32, startTimeSeconds: UInt64, startTimeMicroseconds: UInt64) {
        self.pid = pid
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }
}

public struct ProcessSnapshot: Codable, Sendable, Identifiable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32
    public let isSystem: Bool
    public let name: String
    public let executablePath: String?
    public let residentBytes: UInt64
    public let physicalFootprintBytes: UInt64
    /// True when libproc could not provide phys_footprint and RSS was used as a fallback.
    public let physicalFootprintIsEstimated: Bool
    public let virtualBytes: UInt64
    public let userTimeNanos: UInt64
    public let systemTimeNanos: UInt64
    public let threadCount: Int32

    public var id: ProcessIdentity { identity }

    public init(
        identity: ProcessIdentity,
        parentPID: Int32,
        userID: UInt32,
        isSystem: Bool,
        name: String,
        executablePath: String?,
        residentBytes: UInt64,
        physicalFootprintBytes: UInt64,
        physicalFootprintIsEstimated: Bool = false,
        virtualBytes: UInt64,
        userTimeNanos: UInt64,
        systemTimeNanos: UInt64,
        threadCount: Int32
    ) {
        self.identity = identity
        self.parentPID = parentPID
        self.userID = userID
        self.isSystem = isSystem
        self.name = name
        self.executablePath = executablePath
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.physicalFootprintIsEstimated = physicalFootprintIsEstimated
        self.virtualBytes = virtualBytes
        self.userTimeNanos = userTimeNanos
        self.systemTimeNanos = systemTimeNanos
        self.threadCount = threadCount
    }
}

public struct ProcessSampler: Sendable {
    public init() {}

    public func sample() throws -> [ProcessSnapshot] {
        let requestedBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requestedBytes > 0 else {
            throw MemoryMonitorError.systemCall(name: "proc_listpids(size)", code: requestedBytes)
        }

        var capacity = Int(requestedBytes) / MemoryLayout<pid_t>.stride + 1
        var pids = [pid_t]()
        var returnedBytes: Int32 = 0
        for _ in 0..<3 {
            pids = [pid_t](repeating: 0, count: capacity)
            returnedBytes = pids.withUnsafeMutableBytes { rawBuffer in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, rawBuffer.baseAddress, Int32(rawBuffer.count))
            }
            guard returnedBytes > 0 else {
                throw MemoryMonitorError.systemCall(name: "proc_listpids", code: returnedBytes)
            }
            if Int(returnedBytes) < pids.count * MemoryLayout<pid_t>.stride {
                break
            }
            capacity = max(capacity * 2, Int(returnedBytes) / MemoryLayout<pid_t>.stride + 1)
        }
        guard Int(returnedBytes) < pids.count * MemoryLayout<pid_t>.stride else {
            throw MemoryMonitorError.invalidData(description: "proc_listpids returned a truncated process list")
        }

        let returnedCount = min(Int(returnedBytes) / MemoryLayout<pid_t>.stride, pids.count)
        return pids.prefix(returnedCount).compactMap { pid in
            guard pid > 0 else { return nil }
            return snapshot(pid: pid)
        }
    }

    private func snapshot(pid: pid_t) -> ProcessSnapshot? {
        var info = proc_taskallinfo()
        let infoSize = Int32(MemoryLayout<proc_taskallinfo>.stride)
        let infoBytes = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, pointer, infoSize)
        }
        guard infoBytes >= infoSize else { return nil }

        let bsd = info.pbsd
        let task = info.ptinfo
        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }

        let footprintAvailable = usageResult == 0
        let footprint = footprintAvailable ? usage.ri_phys_footprint : UInt64(task.pti_resident_size)
        let name = withUnsafeBytes(of: bsd.pbi_comm) { rawBuffer -> String in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<end], as: UTF8.self)
        }

        return ProcessSnapshot(
            identity: ProcessIdentity(
                pid: Int32(bsd.pbi_pid),
                startTimeSeconds: bsd.pbi_start_tvsec,
                startTimeMicroseconds: bsd.pbi_start_tvusec
            ),
            parentPID: Int32(bsd.pbi_ppid),
            userID: UInt32(bsd.pbi_uid),
            isSystem: (bsd.pbi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0,
            name: name.isEmpty ? "(unknown)" : name,
            executablePath: executablePath(for: pid),
            residentBytes: task.pti_resident_size,
            physicalFootprintBytes: footprint,
            physicalFootprintIsEstimated: !footprintAvailable,
            virtualBytes: task.pti_virtual_size,
            userTimeNanos: task.pti_total_user,
            systemTimeNanos: task.pti_total_system,
            threadCount: task.pti_threadnum
        )
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let length = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }
}

public struct WorkloadGroupSnapshot: Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let processCount: Int
    public let physicalFootprintBytes: UInt64
    public let residentBytes: UInt64
    public let containsEstimatedFootprint: Bool
    public let isSystem: Bool
    public let representativeProcess: String

    /// Sum of member footprints attributed to this group; shared mappings are
    /// intentionally counted in each member and must not be treated as a
    /// de-duplicated machine total.
    public var attributedFootprintBytes: UInt64 { physicalFootprintBytes }

    /// Sum of member RSS values attributed to this group.
    public var attributedResidentBytes: UInt64 { residentBytes }

    public init(
        id: String,
        title: String,
        processCount: Int,
        physicalFootprintBytes: UInt64,
        residentBytes: UInt64,
        containsEstimatedFootprint: Bool = false,
        isSystem: Bool,
        representativeProcess: String
    ) {
        self.id = id
        self.title = title
        self.processCount = processCount
        self.physicalFootprintBytes = physicalFootprintBytes
        self.residentBytes = residentBytes
        self.containsEstimatedFootprint = containsEstimatedFootprint
        self.isSystem = isSystem
        self.representativeProcess = representativeProcess
    }
}

/// Groups one sampling pass into stable, user-facing workload labels.
public struct WorkloadGrouper: Sendable {
    public init() {}

    public func group(_ processes: [ProcessSnapshot]) -> [WorkloadGroupSnapshot] {
        let byPID = Dictionary(
            processes.map { ($0.identity.pid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var buckets: [String: (title: String, processes: [ProcessSnapshot], isSystem: Bool)] = [:]

        for process in processes {
            let classification = classify(process, byPID: byPID)
            var bucket = buckets[classification.id] ?? (
                title: classification.title,
                processes: [],
                isSystem: classification.isSystem
            )
            bucket.processes.append(process)
            buckets[classification.id] = bucket
        }

        return buckets.map { id, bucket in
            let largest = bucket.processes.max { $0.physicalFootprintBytes < $1.physicalFootprintBytes }
            return WorkloadGroupSnapshot(
                id: id,
                title: bucket.title,
                processCount: bucket.processes.count,
                physicalFootprintBytes: bucket.processes.reduce(0) { $0 + $1.physicalFootprintBytes },
                residentBytes: bucket.processes.reduce(0) { $0 + $1.residentBytes },
                containsEstimatedFootprint: bucket.processes.contains { $0.physicalFootprintIsEstimated },
                isSystem: bucket.isSystem,
                representativeProcess: largest?.name ?? "(unknown)"
            )
        }
        .sorted {
            if $0.isSystem != $1.isSystem { return !$0.isSystem }
            return $0.physicalFootprintBytes > $1.physicalFootprintBytes
        }
    }

    private func classify(
        _ process: ProcessSnapshot,
        byPID: [Int32: ProcessSnapshot]
    ) -> (id: String, title: String, isSystem: Bool) {
        let names = ancestorNames(for: process, byPID: byPID)
        let combined = names.joined(separator: " ").lowercased()
        let own = process.name.lowercased()
        let path = process.executablePath?.lowercased() ?? ""
        let identityText = "\(own) \(path)"

        if process.isSystem || process.userID == 0 || ["kernel_task", "windowserver", "controlcenter", "launchd"].contains(own) {
            return ("system", "系统", true)
        }
        if combined.contains("codex") && (identityText.contains("chrome") || identityText.contains("chromium") || identityText.contains("node")) {
            return ("codex-automation", "Codex 自动化", false)
        }
        if own.contains("safari") || path.contains("safari") || combined.contains("safari") {
            return ("safari-webkit", "Safari/WebKit", false)
        }
        if own.contains("webkit") || path.contains("webkit") {
            return ("unattributed-webkit", "未归属 WebKit", false)
        }
        if identityText.contains("chrome") || identityText.contains("chromium") {
            return ("chrome", "Chrome", false)
        }
        if combined.contains("ghostty") {
            return ("ghostty-services", "Ghostty/开发服务", false)
        }
        if identityText.contains("maibot") || path.contains("maibot") {
            return ("maibot", "MaiBot", false)
        }
        if identityText.contains("virtualization") || identityText.contains("virtual machine") || identityText.contains("vmm") {
            return ("virtual-machines", "虚拟机", false)
        }
        if own.contains("python") || own.contains("node") {
            return ("runtime-\(own)", own, false)
        }
        return ("process-\(own)", process.name, false)
    }

    private func ancestorNames(for process: ProcessSnapshot, byPID: [Int32: ProcessSnapshot]) -> [String] {
        var names = [process.name]
        var parentPID = process.parentPID
        var visited = Set<Int32>()
        while parentPID > 0, visited.insert(parentPID).inserted, let parent = byPID[parentPID] {
            names.append(parent.name)
            parentPID = parent.parentPID
        }
        return names
    }
}

public struct WorkloadGrowth: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let deltaBytes: UInt64
    public let currentFootprintBytes: UInt64
    public let rateBytesPerSecond: Double

    public init(
        id: String,
        title: String,
        deltaBytes: UInt64,
        currentFootprintBytes: UInt64,
        rateBytesPerSecond: Double
    ) {
        self.id = id
        self.title = title
        self.deltaBytes = deltaBytes
        self.currentFootprintBytes = currentFootprintBytes
        self.rateBytesPerSecond = rateBytesPerSecond
    }
}

public struct WorkloadTrendAnalyzer: Sendable {
    public init() {}

    /// Compares only groups present in both samples; new groups need a baseline first.
    public func growingGroups(
        previous: [WorkloadGroupSnapshot],
        current: [WorkloadGroupSnapshot],
        intervalSeconds: TimeInterval
    ) -> [WorkloadGrowth] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let interval = max(intervalSeconds, 0.001)
        return current.compactMap { group in
            guard let old = previousByID[group.id], group.physicalFootprintBytes > old.physicalFootprintBytes else {
                return nil
            }
            let delta = group.physicalFootprintBytes - old.physicalFootprintBytes
            return WorkloadGrowth(
                id: group.id,
                title: group.title,
                deltaBytes: delta,
                currentFootprintBytes: group.physicalFootprintBytes,
                rateBytesPerSecond: Double(delta) / interval
            )
        }
        .sorted {
            if $0.rateBytesPerSecond != $1.rateBytesPerSecond {
                return $0.rateBytesPerSecond > $1.rateBytesPerSecond
            }
            return $0.deltaBytes > $1.deltaBytes
        }
    }
}

/// Chooses a sampling cadence from the amount of detail the user currently needs.
/// The values are deliberately conservative for a menu-bar process monitor: the
/// full process scan is the expensive part, so normal background observation is
/// much less frequent than an open panel or an elevated-pressure state.
public struct AdaptiveSamplingPolicy: Sendable, Equatable {
    public let backgroundIntervalSeconds: TimeInterval
    public let panelIntervalSeconds: TimeInterval
    public let pressureIntervalSeconds: TimeInterval

    public init(
        backgroundIntervalSeconds: TimeInterval = 20,
        panelIntervalSeconds: TimeInterval = 3,
        pressureIntervalSeconds: TimeInterval = 5
    ) {
        self.backgroundIntervalSeconds = Self.validatedInterval(backgroundIntervalSeconds)
        self.panelIntervalSeconds = Self.validatedInterval(panelIntervalSeconds)
        self.pressureIntervalSeconds = Self.validatedInterval(pressureIntervalSeconds)
    }

    public func intervalSeconds(panelPresented: Bool, pressureActive: Bool) -> TimeInterval {
        if panelPresented {
            return panelIntervalSeconds
        }
        if pressureActive {
            return pressureIntervalSeconds
        }
        return backgroundIntervalSeconds
    }

    private static func validatedInterval(_ value: TimeInterval) -> TimeInterval {
        // A lower bound prevents a bad configuration from creating a busy loop.
        guard value.isFinite else { return 0.1 }
        return max(value, 0.1)
    }
}

public struct MemoryHistoryEntry: Sendable, Codable, Identifiable, Equatable {
    public let timestamp: Date
    public let availableFraction: Double
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64

    public var id: Date { timestamp }

    public init(snapshot: SystemMemorySnapshot) {
        timestamp = snapshot.timestamp
        availableFraction = snapshot.availableFraction
        compressedBytes = snapshot.compressedBytes
        swapUsedBytes = snapshot.swapUsedBytes
    }
}

public struct MemoryHistoryBuffer: Sendable {
    public let capacity: Int
    private var storage: [MemoryHistoryEntry] = []

    public init(capacity: Int = 60) {
        self.capacity = max(capacity, 1)
    }

    public var entries: [MemoryHistoryEntry] { storage }

    public mutating func append(snapshot: SystemMemorySnapshot) {
        storage.append(MemoryHistoryEntry(snapshot: snapshot))
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }
}

/// The privacy-preserving workload fields written to the on-disk history.
/// Values are sums of the processes assigned to a group and are not a
/// de-duplicated physical-memory measurement.
public struct PersistedWorkloadRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let processCount: Int
    public let attributedFootprintBytes: UInt64
    public let attributedResidentBytes: UInt64
    public let isSystem: Bool

    public init(
        id: String,
        title: String,
        processCount: Int,
        attributedFootprintBytes: UInt64,
        attributedResidentBytes: UInt64,
        isSystem: Bool
    ) {
        self.id = id
        self.title = title
        self.processCount = processCount
        self.attributedFootprintBytes = attributedFootprintBytes
        self.attributedResidentBytes = attributedResidentBytes
        self.isSystem = isSystem
    }

    public init(group: WorkloadGroupSnapshot) {
        self.init(
            id: group.id,
            title: group.title,
            processCount: group.processCount,
            attributedFootprintBytes: group.attributedFootprintBytes,
            attributedResidentBytes: group.attributedResidentBytes,
            isSystem: group.isSystem
        )
    }
}

/// One minute-level system and workload sample retained by `HistoryStore`.
public struct MemoryHistoryRecord: Codable, Sendable, Identifiable, Equatable {
    public let timestamp: Date
    public let availableFraction: Double
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let workloads: [PersistedWorkloadRecord]

    public var id: Date { timestamp }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case availableFraction
        case compressedBytes
        case swapUsedBytes
        case workloads
    }

    public init(
        timestamp: Date,
        availableFraction: Double,
        compressedBytes: UInt64,
        swapUsedBytes: UInt64,
        workloads: [PersistedWorkloadRecord] = []
    ) {
        self.timestamp = timestamp
        self.availableFraction = min(max(availableFraction, 0), 1)
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.workloads = workloads
    }

    public init(snapshot: SystemMemorySnapshot, groups: [WorkloadGroupSnapshot] = []) {
        self.init(
            timestamp: snapshot.timestamp,
            availableFraction: snapshot.availableFraction,
            compressedBytes: snapshot.compressedBytes,
            swapUsedBytes: snapshot.swapUsedBytes,
            workloads: groups.map(PersistedWorkloadRecord.init(group:))
        )
    }

    public init(entry: MemoryHistoryEntry) {
        self.init(
            timestamp: entry.timestamp,
            availableFraction: entry.availableFraction,
            compressedBytes: entry.compressedBytes,
            swapUsedBytes: entry.swapUsedBytes
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            availableFraction: try container.decode(Double.self, forKey: .availableFraction),
            compressedBytes: try container.decode(UInt64.self, forKey: .compressedBytes),
            swapUsedBytes: try container.decode(UInt64.self, forKey: .swapUsedBytes),
            workloads: try container.decodeIfPresent([PersistedWorkloadRecord].self, forKey: .workloads) ?? []
        )
    }
}

/// Versioned file envelope so future schema changes can be rejected clearly.
public struct MemoryHistoryFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let records: [MemoryHistoryRecord]

    public init(version: Int = MemoryHistoryFile.currentVersion, records: [MemoryHistoryRecord]) {
        self.version = version
        self.records = records
    }
}

public enum HistoryStoreError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    case readFailed
    case writeFailed
    case invalidData
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .readFailed:
            return "无法读取 24 小时历史文件"
        case .writeFailed:
            return "无法写入 24 小时历史文件"
        case .invalidData:
            return "24 小时历史文件格式无效或已损坏"
        case let .unsupportedVersion(version):
            return "不支持的历史文件版本 " + String(version)
        }
    }

    public var errorDescription: String? { description }
}

/// A small, minute-coalesced JSON history store.
///
/// Appending samples updates memory on every pass, but disk writes happen at
/// most once per minute (plus an explicit `flush()`), which keeps the monitor
/// lightweight while bounding crash-related data loss to roughly one minute.
/// Only the largest workload records are kept individually; the remainder are
/// represented by user/system attribution aggregates.
public actor HistoryStore {
    public static let defaultRetentionInterval: TimeInterval = 24 * 60 * 60
    public static let defaultMaxPersistedWorkloads = 40

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("MemoryMonitor", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    public let fileURL: URL
    public let retentionInterval: TimeInterval
    public let maxPersistedWorkloads: Int

    private var records: [MemoryHistoryRecord] = []
    private var hasLoaded = false
    private var dirty = false
    private var lastPersistedMinute: Date?

    public init(
        fileURL: URL = HistoryStore.defaultFileURL,
        retentionInterval: TimeInterval = HistoryStore.defaultRetentionInterval,
        maxPersistedWorkloads: Int = HistoryStore.defaultMaxPersistedWorkloads
    ) {
        self.fileURL = fileURL
        self.retentionInterval = max(retentionInterval, 0)
        self.maxPersistedWorkloads = max(maxPersistedWorkloads, 1)
    }

    @discardableResult
    public func load(now: Date = Date()) throws -> [MemoryHistoryRecord] {
        guard !hasLoaded else {
            let before = records
            records = Self.pruned(coalesced(records), now: now, retentionInterval: retentionInterval)
            if records != before {
                dirty = true
                try persist()
            }
            return records
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            hasLoaded = true
            return []
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw HistoryStoreError.readFailed
        }

        let file: MemoryHistoryFile
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            file = try decoder.decode(MemoryHistoryFile.self, from: data)
        } catch {
            throw HistoryStoreError.invalidData
        }
        guard file.version == MemoryHistoryFile.currentVersion else {
            throw HistoryStoreError.unsupportedVersion(file.version)
        }

        let coalescedRecords = coalesced(file.records)
        records = Self.pruned(coalescedRecords, now: now, retentionInterval: retentionInterval)
        hasLoaded = true
        dirty = records != file.records
        lastPersistedMinute = records.last?.timestamp
        if dirty {
            try persist()
        }
        return records
    }

    @discardableResult
    public func append(
        snapshot: SystemMemorySnapshot,
        groups: [WorkloadGroupSnapshot] = [],
        now: Date = Date()
    ) throws -> [MemoryHistoryRecord] {
        try append(MemoryHistoryRecord(snapshot: snapshot, groups: groups), now: now)
    }

    @discardableResult
    public func append(_ record: MemoryHistoryRecord, now: Date = Date()) throws -> [MemoryHistoryRecord] {
        if !hasLoaded {
            _ = try load(now: now)
        }

        let normalized = normalized(record)
        let existingIndex = records.firstIndex(where: { $0.timestamp == normalized.timestamp })
        if let index = existingIndex {
            records[index] = normalized
        } else {
            records.append(normalized)
        }
        let sortedRecords = records.sorted { $0.timestamp < $1.timestamp }
        records = Self.pruned(sortedRecords, now: now, retentionInterval: retentionInterval)
        dirty = true

        // A first write and each new minute are persisted immediately. Samples
        // within the same minute stay in memory until the next minute or flush.
        let removedExpiredRecords = records.count < sortedRecords.count
        if lastPersistedMinute != normalized.timestamp || removedExpiredRecords {
            try persist()
        }
        return records
    }

    public func currentRecords(now: Date = Date()) throws -> [MemoryHistoryRecord] {
        if !hasLoaded {
            return try load(now: now)
        }
        let before = records
        records = Self.pruned(records, now: now, retentionInterval: retentionInterval)
        if records != before {
            dirty = true
            try persist()
        }
        return records
    }

    public func flush() throws {
        guard hasLoaded, dirty else { return }
        try persist()
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(MemoryHistoryFile(records: records))
            // Atomic writes use a temporary sibling and rename it into place.
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw HistoryStoreError.writeFailed
        }
        dirty = false
        lastPersistedMinute = records.last?.timestamp
    }

    private static func minuteStart(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else { return date }
        return Date(timeIntervalSince1970: floor(seconds / 60) * 60)
    }

    private func normalized(_ record: MemoryHistoryRecord) -> MemoryHistoryRecord {
        MemoryHistoryRecord(
            timestamp: Self.minuteStart(record.timestamp),
            availableFraction: record.availableFraction,
            compressedBytes: record.compressedBytes,
            swapUsedBytes: record.swapUsedBytes,
            workloads: Self.compactWorkloads(record.workloads, limit: maxPersistedWorkloads)
        )
    }

    private func coalesced(_ source: [MemoryHistoryRecord]) -> [MemoryHistoryRecord] {
        var byMinute: [Date: MemoryHistoryRecord] = [:]
        for record in source {
            let normalizedRecord = normalized(record)
            byMinute[normalizedRecord.timestamp] = normalizedRecord
        }
        return byMinute.values.sorted { $0.timestamp < $1.timestamp }
    }

    private static func compactWorkloads(
        _ source: [PersistedWorkloadRecord],
        limit: Int
    ) -> [PersistedWorkloadRecord] {
        let ranked = source.sorted {
            if $0.attributedFootprintBytes != $1.attributedFootprintBytes {
                return $0.attributedFootprintBytes > $1.attributedFootprintBytes
            }
            if $0.isSystem != $1.isSystem {
                return !$0.isSystem
            }
            return $0.id < $1.id
        }
        guard ranked.count > limit else { return ranked }

        var result = Array(ranked.prefix(limit))
        var aggregateBySystem: [Bool: (processCount: Int, footprint: UInt64, resident: UInt64)] = [:]
        for workload in ranked.dropFirst(limit) {
            var aggregate = aggregateBySystem[workload.isSystem] ?? (0, 0, 0)
            aggregate.processCount = adding(aggregate.processCount, workload.processCount)
            aggregate.footprint = adding(aggregate.footprint, workload.attributedFootprintBytes)
            aggregate.resident = adding(aggregate.resident, workload.attributedResidentBytes)
            aggregateBySystem[workload.isSystem] = aggregate
        }

        for (isSystem, aggregate) in aggregateBySystem {
            result.append(
                PersistedWorkloadRecord(
                    id: isSystem ? "other-system" : "other-processes",
                    title: isSystem ? "其他系统进程" : "其他进程",
                    processCount: aggregate.processCount,
                    attributedFootprintBytes: aggregate.footprint,
                    attributedResidentBytes: aggregate.resident,
                    isSystem: isSystem
                )
            )
        }
        return result.sorted {
            if $0.attributedFootprintBytes != $1.attributedFootprintBytes {
                return $0.attributedFootprintBytes > $1.attributedFootprintBytes
            }
            if $0.isSystem != $1.isSystem {
                return !$0.isSystem
            }
            return $0.id < $1.id
        }
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        guard rhs > 0 else { return lhs }
        return lhs > Int.max - rhs ? Int.max : lhs + rhs
    }

    private static func pruned(
        _ source: [MemoryHistoryRecord],
        now: Date,
        retentionInterval: TimeInterval
    ) -> [MemoryHistoryRecord] {
        let cutoff = now.timeIntervalSince1970 - retentionInterval
        guard cutoff.isFinite else { return source }
        return source.filter { $0.timestamp.timeIntervalSince1970 >= cutoff }
    }
}

public enum MemoryFormatter {
    public static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var number = Double(value)
        var index = 0
        while number >= 1024 && index < units.count - 1 {
            number /= 1024
            index += 1
        }

        if index == 0 {
            return "\(value) B"
        }
        return "\(String(format: "%.1f", number)) \(units[index])"
    }
}

private func sysctlUInt64(named name: String) throws -> UInt64 {
    var value: UInt64 = 0
    var size = MemoryLayout<UInt64>.size
    let result = name.withCString { sysctlName in
        sysctlbyname(sysctlName, &value, &size, nil, 0)
    }
    guard result == 0 else {
        throw MemoryMonitorError.systemCall(name: "sysctl(\(name))", code: result)
    }
    return value
}
