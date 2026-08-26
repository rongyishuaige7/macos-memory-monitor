import Darwin
import Foundation

public enum MemoryMonitorError: Error, CustomStringConvertible, Sendable {
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
        freeBytes + inactiveBytes + speculativeBytes + purgeableBytes
    }

    public var usedEstimateBytes: UInt64 {
        totalBytes > availableEstimateBytes ? totalBytes - availableEstimateBytes : 0
    }

    public var availableFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(availableEstimateBytes) / Double(totalBytes)
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

        let capacity = Int(requestedBytes) / MemoryLayout<pid_t>.stride + 1
        var pids = [pid_t](repeating: 0, count: capacity)
        let returnedBytes = pids.withUnsafeMutableBytes { rawBuffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, rawBuffer.baseAddress, Int32(rawBuffer.count))
        }
        guard returnedBytes > 0 else {
            throw MemoryMonitorError.systemCall(name: "proc_listpids", code: returnedBytes)
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

        let footprint = usageResult == 0 ? usage.ri_phys_footprint : UInt64(task.pti_resident_size)
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
    public let isSystem: Bool
    public let representativeProcess: String

    public init(
        id: String,
        title: String,
        processCount: Int,
        physicalFootprintBytes: UInt64,
        residentBytes: UInt64,
        isSystem: Bool,
        representativeProcess: String
    ) {
        self.id = id
        self.title = title
        self.processCount = processCount
        self.physicalFootprintBytes = physicalFootprintBytes
        self.residentBytes = residentBytes
        self.isSystem = isSystem
        self.representativeProcess = representativeProcess
    }
}

/// Groups one sampling pass into stable, user-facing workload labels.
public struct WorkloadGrouper: Sendable {
    public init() {}

    public func group(_ processes: [ProcessSnapshot]) -> [WorkloadGroupSnapshot] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.identity.pid, $0) })
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

        if process.isSystem || ["kernel_task", "windowserver", "controlcenter", "launchd"].contains(own) {
            return ("system", "系统", true)
        }
        if combined.contains("codex") && (identityText.contains("chrome") || identityText.contains("chromium") || identityText.contains("node")) {
            return ("codex-automation", "Codex 自动化", false)
        }
        if own.contains("webkit") || own.contains("safari") || path.contains("webkit") || path.contains("safari") {
            return ("safari-webkit", "Safari/WebKit", false)
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
