import Darwin
import Foundation
import IOKit

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

/// Describes how trustworthy a value is for the current sampling pass.
/// `estimated` means a value was obtained through a documented fallback;
/// it is not interchangeable with an unavailable or failed measurement.
public enum SampleQuality: String, Codable, Sendable, Equatable {
    case available
    case estimated
    case unavailable
    case error

    public var displayName: String {
        switch self {
        case .available: return "实时"
        case .estimated: return "部分可用"
        case .unavailable: return "暂无数据"
        case .error: return "采集失败"
        }
    }

    public var isUsable: Bool {
        self == .available || self == .estimated
    }
}

/// Lightweight metadata attached to each independent metric source.
/// `sampledAt` is nil when no value was captured, so a failure cannot look
/// like a fresh zero-valued sample.
public struct SampleStatus: Codable, Sendable, Equatable {
    public let quality: SampleQuality
    public let message: String?
    public let sampledAt: Date?

    public init(
        quality: SampleQuality,
        message: String? = nil,
        sampledAt: Date? = nil
    ) {
        self.quality = quality
        self.message = message
        self.sampledAt = sampledAt
    }

    public static func available(at date: Date, message: String? = nil) -> SampleStatus {
        SampleStatus(quality: .available, message: message, sampledAt: date)
    }

    public static func estimated(at date: Date, message: String? = nil) -> SampleStatus {
        SampleStatus(quality: .estimated, message: message, sampledAt: date)
    }

    public static func unavailable(message: String? = nil) -> SampleStatus {
        SampleStatus(quality: .unavailable, message: message)
    }

    public static func error(_ message: String) -> SampleStatus {
        SampleStatus(quality: .error, message: message)
    }

    public func sampleAge(at now: Date = Date()) -> TimeInterval? {
        guard let sampledAt else { return nil }
        let age = now.timeIntervalSince(sampledAt)
        return age.isFinite ? max(age, 0) : nil
    }

    public var shortDescription: String {
        if let message, !message.isEmpty {
            return "\(quality.displayName) · \(message)"
        }
        return quality.displayName
    }
}

public struct SystemMemorySnapshot: Codable, Sendable, Equatable {
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

    /// Reclaim-aware physical memory usage, expressed as a fraction of total RAM.
    /// This is the complement of `availableFraction` and intentionally follows
    /// the same estimate used by the pressure indicator.
    public var usedFraction: Double {
        min(max(1 - availableFraction, 0), 1)
    }

    public var availableFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(availableEstimateBytes) / Double(totalBytes), 0), 1)
    }

    public var isStructurallyValid: Bool {
        totalBytes > 0 && pageSize > 0
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
        let totalBytes = try sysctlUInt64(named: "hw.memsize")
        guard pageBytes > 0, totalBytes > 0 else {
            throw MemoryMonitorError.invalidData(description: "系统内存采样返回了无效的总量或页大小")
        }
        return SystemMemorySnapshot(
            totalBytes: totalBytes,
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

/// Cumulative CPU time counters returned by the Mach host interface.
public struct CPUTimeSnapshot: Sendable, Equatable {
    public let userTicks: UInt64
    public let systemTicks: UInt64
    public let idleTicks: UInt64
    public let niceTicks: UInt64

    public init(
        userTicks: UInt64,
        systemTicks: UInt64,
        idleTicks: UInt64,
        niceTicks: UInt64
    ) {
        self.userTicks = userTicks
        self.systemTicks = systemTicks
        self.idleTicks = idleTicks
        self.niceTicks = niceTicks
    }

    public var activeTicks: UInt64 {
        saturatingAdd(saturatingAdd(userTicks, systemTicks), niceTicks)
    }

    public var totalTicks: UInt64 {
        saturatingAdd(activeTicks, idleTicks)
    }

    private func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}

/// Samples system-wide CPU counters without invoking external commands.
public struct CPUTimeSampler: Sendable {
    public init() {}

    public func sample() throws -> CPUTimeSnapshot {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &load) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw MemoryMonitorError.systemCall(name: "host_statistics(HOST_CPU_LOAD_INFO)", code: status)
        }

        return CPUTimeSnapshot(
            userTicks: UInt64(load.cpu_ticks.0),
            systemTicks: UInt64(load.cpu_ticks.1),
            idleTicks: UInt64(load.cpu_ticks.2),
            niceTicks: UInt64(load.cpu_ticks.3)
        )
    }
}

/// Converts two cumulative CPU samples into a bounded 0...1 utilization value.
public enum CPUUsageCalculator {
    public static func usedFraction(
        current: CPUTimeSnapshot,
        previous: CPUTimeSnapshot
    ) -> Double? {
        guard let totalDelta = delta(current.totalTicks, previous.totalTicks), totalDelta > 0,
              let activeDelta = delta(current.activeTicks, previous.activeTicks),
              activeDelta <= totalDelta else {
            return nil
        }
        return min(max(Double(activeDelta) / Double(totalDelta), 0), 1)
    }

    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64? {
        current >= previous ? current - previous : nil
    }
}

/// Reads the aggregate GPU utilization exposed by Apple's IOAccelerator
/// service. The property is intentionally optional: some macOS versions or
/// restricted environments do not expose performance statistics to user apps.
public struct GPUUsageSample: Sendable, Equatable {
    public let fraction: Double?
    public let status: SampleStatus

    public init(fraction: Double?, status: SampleStatus) {
        self.fraction = fraction
        self.status = status
    }
}

public struct GPUUsageSampler: Sendable {
    private static let utilizationKeys = [
        "Device Utilization %",
        "GPU Utilization %",
        "Renderer Utilization %",
        "Tiler Utilization %"
    ]

    public init() {}

    public func sample() -> Double? {
        sampleDetailed().fraction
    }

    public func sampleDetailed(at timestamp: Date = Date()) -> GPUUsageSample {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        let matchingStatus = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard matchingStatus == KERN_SUCCESS else {
            return GPUUsageSample(
                fraction: nil,
                status: SampleStatus.error("IOAccelerator 查询失败（\(matchingStatus)）")
            )
        }
        defer { IOObjectRelease(iterator) }

        var values: [Double] = []
        var propertyFailures = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }

            var properties: Unmanaged<CFMutableDictionary>?
            let status = IORegistryEntryCreateCFProperties(
                service,
                &properties,
                kCFAllocatorDefault,
                0
            )
            if status == KERN_SUCCESS, let properties {
                let dictionary = properties.takeRetainedValue() as NSDictionary
                if let performance = dictionary["PerformanceStatistics"] as? NSDictionary,
                   let utilization = utilization(in: performance) {
                    values.append(utilization)
                } else {
                    propertyFailures += 1
                }
            } else {
                propertyFailures += 1
            }
            IOObjectRelease(service)
        }

        guard let value = values.max() else {
            let message = propertyFailures > 0
                ? "IOAccelerator 未提供可读利用率"
                : "未发现可用 GPU 利用率"
            return GPUUsageSample(
                fraction: nil,
                status: SampleStatus.unavailable(message: message)
            )
        }
        return GPUUsageSample(
            fraction: value,
            status: SampleStatus.available(at: timestamp)
        )
    }

    private func utilization(in performance: NSDictionary) -> Double? {
        for key in Self.utilizationKeys {
            guard let number = performance[key] as? NSNumber else { continue }
            let percentage = number.doubleValue
            guard percentage.isFinite else { continue }
            return min(max(percentage / 100, 0), 1)
        }
        return nil
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

/// Extracts a short, privacy-preserving project label from a process working
/// directory. The full path never leaves the sampling layer.
public enum WorkingDirectoryLabelSanitizer {
    public static let maxLength = 48

    /// Returns a safe basename for an absolute working-directory path.
    /// Common roots and transient macOS directories are intentionally omitted.
    public static func label(
        from path: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> String? {
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !normalizedPath.isEmpty, normalizedPath != "/" else { return nil }

        let normalizedHome = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        if normalizedPath == normalizedHome {
            return nil
        }
        if transientPrefixes.contains(where: { prefix in
            normalizedPath == prefix || normalizedPath.hasPrefix(prefix + "/")
        }) {
            return nil
        }

        return label(fromComponent: URL(fileURLWithPath: normalizedPath).lastPathComponent)
    }

    /// Cleans a basename for display. This also handles synthetic/test input
    /// so callers cannot smuggle path separators or terminal control codes.
    public static func label(fromComponent component: String) -> String? {
        var filtered = ""
        for scalar in component.unicodeScalars {
            if isControl(scalar) {
                continue
            }
            if scalar.value == 0x2F || scalar.value == 0x5C {
                filtered.append("-")
            } else {
                filtered.unicodeScalars.append(scalar)
            }
        }

        let collapsed = filtered
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty, collapsed != ".", collapsed != ".." else { return nil }

        let limited = String(collapsed.prefix(maxLength))
        return limited.isEmpty ? nil : limited
    }

    /// Encodes a label for use in a stable workload ID without losing
    /// distinction between non-ASCII project names.
    public static func identifierComponent(for label: String) -> String {
        let cleaned = self.label(fromComponent: label) ?? "project"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return cleaned.addingPercentEncoding(withAllowedCharacters: allowed) ?? "project"
    }

    private static let transientPrefixes = [
        "/tmp",
        "/private/tmp",
        "/var/tmp",
        "/private/var/tmp",
        "/var/folders",
        "/private/var/folders"
    ]

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // C0/C1 controls and bidirectional/invisible formatting controls are
        // not useful in a process label and can make UI/log output deceptive.
        return value < 0x20
            || (0x7F...0x9F).contains(value)
            || (0x200B...0x200F).contains(value)
            || (0x202A...0x202E).contains(value)
            || (0x2060...0x2064).contains(value)
            || (0x2066...0x2069).contains(value)
    }
}

/// Optional application metadata resolved from the nearest `.app` bundle in
/// an executable path. It is intentionally absent for command-line tools and
/// system daemons; callers must continue to use the process name as fallback.
public struct ApplicationIdentity: Codable, Sendable, Equatable {
    public let name: String?
    public let bundleIdentifier: String?

    public init(name: String? = nil, bundleIdentifier: String? = nil) {
        self.name = name.flatMap(WorkingDirectoryLabelSanitizer.label(fromComponent:))
        self.bundleIdentifier = bundleIdentifier.flatMap(WorkingDirectoryLabelSanitizer.label(fromComponent:))
    }
}

public enum ApplicationIdentityResolver {
    public static func resolve(executablePath: String?) -> ApplicationIdentity? {
        guard let executablePath, executablePath.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: executablePath).standardizedFileURL
        let components = url.pathComponents
        guard let appIndex = components.lastIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }

        let appPath = NSString.path(withComponents: Array(components.prefix(appIndex + 1)))
        guard let bundle = Bundle(path: appPath) else { return nil }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
        let bundleIdentifier = bundle.bundleIdentifier
        guard displayName != nil || bundleIdentifier != nil else { return nil }
        return ApplicationIdentity(
            name: displayName.flatMap(WorkingDirectoryLabelSanitizer.label(fromComponent:)),
            bundleIdentifier: bundleIdentifier.flatMap(WorkingDirectoryLabelSanitizer.label(fromComponent:))
        )
    }
}

public struct ProcessSnapshot: Codable, Sendable, Identifiable, Equatable {
    public let identity: ProcessIdentity
    public let parentPID: Int32
    public let userID: UInt32
    public let isSystem: Bool
    public let name: String
    public let executablePath: String?
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let residentBytes: UInt64
    public let physicalFootprintBytes: UInt64
    /// True when libproc could not provide phys_footprint and RSS was used as a fallback.
    public let physicalFootprintIsEstimated: Bool
    /// A sanitized basename of the current working directory, when available.
    public let workingDirectoryLabel: String?
    public let virtualBytes: UInt64
    public let userTimeNanos: UInt64
    public let systemTimeNanos: UInt64
    public let threadCount: Int32

    public var id: ProcessIdentity { identity }

    /// The process start instant reconstructed from the stable identity.
    /// A nil value means the kernel supplied an invalid timestamp.
    public var startDate: Date? {
        let seconds = Double(identity.startTimeSeconds)
            + Double(identity.startTimeMicroseconds) / 1_000_000
        guard seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Cumulative CPU time. This is intentionally not presented as a
    /// percentage because a percentage requires a second process sample and a
    /// defined machine-core denominator.
    public var cpuTimeNanos: UInt64 {
        let (value, overflow) = userTimeNanos.addingReportingOverflow(systemTimeNanos)
        return overflow ? UInt64.max : value
    }

    public var footprintQuality: SampleQuality {
        physicalFootprintIsEstimated ? .estimated : .available
    }

    public static func memoryDescending(_ lhs: ProcessSnapshot, _ rhs: ProcessSnapshot) -> Bool {
        if lhs.physicalFootprintBytes != rhs.physicalFootprintBytes {
            return lhs.physicalFootprintBytes > rhs.physicalFootprintBytes
        }
        if lhs.residentBytes != rhs.residentBytes {
            return lhs.residentBytes > rhs.residentBytes
        }
        return lhs.identity.pid < rhs.identity.pid
    }

    public init(
        identity: ProcessIdentity,
        parentPID: Int32,
        userID: UInt32,
        isSystem: Bool,
        name: String,
        executablePath: String?,
        applicationName: String? = nil,
        bundleIdentifier: String? = nil,
        residentBytes: UInt64,
        physicalFootprintBytes: UInt64,
        physicalFootprintIsEstimated: Bool = false,
        workingDirectoryLabel: String? = nil,
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
        self.applicationName = applicationName.flatMap(WorkingDirectoryLabelSanitizer.label(fromComponent:))
        self.bundleIdentifier = bundleIdentifier.flatMap(WorkingDirectoryLabelSanitizer.label(fromComponent:))
        self.residentBytes = residentBytes
        self.physicalFootprintBytes = physicalFootprintBytes
        self.physicalFootprintIsEstimated = physicalFootprintIsEstimated
        self.workingDirectoryLabel = workingDirectoryLabel.flatMap { label in
            // A basename cannot contain path separators. Rejecting them here
            // keeps public model construction from reintroducing full paths.
            guard !label.contains("/"), !label.contains("\\") else { return nil }
            return WorkingDirectoryLabelSanitizer.label(fromComponent: label)
        }
        self.virtualBytes = virtualBytes
        self.userTimeNanos = userTimeNanos
        self.systemTimeNanos = systemTimeNanos
        self.threadCount = threadCount
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case parentPID
        case userID
        case isSystem
        case name
        case executablePath
        case applicationName
        case bundleIdentifier
        case residentBytes
        case physicalFootprintBytes
        case physicalFootprintIsEstimated
        case workingDirectoryLabel
        case virtualBytes
        case userTimeNanos
        case systemTimeNanos
        case threadCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identity: try container.decode(ProcessIdentity.self, forKey: .identity),
            parentPID: try container.decode(Int32.self, forKey: .parentPID),
            userID: try container.decode(UInt32.self, forKey: .userID),
            isSystem: try container.decode(Bool.self, forKey: .isSystem),
            name: try container.decode(String.self, forKey: .name),
            executablePath: try container.decodeIfPresent(String.self, forKey: .executablePath),
            applicationName: try container.decodeIfPresent(String.self, forKey: .applicationName),
            bundleIdentifier: try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            residentBytes: try container.decode(UInt64.self, forKey: .residentBytes),
            physicalFootprintBytes: try container.decode(UInt64.self, forKey: .physicalFootprintBytes),
            physicalFootprintIsEstimated: try container.decodeIfPresent(Bool.self, forKey: .physicalFootprintIsEstimated) ?? false,
            workingDirectoryLabel: try container.decodeIfPresent(String.self, forKey: .workingDirectoryLabel),
            virtualBytes: try container.decode(UInt64.self, forKey: .virtualBytes),
            userTimeNanos: try container.decode(UInt64.self, forKey: .userTimeNanos),
            systemTimeNanos: try container.decode(UInt64.self, forKey: .systemTimeNanos),
            threadCount: try container.decode(Int32.self, forKey: .threadCount)
        )
    }
}

public struct ProcessSamplingResult: Sendable, Equatable {
    public let processes: [ProcessSnapshot]
    public let listedProcessCount: Int
    public let sampledProcessCount: Int
    public let skippedProcessCount: Int
    public let status: SampleStatus

    public init(
        processes: [ProcessSnapshot],
        listedProcessCount: Int,
        sampledProcessCount: Int,
        skippedProcessCount: Int,
        status: SampleStatus
    ) {
        self.processes = processes
        let normalizedSampledCount = processes.count
        let normalizedListedCount = max(max(listedProcessCount, 0), normalizedSampledCount)
        self.listedProcessCount = normalizedListedCount
        self.sampledProcessCount = normalizedSampledCount
        self.skippedProcessCount = max(
            max(skippedProcessCount, 0),
            normalizedListedCount - normalizedSampledCount
        )
        self.status = status
    }
}

public struct ProcessSampler: Sendable {
    public init() {}

    public func sample() throws -> [ProcessSnapshot] {
        try sampleDetailed().processes
    }

    /// Enumerates all visible processes and reports processes that disappear
    /// or become inaccessible during the scan instead of silently hiding the
    /// partial result.
    public func sampleDetailed(at timestamp: Date = Date()) throws -> ProcessSamplingResult {
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
        var seenPIDs = Set<pid_t>()
        let candidatePIDs = pids.prefix(returnedCount).filter { pid in
            pid > 0 && seenPIDs.insert(pid).inserted
        }
        let processes: [ProcessSnapshot] = candidatePIDs.compactMap { pid in
            snapshot(pid: pid)
        }
        let skippedCount = candidatePIDs.count - processes.count
        let hasEstimatedFootprint = processes.contains { $0.physicalFootprintIsEstimated }
        let status: SampleStatus
        if skippedCount == 0, !hasEstimatedFootprint {
            status = SampleStatus.available(at: timestamp)
        } else {
            var reasons = [String]()
            if skippedCount > 0 {
                reasons.append("\(skippedCount) 个进程在扫描期间退出或受权限限制")
            }
            if hasEstimatedFootprint {
                reasons.append("部分 footprint 使用 RSS 估算")
            }
            status = SampleStatus.estimated(at: timestamp, message: reasons.joined(separator: "；"))
        }
        return ProcessSamplingResult(
            processes: processes,
            listedProcessCount: candidatePIDs.count,
            sampledProcessCount: processes.count,
            skippedProcessCount: skippedCount,
            status: status
        )
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
        let processName = name.isEmpty ? "(unknown)" : name
        let directoryLabel = capturesWorkingDirectory(for: processName)
            ? workingDirectoryLabel(for: pid)
            : nil

        let path = executablePath(for: pid)
        let application = ApplicationIdentityResolver.resolve(executablePath: path)
        return ProcessSnapshot(
            identity: ProcessIdentity(
                pid: Int32(bsd.pbi_pid),
                startTimeSeconds: bsd.pbi_start_tvsec,
                startTimeMicroseconds: bsd.pbi_start_tvusec
            ),
            parentPID: Int32(bsd.pbi_ppid),
            userID: UInt32(bsd.pbi_uid),
            isSystem: (bsd.pbi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0,
            name: processName,
            executablePath: path,
            applicationName: application?.name,
            bundleIdentifier: application?.bundleIdentifier,
            residentBytes: task.pti_resident_size,
            physicalFootprintBytes: footprint,
            physicalFootprintIsEstimated: !footprintAvailable,
            workingDirectoryLabel: directoryLabel,
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

    private func capturesWorkingDirectory(for name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.contains("node") || lowercased.contains("python")
    }

    private func workingDirectoryLabel(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let infoSize = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let infoBytes = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, infoSize)
        }
        guard infoBytes >= infoSize else { return nil }

        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { rawBuffer -> String? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.count
            guard end > 0 else { return nil }
            let path = String(decoding: bytes[..<end], as: UTF8.self)
            return WorkingDirectoryLabelSanitizer.label(from: path)
        }
    }
}

public enum WorkloadAttributionReason: String, Codable, Sendable, Equatable {
    case systemProcess
    case codexSession
    case codexAncestor
    case safariAncestor
    case unattributedWebKit
    case chromeIdentity
    case ghosttyAncestor
    case maibotIdentity
    case virtualizationIdentity
    case runtimeWorkingDirectory
    case runtimeAncestorWorkingDirectory
    case runtimeFallback
    case processName

    public var displayName: String {
        switch self {
        case .systemProcess: return "系统标记或 UID 0"
        case .codexSession: return "进程或应用标识包含 Codex"
        case .codexAncestor: return "父链包含 Codex，并包含浏览器或运行时"
        case .safariAncestor: return "父链包含 Safari"
        case .unattributedWebKit: return "未找到 Safari 父链"
        case .chromeIdentity: return "进程或应用标识包含 Chrome/Chromium"
        case .ghosttyAncestor: return "父链包含 Ghostty"
        case .maibotIdentity: return "进程或可执行路径包含 MaiBot"
        case .virtualizationIdentity: return "进程标识包含虚拟化运行时"
        case .runtimeWorkingDirectory: return "运行时名称 + 工作目录标签"
        case .runtimeAncestorWorkingDirectory: return "运行时名称 + 父链工作目录标签"
        case .runtimeFallback: return "运行时名称，未取得工作目录"
        case .processName: return "进程名称"
        }
    }
}

public struct WorkloadGroupSnapshot: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let processCount: Int
    public let physicalFootprintBytes: UInt64
    public let residentBytes: UInt64
    public let containsEstimatedFootprint: Bool
    public let isSystem: Bool
    public let representativeProcess: String
    public let attributionReason: WorkloadAttributionReason
    /// Names of the representative process's ancestors, nearest first.
    /// Only short process names are retained; paths and command lines never
    /// enter this field.
    public let parentChain: [String]

    /// Stable identities of the members captured in this live sampling pass.
    /// These are deliberately omitted from `PersistedWorkloadRecord` and never
    /// written to the 24-hour history.
    public let memberProcessIdentities: [ProcessIdentity]

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
        representativeProcess: String,
        attributionReason: WorkloadAttributionReason = .processName,
        parentChain: [String] = [],
        memberProcessIdentities: [ProcessIdentity] = []
    ) {
        self.id = id
        self.title = title
        self.processCount = processCount
        self.physicalFootprintBytes = physicalFootprintBytes
        self.residentBytes = residentBytes
        self.containsEstimatedFootprint = containsEstimatedFootprint
        self.isSystem = isSystem
        self.representativeProcess = representativeProcess
        self.attributionReason = attributionReason
        self.parentChain = Array(
            parentChain
                .compactMap { WorkingDirectoryLabelSanitizer.label(fromComponent: $0) }
                .prefix(8)
        )
        var uniqueIdentities = Set<ProcessIdentity>()
        self.memberProcessIdentities = memberProcessIdentities.filter {
            uniqueIdentities.insert($0).inserted
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case processCount
        case physicalFootprintBytes
        case residentBytes
        case containsEstimatedFootprint
        case isSystem
        case representativeProcess
        case attributionReason
        case parentChain
        case memberProcessIdentities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            processCount: try container.decode(Int.self, forKey: .processCount),
            physicalFootprintBytes: try container.decode(UInt64.self, forKey: .physicalFootprintBytes),
            residentBytes: try container.decode(UInt64.self, forKey: .residentBytes),
            containsEstimatedFootprint: try container.decodeIfPresent(Bool.self, forKey: .containsEstimatedFootprint) ?? false,
            isSystem: try container.decode(Bool.self, forKey: .isSystem),
            representativeProcess: try container.decode(String.self, forKey: .representativeProcess),
            attributionReason: try container.decodeIfPresent(WorkloadAttributionReason.self, forKey: .attributionReason) ?? .processName,
            parentChain: try container.decodeIfPresent([String].self, forKey: .parentChain) ?? [],
            memberProcessIdentities: try container.decodeIfPresent([ProcessIdentity].self, forKey: .memberProcessIdentities) ?? []
        )
    }
}

/// Groups one sampling pass into stable, user-facing workload labels.
public struct WorkloadGrouper: Sendable {
    public init() {}

    public func group(_ processes: [ProcessSnapshot]) -> [WorkloadGroupSnapshot] {
        // A PID can be reused after a process exits. If one pass contains
        // ambiguous entries, do not follow that PID and accidentally inherit
        // the wrong application's attribution.
        let byPID = Dictionary(grouping: processes, by: { $0.identity.pid })
            .compactMapValues { candidates -> ProcessSnapshot? in
                guard let first = candidates.first,
                      candidates.dropFirst().allSatisfy({ $0.identity == first.identity }) else {
                    return nil
                }
                return first
            }
        var buckets: [String: (
            title: String,
            processes: [ProcessSnapshot],
            isSystem: Bool,
            reason: WorkloadAttributionReason
        )] = [:]

        for process in processes {
            let classification = classify(process, byPID: byPID)
            var bucket = buckets[classification.id] ?? (
                title: classification.title,
                processes: [],
                isSystem: classification.isSystem,
                reason: classification.reason
            )
            bucket.processes.append(process)
            buckets[classification.id] = bucket
        }

        return buckets.map { id, bucket in
            let largest = bucket.processes.sorted(by: ProcessSnapshot.memoryDescending).first
            return WorkloadGroupSnapshot(
                id: id,
                title: bucket.title,
                processCount: bucket.processes.count,
                physicalFootprintBytes: bucket.processes.reduce(0) {
                    Self.saturatingAdd($0, $1.physicalFootprintBytes)
                },
                residentBytes: bucket.processes.reduce(0) {
                    Self.saturatingAdd($0, $1.residentBytes)
                },
                containsEstimatedFootprint: bucket.processes.contains { $0.physicalFootprintIsEstimated },
                isSystem: bucket.isSystem,
                representativeProcess: largest?.name ?? "(unknown)",
                attributionReason: bucket.reason,
                parentChain: largest.map { parentChain(for: $0, byPID: byPID) } ?? [],
                memberProcessIdentities: bucket.processes.map(\.identity)
            )
        }
        .sorted {
            if $0.physicalFootprintBytes != $1.physicalFootprintBytes {
                return $0.physicalFootprintBytes > $1.physicalFootprintBytes
            }
            if $0.isSystem != $1.isSystem { return !$0.isSystem }
            return $0.id < $1.id
        }
    }

    private struct Classification {
        let id: String
        let title: String
        let isSystem: Bool
        let reason: WorkloadAttributionReason
    }

    private func classify(
        _ process: ProcessSnapshot,
        byPID: [Int32: ProcessSnapshot]
    ) -> Classification {
        let names = ancestorNames(for: process, byPID: byPID)
        let combined = names.joined(separator: " ").lowercased()
        let own = process.name.lowercased()
        let path = process.executablePath?.lowercased() ?? ""
        let applicationText = "\(process.applicationName ?? "") \(process.bundleIdentifier ?? "")".lowercased()
        let identityText = "\(own) \(path) \(applicationText)"

        if process.isSystem || process.userID == 0 || ["kernel_task", "windowserver", "controlcenter", "launchd"].contains(own) {
            return Classification(id: "system", title: "系统", isSystem: true, reason: .systemProcess)
        }
        if own == "codex" || path.contains("/codex") || applicationText.contains("codex") {
            let hasAutomationDescendant = identityText.contains("chrome")
                || identityText.contains("chromium")
                || identityText.contains("node")
                || identityText.contains("webkit")
                || identityText.contains("python")
            return hasAutomationDescendant
                ? Classification(id: "codex-automation", title: "Codex 自动化", isSystem: false, reason: .codexAncestor)
                : Classification(id: "codex-session", title: "Codex 会话", isSystem: false, reason: .codexSession)
        }
        if combined.contains("codex") && (identityText.contains("chrome") || identityText.contains("chromium") || identityText.contains("node")) {
            return Classification(id: "codex-automation", title: "Codex 自动化", isSystem: false, reason: .codexAncestor)
        }
        if own.contains("safari") || path.contains("safari") || combined.contains("safari") {
            return Classification(id: "safari-webkit", title: "Safari/WebKit", isSystem: false, reason: .safariAncestor)
        }
        if own.contains("webkit") || path.contains("webkit") {
            return Classification(id: "unattributed-webkit", title: "未归属 WebKit", isSystem: false, reason: .unattributedWebKit)
        }
        if identityText.contains("chrome") || identityText.contains("chromium") {
            return Classification(id: "chrome", title: "Chrome", isSystem: false, reason: .chromeIdentity)
        }
        if combined.contains("ghostty") {
            return Classification(id: "ghostty-services", title: "Ghostty/开发服务", isSystem: false, reason: .ghosttyAncestor)
        }
        if identityText.contains("maibot") || path.contains("maibot") {
            return Classification(id: "maibot", title: "MaiBot", isSystem: false, reason: .maibotIdentity)
        }
        if identityText.contains("virtualization") || identityText.contains("virtual machine") || identityText.contains("vmm") {
            return Classification(id: "virtual-machines", title: "虚拟机", isSystem: false, reason: .virtualizationIdentity)
        }
        if let runtime = runtimeDescriptor(for: own) {
            if let resolution = workingDirectoryResolution(for: process, byPID: byPID) {
                let label = resolution.label
                let component = WorkingDirectoryLabelSanitizer.identifierComponent(for: label)
                return Classification(
                    id: "runtime-\(runtime.id)-\(component)",
                    title: "\(runtime.title) · \(label)",
                    isSystem: false,
                    reason: resolution.inherited ? .runtimeAncestorWorkingDirectory : .runtimeWorkingDirectory
                )
            }
            return Classification(
                id: "runtime-\(runtime.id)",
                title: runtime.title,
                isSystem: false,
                reason: .runtimeFallback
            )
        }
        return Classification(id: "process-\(own)", title: process.name, isSystem: false, reason: .processName)
    }

    private func runtimeDescriptor(for name: String) -> (id: String, title: String)? {
        if name.contains("python") {
            return ("python", "Python")
        }
        if name.contains("node") {
            return ("node", "Node")
        }
        return nil
    }

    private func workingDirectoryResolution(
        for process: ProcessSnapshot,
        byPID: [Int32: ProcessSnapshot]
    ) -> (label: String, inherited: Bool)? {
        var current = process
        var visited = Set<Int32>()
        var inherited = false
        while true {
            if let label = current.workingDirectoryLabel,
               let sanitized = WorkingDirectoryLabelSanitizer.label(fromComponent: label) {
                return (sanitized, inherited)
            }

            let parentPID = current.parentPID
            guard parentPID > 0,
                  visited.insert(parentPID).inserted,
                  let parent = byPID[parentPID] else {
                return nil
            }
            current = parent
            inherited = true
        }
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

    private func parentChain(for process: ProcessSnapshot, byPID: [Int32: ProcessSnapshot]) -> [String] {
        ancestorNames(for: process, byPID: byPID)
            .dropFirst()
            .prefix(8)
            .compactMap { WorkingDirectoryLabelSanitizer.label(fromComponent: $0) }
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}

/// A complete sampling pass. Every source has its own status so a failure in
/// process enumeration cannot discard otherwise valid system metrics.
public struct MonitorSnapshot: Sendable, Equatable {
    public let timestamp: Date
    public let samplingMode: SamplingMode
    public let diagnostics: SamplingDiagnostics
    public let system: SystemMemorySnapshot?
    public let systemStatus: SampleStatus
    public let cpuTime: CPUTimeSnapshot?
    public let cpuStatus: SampleStatus
    public let gpuUsageFraction: Double?
    public let gpuStatus: SampleStatus
    public let processes: [ProcessSnapshot]
    public let processStatus: SampleStatus
    public let listedProcessCount: Int
    public let sampledProcessCount: Int
    public let groups: [WorkloadGroupSnapshot]

    public var processCount: Int { sampledProcessCount }

    public init(
        timestamp: Date,
        system: SystemMemorySnapshot?,
        systemStatus: SampleStatus,
        cpuTime: CPUTimeSnapshot?,
        cpuStatus: SampleStatus,
        gpuUsageFraction: Double?,
        gpuStatus: SampleStatus,
        processes: [ProcessSnapshot],
        processStatus: SampleStatus,
        listedProcessCount: Int,
        sampledProcessCount: Int,
        groups: [WorkloadGroupSnapshot],
        samplingMode: SamplingMode = .full,
        diagnostics: SamplingDiagnostics? = nil
    ) {
        self.timestamp = timestamp
        self.samplingMode = samplingMode
        self.system = system
        self.systemStatus = systemStatus
        self.cpuTime = cpuTime
        self.cpuStatus = cpuStatus
        self.gpuUsageFraction = gpuUsageFraction
        self.gpuStatus = gpuStatus
        self.processes = processes
        self.processStatus = processStatus
        let normalizedListedCount = max(listedProcessCount, 0)
        let normalizedSampledCount = max(sampledProcessCount, 0)
        self.listedProcessCount = max(normalizedListedCount, normalizedSampledCount)
        self.sampledProcessCount = normalizedSampledCount
        self.groups = groups
        self.diagnostics = diagnostics ?? SamplingDiagnostics(
            mode: samplingMode,
            totalDurationMilliseconds: 0,
            processDurationMilliseconds: samplingMode.samplesProcesses ? 0 : nil,
            processSamplingPerformed: samplingMode.samplesProcesses,
            processCount: normalizedSampledCount,
            listedProcessCount: max(normalizedListedCount, normalizedSampledCount)
        )
    }

    public var didSampleProcesses: Bool {
        diagnostics.processSamplingPerformed
    }
}

/// Coordinates independent native samplers and degrades each source in
/// isolation. Providers are injectable to keep failure behavior testable
/// without trying to manufacture kernel or IORegistry failures.
public struct MonitorSampler: Sendable {
    private let systemProvider: @Sendable () throws -> SystemMemorySnapshot
    private let cpuProvider: @Sendable () throws -> CPUTimeSnapshot
    private let gpuProvider: @Sendable () -> GPUUsageSample
    private let processProvider: @Sendable () throws -> ProcessSamplingResult
    private let grouper: WorkloadGrouper

    public init(
        systemSampler: @escaping @Sendable () throws -> SystemMemorySnapshot = {
            try SystemMemorySampler().sample()
        },
        cpuSampler: @escaping @Sendable () throws -> CPUTimeSnapshot = {
            try CPUTimeSampler().sample()
        },
        gpuSampler: @escaping @Sendable () -> GPUUsageSample = {
            GPUUsageSampler().sampleDetailed()
        },
        processSampler: @escaping @Sendable () throws -> ProcessSamplingResult = {
            try ProcessSampler().sampleDetailed()
        },
        grouper: WorkloadGrouper = WorkloadGrouper()
    ) {
        self.systemProvider = systemSampler
        self.cpuProvider = cpuSampler
        self.gpuProvider = gpuSampler
        self.processProvider = processSampler
        self.grouper = grouper
    }

    public func sample(at timestamp: Date = Date()) -> MonitorSnapshot {
        sample(mode: .full, at: timestamp)
    }

    public func sample(
        mode: SamplingMode,
        at timestamp: Date = Date()
    ) -> MonitorSnapshot {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        var system: SystemMemorySnapshot?
        let systemStatus: SampleStatus
        do {
            let value = try systemProvider()
            guard value.isStructurallyValid else {
                throw MemoryMonitorError.invalidData(description: "系统内存采样返回了无效数据")
            }
            system = value
            systemStatus = SampleStatus.estimated(
                at: value.timestamp,
                message: "内存使用率按可回收内存估算"
            )
        } catch {
            systemStatus = Self.errorStatus(for: error)
        }

        var cpuTime: CPUTimeSnapshot?
        let cpuStatus: SampleStatus
        do {
            cpuTime = try cpuProvider()
            cpuStatus = SampleStatus.available(at: timestamp)
        } catch {
            cpuStatus = Self.errorStatus(for: error)
        }

        let gpuSample = gpuProvider()

        var processes: [ProcessSnapshot] = []
        let processSamplingPerformed = mode.samplesProcesses
        let processStartedAt = processSamplingPerformed
            ? DispatchTime.now().uptimeNanoseconds
            : nil
        var processStatus: SampleStatus
        var listedProcessCount = 0
        var sampledProcessCount = 0
        if processSamplingPerformed {
            do {
                let result = try processProvider()
                processes = result.processes.sorted(by: ProcessSnapshot.memoryDescending)
                processStatus = result.status
                listedProcessCount = result.listedProcessCount
                sampledProcessCount = processes.count
            } catch {
                processStatus = Self.errorStatus(for: error)
            }
        } else {
            processStatus = SampleStatus.unavailable(message: "本轮后台采样未执行进程扫描")
        }

        let processDurationMilliseconds = processStartedAt.map {
            elapsedMilliseconds(since: $0)
        }
        let diagnostics = SamplingDiagnostics(
            mode: mode,
            totalDurationMilliseconds: elapsedMilliseconds(since: startedAt),
            processDurationMilliseconds: processDurationMilliseconds,
            processSamplingPerformed: processSamplingPerformed,
            processCount: sampledProcessCount,
            listedProcessCount: listedProcessCount
        )

        return MonitorSnapshot(
            timestamp: timestamp,
            system: system,
            systemStatus: systemStatus,
            cpuTime: cpuTime,
            cpuStatus: cpuStatus,
            gpuUsageFraction: gpuSample.fraction,
            gpuStatus: gpuSample.status,
            processes: processes,
            processStatus: processStatus,
            listedProcessCount: listedProcessCount,
            sampledProcessCount: sampledProcessCount,
            groups: grouper.group(processes),
            samplingMode: mode,
            diagnostics: diagnostics
        )
    }

    private static func errorStatus(for error: Error) -> SampleStatus {
        SampleStatus.error(error.localizedDescription)
    }

    private func elapsedMilliseconds(since start: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= start else { return 0 }
        return Double(now - start) / 1_000_000
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

public enum RecommendationSeverity: String, Codable, Sendable, Equatable {
    case info
    case attention
    case critical

    public var priority: Int {
        switch self {
        case .info: return 1
        case .attention: return 2
        case .critical: return 3
        }
    }

    public var displayName: String {
        switch self {
        case .info: return "提示"
        case .attention: return "注意"
        case .critical: return "优先处理"
        }
    }
}

public struct RecommendationEvidence: Codable, Sendable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// A read-only explanation generated from a pair of immutable observations.
/// `id` is stable for a rule/target pair so the UI can de-duplicate repeated
/// samples without persisting process identities or command lines.
public struct MemoryRecommendation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: RecommendationSeverity
    public let title: String
    public let detail: String
    public let evidence: [RecommendationEvidence]
    public let confidence: Double
    public let targetGroupID: String?
    public let generatedAt: Date

    public init(
        id: String,
        severity: RecommendationSeverity,
        title: String,
        detail: String,
        evidence: [RecommendationEvidence],
        confidence: Double,
        targetGroupID: String? = nil,
        generatedAt: Date
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.evidence = evidence
        self.confidence = min(max(confidence.isFinite ? confidence : 0, 0), 1)
        self.targetGroupID = targetGroupID
        self.generatedAt = generatedAt
    }

    public var confidencePercent: Int {
        Int((confidence * 100).rounded())
    }

    public var deduplicationKey: String { id }
}

/// Inputs used by the recommendation engine. Previous process groups are
/// supplied separately because a background system-only pass intentionally
/// carries no fresh process list.
public struct RecommendationContext: Sendable, Equatable {
    public let current: MonitorSnapshot
    /// Latest system sample used for recovery and system-only signals.
    public let previousSystem: SystemMemorySnapshot?
    /// System sample captured alongside `previousGroups`. Keeping this
    /// separate prevents a cheap background system pass from shortening the
    /// process-trend interval.
    public let previousProcessSystem: SystemMemorySnapshot?
    public let previousGroups: [WorkloadGroupSnapshot]
    public let previousProcessStatus: SampleStatus?
    /// Debounced pressure levels supplied by the monitor coordinator. When
    /// absent, the engine falls back to the raw level derived from the current
    /// and previous system snapshots for standalone callers and older clients.
    public let pressureLevel: MemoryPressureLevel?
    public let previousPressureLevel: MemoryPressureLevel?

    public init(
        current: MonitorSnapshot,
        previousSystem: SystemMemorySnapshot? = nil,
        previousProcessSystem: SystemMemorySnapshot? = nil,
        previousGroups: [WorkloadGroupSnapshot] = [],
        previousProcessStatus: SampleStatus? = nil,
        pressureLevel: MemoryPressureLevel? = nil,
        previousPressureLevel: MemoryPressureLevel? = nil
    ) {
        self.current = current
        self.previousSystem = previousSystem
        self.previousProcessSystem = previousProcessSystem
        self.previousGroups = previousGroups
        self.previousProcessStatus = previousProcessStatus
        self.pressureLevel = pressureLevel
        self.previousPressureLevel = previousPressureLevel
    }
}

/// Produces conservative, explainable, read-only suggestions. The engine is
/// deliberately pure and has no process-control or notification side effects.
public struct RecommendationEngine: Sendable {
    public let minimumGrowthBytes: UInt64
    public let swapGrowthThresholdBytes: UInt64
    public let residualSwapThresholdBytes: UInt64
    public let criticalGroupFraction: Double

    public init(
        minimumGrowthBytes: UInt64 = 16 * 1024 * 1024,
        swapGrowthThresholdBytes: UInt64 = 64 * 1024 * 1024,
        residualSwapThresholdBytes: UInt64 = 1 * 1024 * 1024 * 1024,
        criticalGroupFraction: Double = 0.10
    ) {
        self.minimumGrowthBytes = minimumGrowthBytes
        self.swapGrowthThresholdBytes = swapGrowthThresholdBytes
        self.residualSwapThresholdBytes = residualSwapThresholdBytes
        self.criticalGroupFraction = min(max(criticalGroupFraction.isFinite ? criticalGroupFraction : 0.10, 0), 1)
    }

    public func evaluate(_ context: RecommendationContext) -> [MemoryRecommendation] {
        guard let system = context.current.system,
              context.current.systemStatus.quality.isUsable else {
            return []
        }

        let observedLevel = MemoryPressureEvaluator.observedLevel(for: system)
        let currentPressureLevel = context.pressureLevel ?? observedLevel
        let baseConfidence = confidence(
            systemStatus: context.current.systemStatus,
            processStatus: context.current.processStatus,
            hasBaseline: context.previousProcessSystem != nil || context.previousSystem != nil
        )
        var recommendations = [MemoryRecommendation]()

        if currentPressureLevel == .critical,
           context.current.didSampleProcesses,
           let group = largestActionableGroup(in: context.current.groups),
           Double(group.physicalFootprintBytes) / Double(system.totalBytes) >= criticalGroupFraction {
            let fraction = Double(group.physicalFootprintBytes) / Double(system.totalBytes)
            recommendations.append(
                MemoryRecommendation(
                    id: "critical-group-\(group.id)",
                    severity: .critical,
                    title: "优先检查 \(group.title)",
                    detail: "当前内存压力严重，该用户工作组的归因总量较大；先确认它是否仍在执行当前任务。",
                    evidence: [
                        RecommendationEvidence(label: "压力", value: "严重"),
                        RecommendationEvidence(label: "归因总量", value: MemoryFormatter.bytes(group.attributedFootprintBytes)),
                        RecommendationEvidence(label: "占总内存", value: String(format: "%.0f%%", fraction * 100))
                    ],
                    confidence: baseConfidence,
                    targetGroupID: group.id,
                    generatedAt: context.current.timestamp
                )
            )
        }

        if context.current.didSampleProcesses,
           context.current.processStatus.quality.isUsable,
           context.previousProcessStatus?.quality.isUsable ?? true,
           let previousSystem = context.previousProcessSystem ?? context.previousSystem {
            let interval = max(
                context.current.timestamp.timeIntervalSince(previousSystem.timestamp),
                0.001
            )
            let growth = WorkloadTrendAnalyzer().growingGroups(
                previous: context.previousGroups,
                current: context.current.groups,
                intervalSeconds: interval
            )
            if let growing = growth.first(where: { !$0.title.isEmpty && !isSystemGroup(id: $0.id) }),
               growing.deltaBytes >= minimumGrowthBytes {
                let swapDelta = positiveDelta(
                    current: system.swapUsedBytes,
                    previous: previousSystem.swapUsedBytes
                )
                let pressureElevated = currentPressureLevel != .normal
                let severity: RecommendationSeverity =
                    swapDelta >= swapGrowthThresholdBytes || pressureElevated ? .attention : .info
                var evidence = [
                    RecommendationEvidence(label: "增长", value: MemoryFormatter.bytes(growing.deltaBytes)),
                    RecommendationEvidence(label: "速度", value: rateDescription(growing.rateBytesPerSecond)),
                    RecommendationEvidence(label: "当前归因总量", value: MemoryFormatter.bytes(growing.currentFootprintBytes))
                ]
                if swapDelta > 0 {
                    evidence.append(
                        RecommendationEvidence(label: "Swap 增量", value: MemoryFormatter.bytes(swapDelta))
                    )
                }
                recommendations.append(
                    MemoryRecommendation(
                        id: "growth-\(growing.id)",
                        severity: severity,
                        title: "\(growing.title) 正在增长",
                        detail: swapDelta >= swapGrowthThresholdBytes
                            ? "该工作组在最近采样间隔持续增加，并伴随 Swap 上升；建议检查任务是否仍有必要运行。"
                            : "该工作组在最近采样间隔持续增加；建议继续观察下一轮趋势。",
                        evidence: evidence,
                        confidence: min(baseConfidence, context.current.processStatus.quality == .estimated ? 0.70 : 0.90),
                        targetGroupID: growing.id,
                        generatedAt: context.current.timestamp
                    )
                )
            }

        }

        // Recovery is a system-only signal, so it must remain available when
        // the current pass intentionally skips the expensive process scan.
        if let previousSystem = context.previousSystem {
            let previousPressureLevel = context.previousPressureLevel
                ?? MemoryPressureEvaluator.observedLevel(for: previousSystem)
            if previousPressureLevel != .normal,
               currentPressureLevel == .normal,
               system.availableFraction > previousSystem.availableFraction,
               system.swapUsedBytes >= residualSwapThresholdBytes {
                recommendations.append(
                    MemoryRecommendation(
                        id: "recovery-swap",
                        severity: .info,
                        title: "压力已下降，Swap 仍在回收",
                        detail: "可回收内存已经改善，但 Swap 仍有存量；先观察系统回收，不要把残留 Swap 当作新的泄漏。",
                        evidence: [
                            RecommendationEvidence(label: "可回收内存", value: String(format: "%.0f%%", system.availableFraction * 100)),
                            RecommendationEvidence(label: "Swap 已用", value: MemoryFormatter.bytes(system.swapUsedBytes))
                        ],
                        confidence: baseConfidence,
                        generatedAt: context.current.timestamp
                    )
                )
            }
        }

        if recommendations.isEmpty,
           context.current.didSampleProcesses,
           context.current.processStatus.quality == .estimated {
            recommendations.append(
                MemoryRecommendation(
                    id: "data-quality-processes",
                    severity: .info,
                    title: "进程数据部分可用",
                    detail: "本轮有进程退出或受权限限制，建议把当前排行作为方向参考，不据此执行清理。",
                    evidence: [
                        RecommendationEvidence(label: "成功读取", value: String(context.current.sampledProcessCount)),
                        RecommendationEvidence(label: "已枚举", value: String(context.current.listedProcessCount))
                    ],
                    confidence: 0.60,
                    generatedAt: context.current.timestamp
                )
            )
        }

        return recommendations.sorted {
            if $0.severity.priority != $1.severity.priority {
                return $0.severity.priority > $1.severity.priority
            }
            if $0.confidence != $1.confidence {
                return $0.confidence > $1.confidence
            }
            return $0.id < $1.id
        }
    }

    private func largestActionableGroup(in groups: [WorkloadGroupSnapshot]) -> WorkloadGroupSnapshot? {
        groups
            .filter { !$0.isSystem && !$0.id.hasPrefix("other-") }
            .max {
                if $0.attributedFootprintBytes != $1.attributedFootprintBytes {
                    return $0.attributedFootprintBytes < $1.attributedFootprintBytes
                }
                return $0.id > $1.id
            }
    }

    private func confidence(
        systemStatus: SampleStatus,
        processStatus: SampleStatus,
        hasBaseline: Bool
    ) -> Double {
        var value = 0.90
        if systemStatus.quality == .estimated { value -= 0.10 }
        if processStatus.quality == .estimated { value -= 0.20 }
        if !hasBaseline { value -= 0.15 }
        return min(max(value, 0.20), 0.95)
    }

    private func positiveDelta(current: UInt64, previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func rateDescription(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "--" }
        let perMinute = bytesPerSecond * 60
        guard perMinute.isFinite, perMinute < Double(UInt64.max) else {
            return "快速增长"
        }
        return "\(MemoryFormatter.bytes(UInt64(perMinute)))/分钟"
    }

    private func isSystemGroup(id: String) -> Bool {
        id == "system" || id == "other-system"
    }
}

/// Controls how much work a sampling pass is allowed to perform. System
/// counters are cheap enough for every pass; a complete process enumeration is
/// deliberately reserved for moments where the user needs fresh detail.
public enum SamplingMode: String, Codable, Sendable, Equatable {
    case background
    case backgroundProcess
    case panel
    case pressure
    case full

    public var samplesProcesses: Bool {
        self != .background
    }

    public var displayName: String {
        switch self {
        case .background:
            return "后台系统"
        case .backgroundProcess:
            return "后台进程刷新"
        case .panel:
            return "面板"
        case .pressure:
            return "压力观察"
        case .full:
            return "完整采样"
        }
    }
}

/// Runtime diagnostics for one sampling pass. Durations are intentionally
/// transient: they help tune the monitor without adding operational metadata
/// to the privacy-preserving history file.
public struct SamplingDiagnostics: Codable, Sendable, Equatable {
    public let mode: SamplingMode
    public let totalDurationMilliseconds: Double
    public let processDurationMilliseconds: Double?
    public let processSamplingPerformed: Bool
    public let processCount: Int
    public let listedProcessCount: Int

    public init(
        mode: SamplingMode,
        totalDurationMilliseconds: Double,
        processDurationMilliseconds: Double?,
        processSamplingPerformed: Bool,
        processCount: Int,
        listedProcessCount: Int
    ) {
        self.mode = mode
        self.totalDurationMilliseconds = Self.normalizedDuration(totalDurationMilliseconds)
        self.processDurationMilliseconds = processDurationMilliseconds.map(Self.normalizedDuration)
        self.processSamplingPerformed = processSamplingPerformed
        let normalizedProcessCount = max(processCount, 0)
        let normalizedListedProcessCount = max(listedProcessCount, 0)
        self.processCount = normalizedProcessCount
        self.listedProcessCount = max(normalizedListedProcessCount, normalizedProcessCount)
    }

    private static func normalizedDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(value, 0)
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
    public let backgroundProcessIntervalSeconds: TimeInterval
    public let pressureProcessIntervalSeconds: TimeInterval

    public init(
        backgroundIntervalSeconds: TimeInterval = 20,
        panelIntervalSeconds: TimeInterval = 3,
        pressureIntervalSeconds: TimeInterval = 5,
        backgroundProcessIntervalSeconds: TimeInterval = 60,
        pressureProcessIntervalSeconds: TimeInterval = 10
    ) {
        self.backgroundIntervalSeconds = Self.validatedInterval(backgroundIntervalSeconds)
        self.panelIntervalSeconds = Self.validatedInterval(panelIntervalSeconds)
        self.pressureIntervalSeconds = Self.validatedInterval(pressureIntervalSeconds)
        self.backgroundProcessIntervalSeconds = Self.validatedInterval(backgroundProcessIntervalSeconds)
        self.pressureProcessIntervalSeconds = Self.validatedInterval(pressureProcessIntervalSeconds)
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

    /// Selects the work performed by the next pass. A panel always requests
    /// fresh process data. In normal background operation, the process scan is
    /// independently throttled while system metrics continue at their normal
    /// cadence.
    public func samplingMode(
        panelPresented: Bool,
        pressureActive: Bool,
        now: Date = Date(),
        lastProcessSampleAt: Date?
    ) -> SamplingMode {
        if panelPresented {
            return .panel
        }
        if pressureActive {
            return processRefreshIsDue(
                now: now,
                lastProcessSampleAt: lastProcessSampleAt,
                interval: pressureProcessIntervalSeconds
            ) ? .pressure : .background
        }
        return processRefreshIsDue(
            now: now,
            lastProcessSampleAt: lastProcessSampleAt,
            interval: backgroundProcessIntervalSeconds
        ) ? .backgroundProcess : .background
    }

    public func cadenceDescription(panelPresented: Bool, pressureActive: Bool) -> String {
        if panelPresented {
            return "系统/进程约 \(formattedSeconds(panelIntervalSeconds)) 秒"
        }
        if pressureActive {
            return "系统约 \(formattedSeconds(pressureIntervalSeconds)) 秒 · 进程约 \(formattedSeconds(pressureProcessIntervalSeconds)) 秒"
        }
        return "系统约 \(formattedSeconds(backgroundIntervalSeconds)) 秒 · 进程约 \(formattedSeconds(backgroundProcessIntervalSeconds)) 秒"
    }

    private func formattedSeconds(_ value: TimeInterval) -> String {
        guard value.rounded() == value, value <= Double(Int.max) else {
            return String(format: "%.1f", value)
        }
        return String(Int(value))
    }

    private func processRefreshIsDue(
        now: Date,
        lastProcessSampleAt: Date?,
        interval: TimeInterval
    ) -> Bool {
        guard let lastProcessSampleAt else { return true }
        let age = now.timeIntervalSince(lastProcessSampleAt)
        // Treat a clock rollback or an invalid date as due instead of
        // suppressing process refreshes indefinitely.
        guard age.isFinite, age >= 0 else { return true }
        return age >= interval
    }

    private static func validatedInterval(_ value: TimeInterval) -> TimeInterval {
        // A lower bound prevents a bad configuration from creating a busy loop.
        guard value.isFinite else { return 0.1 }
        return max(value, 0.1)
    }
}

public enum MemoryPressureLevel: String, Codable, Sendable, Equatable {
    case normal
    case attention
    case critical

    public var displayName: String {
        switch self {
        case .normal: return "正常"
        case .attention: return "注意"
        case .critical: return "严重"
        }
    }
}

/// Converts raw system metrics into a stable pressure level. A candidate level
/// must remain unchanged for the configured interval before it replaces the
/// current level, which prevents one noisy sample from changing the UI state.
public struct MemoryPressureEvaluator: Sendable, Equatable {
    public static let defaultTransitionIntervalSeconds: TimeInterval = 30

    public let transitionIntervalSeconds: TimeInterval
    public private(set) var stableLevel: MemoryPressureLevel?
    public private(set) var pendingLevel: MemoryPressureLevel?

    private var pendingSince: Date?

    public init(
        transitionIntervalSeconds: TimeInterval = MemoryPressureEvaluator.defaultTransitionIntervalSeconds
    ) {
        self.transitionIntervalSeconds = Self.validatedInterval(transitionIntervalSeconds)
    }

    public var pressureActiveForSampling: Bool {
        isElevated(stableLevel) || isElevated(pendingLevel)
    }

    public mutating func update(snapshot: SystemMemorySnapshot) -> MemoryPressureLevel {
        update(observed: Self.observedLevel(for: snapshot), at: snapshot.timestamp)
    }

    @discardableResult
    public mutating func update(
        observed: MemoryPressureLevel,
        at timestamp: Date
    ) -> MemoryPressureLevel {
        guard let stableLevel else {
            self.stableLevel = observed
            pendingLevel = nil
            pendingSince = nil
            return observed
        }

        guard observed != stableLevel else {
            pendingLevel = nil
            pendingSince = nil
            return stableLevel
        }

        if pendingLevel != observed {
            pendingLevel = observed
            pendingSince = timestamp
            if transitionIntervalSeconds == 0 {
                return commitPendingLevel()
            }
            return stableLevel
        }

        guard let pendingSince else {
            self.pendingSince = timestamp
            return stableLevel
        }

        // A wall-clock adjustment should not make a candidate wait forever.
        if timestamp < pendingSince {
            self.pendingSince = timestamp
            return stableLevel
        }

        if timestamp.timeIntervalSince(pendingSince) >= transitionIntervalSeconds {
            return commitPendingLevel()
        }
        return stableLevel
    }

    public static func observedLevel(for snapshot: SystemMemorySnapshot) -> MemoryPressureLevel {
        if snapshot.availableFraction < 0.10
            || (snapshot.swapTotalBytes > 0 && snapshot.swapFreeBytes < 1 * 1024 * 1024 * 1024)
            || snapshot.throttledPages > 0 {
            return .critical
        }
        if snapshot.availableFraction < 0.20
            || snapshot.compressedBytes > snapshot.totalBytes / 5
            || (snapshot.swapTotalBytes > 0 && snapshot.swapUsedBytes > snapshot.swapTotalBytes / 2) {
            return .attention
        }
        return .normal
    }

    private mutating func commitPendingLevel() -> MemoryPressureLevel {
        let committed = pendingLevel ?? stableLevel ?? .normal
        stableLevel = committed
        pendingLevel = nil
        pendingSince = nil
        return committed
    }

    private static func validatedInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultTransitionIntervalSeconds }
        return max(value, 0)
    }

    private func isElevated(_ level: MemoryPressureLevel?) -> Bool {
        level == .attention || level == .critical
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

    /// Reclaim-aware memory usage represented by this minute-level record.
    /// This is the same estimate used by the live pressure indicator.
    public var usedFraction: Double {
        guard availableFraction.isFinite else { return 0 }
        return min(max(1 - availableFraction, 0), 1)
    }

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

public enum MemoryHistoryEventKind: String, Codable, Sendable, Equatable {
    case pressureTransition
    case swapThreshold
    case workloadAppeared
    case workloadDisappeared
    case workloadGrowth
}

/// An explainable change derived from two adjacent minute-level records.
/// Workload events describe changes in the persisted attribution ranking; they
/// deliberately do not claim that a process was created or terminated.
public struct MemoryHistoryEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let timestamp: Date
    public let kind: MemoryHistoryEventKind
    public let severity: RecommendationSeverity
    public let title: String
    public let detail: String
    public let targetID: String?

    public init(
        id: String,
        timestamp: Date,
        kind: MemoryHistoryEventKind,
        severity: RecommendationSeverity,
        title: String,
        detail: String,
        targetID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.severity = severity
        self.title = title
        self.detail = detail
        self.targetID = targetID
    }
}

public struct MemoryHistoryAnalysis: Sendable, Equatable {
    public let sampleCount: Int
    public let firstTimestamp: Date?
    public let lastTimestamp: Date?
    public let latestUsedFraction: Double?
    public let peakUsedFraction: Double?
    public let latestSwapUsedBytes: UInt64?
    public let peakSwapUsedBytes: UInt64?
    public let pressureTransitionCount: Int
    public let events: [MemoryHistoryEvent]

    public init(
        sampleCount: Int,
        firstTimestamp: Date?,
        lastTimestamp: Date?,
        latestUsedFraction: Double?,
        peakUsedFraction: Double?,
        latestSwapUsedBytes: UInt64?,
        peakSwapUsedBytes: UInt64?,
        pressureTransitionCount: Int,
        events: [MemoryHistoryEvent]
    ) {
        self.sampleCount = max(sampleCount, 0)
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.latestUsedFraction = Self.normalizedFraction(latestUsedFraction)
        self.peakUsedFraction = Self.normalizedFraction(peakUsedFraction)
        self.latestSwapUsedBytes = latestSwapUsedBytes
        self.peakSwapUsedBytes = peakSwapUsedBytes
        self.pressureTransitionCount = max(pressureTransitionCount, 0)
        self.events = events
    }

    public static let empty = MemoryHistoryAnalysis(
        sampleCount: 0,
        firstTimestamp: nil,
        lastTimestamp: nil,
        latestUsedFraction: nil,
        peakUsedFraction: nil,
        latestSwapUsedBytes: nil,
        peakSwapUsedBytes: nil,
        pressureTransitionCount: 0,
        events: []
    )

    public var windowDuration: TimeInterval {
        guard let firstTimestamp, let lastTimestamp else { return 0 }
        let duration = lastTimestamp.timeIntervalSince(firstTimestamp)
        return duration.isFinite ? max(duration, 0) : 0
    }

    public var hasData: Bool { sampleCount > 0 }

    private static func normalizedFraction(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, 0), 1)
    }
}

/// Converts persisted records into a compact, privacy-preserving history
/// explanation. No process APIs or side effects are involved.
public struct MemoryHistoryAnalyzer: Sendable {
    public static let defaultEventLimit = 32
    public static let defaultWorkloadEventThresholdBytes: UInt64 = 64 * 1024 * 1024
    public static let defaultWorkloadGrowthThresholdBytes: UInt64 = 512 * 1024 * 1024
    public static let defaultSwapAttentionThresholdBytes: UInt64 = 1 * 1024 * 1024 * 1024
    public static let defaultSwapCriticalThresholdBytes: UInt64 = 4 * 1024 * 1024 * 1024
    public static let defaultWorkloadTransitionGapSeconds: TimeInterval = 5 * 60

    public let eventLimit: Int
    public let workloadEventThresholdBytes: UInt64
    public let workloadGrowthThresholdBytes: UInt64
    public let swapAttentionThresholdBytes: UInt64
    public let swapCriticalThresholdBytes: UInt64
    public let workloadTransitionGapSeconds: TimeInterval

    public init(
        eventLimit: Int = MemoryHistoryAnalyzer.defaultEventLimit,
        workloadEventThresholdBytes: UInt64 = MemoryHistoryAnalyzer.defaultWorkloadEventThresholdBytes,
        workloadGrowthThresholdBytes: UInt64 = MemoryHistoryAnalyzer.defaultWorkloadGrowthThresholdBytes,
        swapAttentionThresholdBytes: UInt64 = MemoryHistoryAnalyzer.defaultSwapAttentionThresholdBytes,
        swapCriticalThresholdBytes: UInt64 = MemoryHistoryAnalyzer.defaultSwapCriticalThresholdBytes,
        workloadTransitionGapSeconds: TimeInterval = MemoryHistoryAnalyzer.defaultWorkloadTransitionGapSeconds
    ) {
        self.eventLimit = max(eventLimit, 1)
        self.workloadEventThresholdBytes = workloadEventThresholdBytes
        self.workloadGrowthThresholdBytes = max(workloadGrowthThresholdBytes, workloadEventThresholdBytes)
        self.swapAttentionThresholdBytes = swapAttentionThresholdBytes
        self.swapCriticalThresholdBytes = max(swapCriticalThresholdBytes, swapAttentionThresholdBytes)
        self.workloadTransitionGapSeconds = max(
            workloadTransitionGapSeconds.isFinite ? workloadTransitionGapSeconds : 0,
            0
        )
    }

    public func analyze(_ records: [MemoryHistoryRecord]) -> MemoryHistoryAnalysis {
        let normalizedRecords = normalized(records)
        guard let first = normalizedRecords.first, let latest = normalizedRecords.last else {
            return .empty
        }

        let usedFractions = normalizedRecords.map(\.usedFraction)
        let swapValues = normalizedRecords.map(\.swapUsedBytes)
        var events = [MemoryHistoryEvent]()
        var pressureTransitionCount = 0

        if normalizedRecords.count > 1 {
            for index in 1..<normalizedRecords.count {
                let previous = normalizedRecords[index - 1]
                let current = normalizedRecords[index]
                let previousPressure = pressure(for: previous)
                let currentPressure = pressure(for: current)

                if previousPressure != currentPressure {
                    pressureTransitionCount += 1
                    events.append(makePressureEvent(
                        previous: previousPressure,
                        current: currentPressure,
                        record: current
                    ))
                }

                if let swapEvent = makeSwapEvent(previous: previous, current: current) {
                    events.append(swapEvent)
                }

                let gap = current.timestamp.timeIntervalSince(previous.timestamp)
                if gap.isFinite, gap >= 0, gap <= workloadTransitionGapSeconds {
                    events.append(contentsOf: workloadEvents(previous: previous, current: current))
                }
            }
        }

        let sortedEvents = events
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                if $0.severity.priority != $1.severity.priority {
                    return $0.severity.priority > $1.severity.priority
                }
                return $0.id < $1.id
            }
            .prefix(eventLimit)

        return MemoryHistoryAnalysis(
            sampleCount: normalizedRecords.count,
            firstTimestamp: first.timestamp,
            lastTimestamp: latest.timestamp,
            latestUsedFraction: latest.usedFraction,
            peakUsedFraction: usedFractions.max(),
            latestSwapUsedBytes: latest.swapUsedBytes,
            peakSwapUsedBytes: swapValues.max(),
            pressureTransitionCount: pressureTransitionCount,
            events: Array(sortedEvents)
        )
    }

    private func normalized(_ records: [MemoryHistoryRecord]) -> [MemoryHistoryRecord] {
        var byTimestamp = [Date: MemoryHistoryRecord]()
        for record in records {
            guard record.timestamp.timeIntervalSince1970.isFinite else { continue }
            byTimestamp[record.timestamp] = record
        }
        return byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func pressure(for record: MemoryHistoryRecord) -> MemoryPressureLevel {
        // The persisted contract intentionally omits swap capacity and total
        // RAM. Use only the reclaim-aware available fraction here; this avoids
        // treating residual Swap after recovery as an active pressure signal.
        if record.availableFraction < 0.10 { return .critical }
        if record.availableFraction < 0.20 { return .attention }
        return .normal
    }

    private func makePressureEvent(
        previous: MemoryPressureLevel,
        current: MemoryPressureLevel,
        record: MemoryHistoryRecord
    ) -> MemoryHistoryEvent {
        let severity: RecommendationSeverity
        let title: String
        if current == .normal {
            severity = .info
            title = "内存压力恢复正常"
        } else {
            severity = current == .critical ? .critical : .attention
            title = current == .critical ? "内存压力进入严重" : "内存压力进入注意"
        }
        let id = eventID(kind: .pressureTransition, timestamp: record.timestamp, target: current.rawValue)
        let detail = "可回收内存 \(String(format: "%.0f%%", record.availableFraction * 100)) · \(previous.displayName) → \(current.displayName)"
        return MemoryHistoryEvent(
            id: id,
            timestamp: record.timestamp,
            kind: .pressureTransition,
            severity: severity,
            title: title,
            detail: detail
        )
    }

    private func makeSwapEvent(
        previous: MemoryHistoryRecord,
        current: MemoryHistoryRecord
    ) -> MemoryHistoryEvent? {
        let thresholds = [swapCriticalThresholdBytes, swapAttentionThresholdBytes]
        guard let threshold = thresholds.first(where: { threshold in
            (previous.swapUsedBytes < threshold) != (current.swapUsedBytes < threshold)
        }) else {
            return nil
        }
        let increased = current.swapUsedBytes >= threshold
        let severity: RecommendationSeverity = increased
            ? (threshold == swapCriticalThresholdBytes ? .critical : .attention)
            : .info
        let thresholdText = MemoryFormatter.bytes(threshold)
        let title = increased ? "Swap 超过 \(thresholdText)" : "Swap 回落至 \(thresholdText) 以下"
        let detail = "当前 Swap 已用 \(MemoryFormatter.bytes(current.swapUsedBytes))"
        return MemoryHistoryEvent(
            id: eventID(
                kind: .swapThreshold,
                timestamp: current.timestamp,
                target: increased ? "up-\(threshold)" : "down-\(threshold)"
            ),
            timestamp: current.timestamp,
            kind: .swapThreshold,
            severity: severity,
            title: title,
            detail: detail
        )
    }

    private func workloadEvents(
        previous: MemoryHistoryRecord,
        current: MemoryHistoryRecord
    ) -> [MemoryHistoryEvent] {
        let previousByID = workloadDictionary(previous.workloads)
        let currentByID = workloadDictionary(current.workloads)
        var result = [MemoryHistoryEvent]()

        let appeared = currentByID.values
            .filter { previousByID[$0.id] == nil && isActionable($0) }
            .sorted(by: workloadDescending)
        for workload in appeared.prefix(2) {
            result.append(
                MemoryHistoryEvent(
                    id: eventID(kind: .workloadAppeared, timestamp: current.timestamp, target: workload.id),
                    timestamp: current.timestamp,
                    kind: .workloadAppeared,
                    severity: .info,
                    title: "\(workload.title) 进入历史排行",
                    detail: "归因总量 \(MemoryFormatter.bytes(workload.attributedFootprintBytes)) · 仅表示出现在保存的 Top 工作组中",
                    targetID: workload.id
                )
            )
        }

        let disappeared = previousByID.values
            .filter { currentByID[$0.id] == nil && isActionable($0) }
            .sorted(by: workloadDescending)
        for workload in disappeared.prefix(2) {
            result.append(
                MemoryHistoryEvent(
                    id: eventID(kind: .workloadDisappeared, timestamp: current.timestamp, target: workload.id),
                    timestamp: current.timestamp,
                    kind: .workloadDisappeared,
                    severity: .info,
                    title: "\(workload.title) 离开历史排行",
                    detail: "上一分钟归因总量 \(MemoryFormatter.bytes(workload.attributedFootprintBytes)) · 不等同于进程已退出",
                    targetID: workload.id
                )
            )
        }

        if let growth = currentByID.values
            .compactMap({ workload -> (PersistedWorkloadRecord, UInt64)? in
                guard let prior = previousByID[workload.id], isActionable(workload),
                      workload.attributedFootprintBytes > prior.attributedFootprintBytes else {
                    return nil
                }
                let delta = workload.attributedFootprintBytes - prior.attributedFootprintBytes
                return delta >= workloadGrowthThresholdBytes ? (workload, delta) : nil
            })
            .sorted(by: { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.id < rhs.0.id
            })
            .first {
            result.append(
                MemoryHistoryEvent(
                    id: eventID(kind: .workloadGrowth, timestamp: current.timestamp, target: growth.0.id),
                    timestamp: current.timestamp,
                    kind: .workloadGrowth,
                    severity: .attention,
                    title: "\(growth.0.title) 增长明显",
                    detail: "单分钟归因总量增加 \(MemoryFormatter.bytes(growth.1)) · 当前 \(MemoryFormatter.bytes(growth.0.attributedFootprintBytes))",
                    targetID: growth.0.id
                )
            )
        }
        return result
    }

    private func workloadDictionary(
        _ workloads: [PersistedWorkloadRecord]
    ) -> [String: PersistedWorkloadRecord] {
        workloads.reduce(into: [String: PersistedWorkloadRecord]()) { result, workload in
            // A malformed or hand-edited history file may contain duplicate
            // IDs. Keep the last value instead of crashing the analyzer.
            result[workload.id] = workload
        }
    }

    private func isActionable(_ workload: PersistedWorkloadRecord) -> Bool {
        !workload.isSystem
            && !workload.id.hasPrefix("other-")
            && workload.attributedFootprintBytes >= workloadEventThresholdBytes
    }

    private func workloadDescending(_ lhs: PersistedWorkloadRecord, _ rhs: PersistedWorkloadRecord) -> Bool {
        if lhs.attributedFootprintBytes != rhs.attributedFootprintBytes {
            return lhs.attributedFootprintBytes > rhs.attributedFootprintBytes
        }
        return lhs.id < rhs.id
    }

    private func eventID(kind: MemoryHistoryEventKind, timestamp: Date, target: String) -> String {
        let seconds = timestamp.timeIntervalSince1970
        return "\(kind.rawValue)-\(String(format: "%.0f", seconds))-\(target)"
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

/// Runtime storage counters used to verify that history persistence stays
/// lightweight. These values describe local files only; no process identity is
/// included.
public struct HistoryStoreDiagnostics: Sendable, Equatable {
    public let snapshotBytes: Int
    public let journalBytes: Int
    public let pendingRecordCount: Int
    public let journalRecordCount: Int
    public let compactionCount: Int
    public let lastCompactionAt: Date?

    public init(
        snapshotBytes: Int,
        journalBytes: Int,
        pendingRecordCount: Int,
        journalRecordCount: Int,
        compactionCount: Int,
        lastCompactionAt: Date?
    ) {
        self.snapshotBytes = max(snapshotBytes, 0)
        self.journalBytes = max(journalBytes, 0)
        self.pendingRecordCount = max(pendingRecordCount, 0)
        self.journalRecordCount = max(journalRecordCount, 0)
        self.compactionCount = max(compactionCount, 0)
        self.lastCompactionAt = lastCompactionAt
    }

    public var totalBytes: Int {
        let (value, overflow) = snapshotBytes.addingReportingOverflow(journalBytes)
        return overflow ? Int.max : value
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
    public static let defaultCompactionRecordThreshold = 120
    public static let defaultCompactionByteThreshold = 1 * 1024 * 1024

    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent("MemoryMonitor", isDirectory: true)
            .appendingPathComponent("history.json", isDirectory: false)
    }

    public nonisolated let fileURL: URL
    /// A sidecar append-only file. It is intentionally derived from
    /// `fileURL`, so custom/test stores remain self-contained.
    public nonisolated let journalURL: URL
    public let retentionInterval: TimeInterval
    public let maxPersistedWorkloads: Int
    public let compactionRecordThreshold: Int
    public let compactionByteThreshold: Int

    private var records: [MemoryHistoryRecord] = []
    private var hasLoaded = false
    private var dirty = false
    private var lastPersistedMinute: Date?
    private var pendingRecords: [Date: MemoryHistoryRecord] = [:]
    private var journalRecordCount = 0
    private var journalByteCount = 0
    private var snapshotExists = false
    private var compactionCount = 0
    private var lastCompactionAt: Date?

    public init(
        fileURL: URL = HistoryStore.defaultFileURL,
        retentionInterval: TimeInterval = HistoryStore.defaultRetentionInterval,
        maxPersistedWorkloads: Int = HistoryStore.defaultMaxPersistedWorkloads,
        compactionRecordThreshold: Int = HistoryStore.defaultCompactionRecordThreshold,
        compactionByteThreshold: Int = HistoryStore.defaultCompactionByteThreshold
    ) {
        self.fileURL = fileURL
        self.journalURL = URL(fileURLWithPath: fileURL.path + ".journal")
        self.retentionInterval = max(retentionInterval, 0)
        self.maxPersistedWorkloads = max(maxPersistedWorkloads, 1)
        self.compactionRecordThreshold = max(compactionRecordThreshold, 1)
        self.compactionByteThreshold = max(compactionByteThreshold, 1)
    }

    public func diagnostics() -> HistoryStoreDiagnostics {
        HistoryStoreDiagnostics(
            snapshotBytes: byteCount(at: fileURL),
            journalBytes: byteCount(at: journalURL),
            pendingRecordCount: pendingRecords.count,
            journalRecordCount: journalRecordCount,
            compactionCount: compactionCount,
            lastCompactionAt: lastCompactionAt
        )
    }

    @discardableResult
    public func load(now: Date = Date()) throws -> [MemoryHistoryRecord] {
        guard !hasLoaded else {
            let before = records
            records = Self.pruned(coalesced(records), now: now, retentionInterval: retentionInterval)
            if records != before {
                dirty = true
                try compactSnapshot(at: now)
            }
            return records
        }

        let fileManager = FileManager.default
        let hasSnapshot = fileManager.fileExists(atPath: fileURL.path)
        let hasJournal = fileManager.fileExists(atPath: journalURL.path)
        var snapshotRecords: [MemoryHistoryRecord] = []
        var snapshotData = Data()

        if hasSnapshot {
            do {
                snapshotData = try Data(contentsOf: fileURL)
            } catch {
                throw HistoryStoreError.readFailed
            }

            do {
                let file = try Self.decoder().decode(MemoryHistoryFile.self, from: snapshotData)
                guard file.version == MemoryHistoryFile.currentVersion else {
                    throw HistoryStoreError.unsupportedVersion(file.version)
                }
                snapshotRecords = file.records
            } catch let error as HistoryStoreError {
                throw error
            } catch {
                throw HistoryStoreError.invalidData
            }
        }

        var journalRecords: [MemoryHistoryRecord] = []
        var journalData = Data()
        if hasJournal {
            do {
                journalData = try Data(contentsOf: journalURL)
            } catch {
                throw HistoryStoreError.readFailed
            }
            let decodedJournal = try decodeJournal(journalData)
            journalRecords = decodedJournal.records
            if decodedJournal.validByteCount < journalData.count {
                do {
                    journalData = Data(journalData.prefix(decodedJournal.validByteCount))
                    try journalData.write(to: journalURL, options: [.atomic])
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: journalURL.path
                    )
                } catch {
                    throw HistoryStoreError.writeFailed
                }
            }
        }

        let coalescedRecords = coalesced(snapshotRecords + journalRecords)
        records = Self.pruned(coalescedRecords, now: now, retentionInterval: retentionInterval)
        hasLoaded = true
        snapshotExists = hasSnapshot
        journalRecordCount = journalRecords.count
        journalByteCount = journalData.count
        pendingRecords.removeAll(keepingCapacity: false)
        dirty = false
        lastPersistedMinute = records.last?.timestamp

        let canonicalSnapshot: Data
        do {
            canonicalSnapshot = try Self.encoder().encode(MemoryHistoryFile(records: coalescedRecords))
        } catch {
            throw HistoryStoreError.invalidData
        }
        let needsCompaction = (!hasSnapshot && !journalRecords.isEmpty)
            || (records != coalescedRecords)
            || (hasSnapshot && !hasJournal && snapshotData != canonicalSnapshot)
        if needsCompaction {
            try compactSnapshot(at: now)
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
        pendingRecords[normalized.timestamp] = normalized

        // The first sample creates a compact snapshot. Later samples append a
        // single line when the minute changes; updates within one minute stay
        // in memory until the next boundary or an explicit flush.
        let removedExpiredRecords = records.count < sortedRecords.count
        if !snapshotExists {
            try compactSnapshot(at: now)
        } else if lastPersistedMinute != normalized.timestamp || removedExpiredRecords {
            try appendPending(at: now)
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
            pendingRecords = pendingRecords.filter { records.contains($0.value) }
            try compactSnapshot(at: now)
        }
        return records
    }

    public func flush() throws {
        guard hasLoaded else { return }
        if !pendingRecords.isEmpty {
            try appendPending(at: Date())
        }
        guard dirty || journalRecordCount > 0 else { return }
        try compactSnapshot(at: Date())
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct JournalDecodeResult {
        let records: [MemoryHistoryRecord]
        let validByteCount: Int
    }

    private func decodeJournal(_ data: Data) throws -> JournalDecodeResult {
        guard !data.isEmpty else {
            return JournalDecodeResult(records: [], validByteCount: 0)
        }

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let decoder = Self.decoder()
        var decoded = [MemoryHistoryRecord]()
        var ignoredIncompleteTail = false
        for index in lines.indices {
            let line = lines[index]
            guard !line.isEmpty else { continue }
            do {
                decoded.append(try decoder.decode(MemoryHistoryRecord.self, from: Data(line)))
            } catch {
                // A process may be terminated while the final line is being
                // appended. Ignore only that incomplete tail; malformed data
                // in a complete or middle line still invalidates the store.
                let isLastLine = index == lines.index(before: lines.endIndex)
                if isLastLine, data.last != 0x0A {
                    ignoredIncompleteTail = true
                    break
                }
                throw HistoryStoreError.invalidData
            }
        }
        let validByteCount: Int
        if ignoredIncompleteTail, let lastNewline = data.lastIndex(of: 0x0A) {
            validByteCount = data.distance(from: data.startIndex, to: lastNewline) + 1
        } else if ignoredIncompleteTail {
            validByteCount = 0
        } else {
            validByteCount = data.count
        }
        return JournalDecodeResult(records: decoded, validByteCount: validByteCount)
    }

    private func appendPending(at timestamp: Date) throws {
        guard !pendingRecords.isEmpty else { return }

        let ordered = pendingRecords.values.sorted { $0.timestamp < $1.timestamp }
        var payload = Data()
        do {
            let encoder = Self.encoder()
            for record in ordered {
                payload.append(try encoder.encode(record))
                payload.append(0x0A)
            }

            try prepareDirectory()
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: journalURL.path) {
                let handle = try FileHandle(forWritingTo: journalURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
                try handle.synchronize()
            } else {
                try payload.write(to: journalURL, options: [.atomic])
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: journalURL.path
            )
        } catch {
            throw HistoryStoreError.writeFailed
        }

        journalRecordCount += ordered.count
        journalByteCount += payload.count
        pendingRecords.removeAll(keepingCapacity: false)
        dirty = false
        lastPersistedMinute = records.last?.timestamp

        if journalRecordCount >= compactionRecordThreshold
            || journalByteCount >= compactionByteThreshold {
            try compactSnapshot(at: timestamp)
        }
    }

    private func compactSnapshot(at timestamp: Date) throws {
        let fileManager = FileManager.default
        do {
            try prepareDirectory()
            let data = try Self.encoder().encode(MemoryHistoryFile(records: records))
            // Keep the canonical snapshot atomic. If the process stops during
            // this write, the previous snapshot and journal remain readable.
            try data.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )

            // Truncating the sidecar only after the snapshot is in place makes
            // a crash recoverable: an old journal merely contributes duplicate
            // minute records, which `coalesced` resolves on the next load.
            if fileManager.fileExists(atPath: journalURL.path) {
                try Data().write(to: journalURL, options: [.atomic])
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: journalURL.path
                )
            }
        } catch {
            throw HistoryStoreError.writeFailed
        }

        snapshotExists = true
        pendingRecords.removeAll(keepingCapacity: false)
        dirty = false
        journalRecordCount = 0
        journalByteCount = 0
        lastPersistedMinute = records.last?.timestamp
        compactionCount += 1
        lastCompactionAt = timestamp
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func byteCount(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.size] as? NSNumber else {
            return 0
        }
        return max(value.intValue, 0)
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
