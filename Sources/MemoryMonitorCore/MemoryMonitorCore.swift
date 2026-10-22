import Darwin
import CryptoKit
import Foundation
import IOKit

// JSONEncoder's ISO-8601 strategy is not a lossless representation for the
// full range accepted by `Date`. Keep persisted timestamps inside the range
// supported by the formatter and reject pathological values before they can
// affect retention arithmetic or ordering.
private let minimumPersistableUnixSeconds = -62_135_596_800.0 // 0001-01-01
private let maximumPersistableUnixSeconds = 253_402_300_799.0 // 9999-12-31
// Kernel process start times are Unix seconds. Keep the integer form beside
// the persisted Date bounds so malformed UInt64 values cannot become a
// finite-but-absurd Date after conversion through Double.
private let maximumProcessStartTimeSeconds: UInt64 = 253_402_300_799

private enum PersistedDataLimit {
    static let clockBytes = 16 * 1024
    static let jsonNestingDepth = 64
}

private func isPersistableDate(_ date: Date) -> Bool {
    let seconds = date.timeIntervalSince1970
    return seconds.isFinite
        && seconds >= minimumPersistableUnixSeconds
        && seconds <= maximumPersistableUnixSeconds
}

private func isWithinFutureSkew(_ date: Date, now: Date, allowance: TimeInterval) -> Bool {
    guard isPersistableDate(date), isPersistableDate(now), allowance.isFinite, allowance >= 0 else {
        return false
    }
    let limit = now.timeIntervalSince1970 + allowance
    guard limit.isFinite else { return false }
    return date.timeIntervalSince1970 <= limit
}

/// A tiny sidecar anchor lets retention survive a wall-clock rollback across
/// process restarts without treating an arbitrary maximum record timestamp as
/// trustworthy. It is written only after the caller has validated `now`.
private struct PersistedClockAnchor: Codable {
    let observedAt: Date
}

private func persistedJSONEncoder(sortedKeys: Bool = false) -> JSONEncoder {
    let encoder = JSONEncoder()
    let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(format.format(date))
    }
    if sortedKeys {
        encoder.outputFormatting = [.sortedKeys]
    }
    return encoder
}

private func persistedJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let legacy = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if let date = try? fractional.parse(value) {
            return date
        }
        guard let date = try? legacy.parse(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid RFC 3339 timestamp"
            )
        }
        return date
    }
    return decoder
}

private func clockAnchorData(for date: Date) throws -> Data {
    let encoder = persistedJSONEncoder(sortedKeys: true)
    return try encoder.encode(PersistedClockAnchor(observedAt: date))
}

private func readClockAnchor(at url: URL) -> Date? {
    guard let data = try? readBoundedFile(
        at: url,
        maximumBytes: PersistedDataLimit.clockBytes
    ), !data.isEmpty else { return nil }
    let decoder = persistedJSONDecoder()
    guard let anchor = try? decoder.decode(PersistedClockAnchor.self, from: data),
          isPersistableDate(anchor.observedAt) else {
        return nil
    }
    return anchor.observedAt
}

private func boundedRetentionReference(
    now: Date,
    anchor: Date?,
    rollbackLimit: TimeInterval
) -> Date {
    guard isPersistableDate(now),
          rollbackLimit.isFinite,
          rollbackLimit >= 0 else {
        return now
    }
    guard let anchor, isPersistableDate(anchor) else { return now }
    let delta = anchor.timeIntervalSince(now)
    guard delta.isFinite, delta > 0, delta <= rollbackLimit else { return now }
    return anchor
}

private enum PersistedFileLockError: Error {
    case openFailed
    case lockFailed
    case timedOut
    case cancelled
}

private enum BoundedFileReadError: Error {
    case readFailed
    case tooLarge
}

private struct PersistedFileGeneration: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

private func persistedFileGeneration(at url: URL) throws -> PersistedFileGeneration? {
    let descriptor = url.path.withCString { path in
        open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    }
    if descriptor < 0 {
        if errno == ENOENT { return nil }
        throw BoundedFileReadError.readFailed
    }
    defer { close(descriptor) }

    var information = stat()
    if fstat(descriptor, &information) != 0 {
        throw BoundedFileReadError.readFailed
    }
    guard information.st_size >= 0 else {
        throw BoundedFileReadError.readFailed
    }
    return PersistedFileGeneration(
        device: UInt64(information.st_dev),
        inode: UInt64(information.st_ino),
        size: UInt64(information.st_size),
        modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
        modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec)
    )
}

private func validateFileSize(at url: URL, maximumBytes: Int) throws {
    guard maximumBytes >= 0 else { throw BoundedFileReadError.tooLarge }
    guard let generation = try persistedFileGeneration(at: url) else { return }
    guard generation.size <= UInt64(maximumBytes) else {
        throw BoundedFileReadError.tooLarge
    }
}

private func readBoundedFile(at url: URL, maximumBytes: Int) throws -> Data {
    let descriptor = url.path.withCString { path in
        open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
    }
    guard descriptor >= 0 else { throw BoundedFileReadError.readFailed }
    defer { close(descriptor) }

    var information = stat()
    guard fstat(descriptor, &information) == 0,
          information.st_size >= 0 else {
        throw BoundedFileReadError.readFailed
    }
    guard UInt64(information.st_size) <= UInt64(max(maximumBytes, 0)) else {
        throw BoundedFileReadError.tooLarge
    }

    var data = Data()
    data.reserveCapacity(min(maximumBytes, 64 * 1024))
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count == 0 { return data }
        if count < 0 {
            if errno == EINTR { continue }
            throw BoundedFileReadError.readFailed
        }
        guard data.count <= maximumBytes - count else {
            throw BoundedFileReadError.tooLarge
        }
        data.append(contentsOf: buffer.prefix(count))
    }
}

private func fileEndsWithNewline(at url: URL) -> Bool {
    let descriptor = url.path.withCString { path in
        open(path, O_RDONLY | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    let end = lseek(descriptor, 0, SEEK_END)
    guard end >= 0 else { return false }
    if end == 0 { return true }
    guard lseek(descriptor, -1, SEEK_END) >= 0 else { return false }
    var byte: UInt8 = 0
    return read(descriptor, &byte, 1) == 1 && byte == 0x0A
}

/// Serializes read-modify-write transactions for stores that may be opened by
/// multiple actors or processes. Actor isolation alone only protects one
/// instance, so every durable operation must also hold this path-level lock.
private func acquireExclusivePersistedFileLock(
    at url: URL,
    timeoutSeconds: TimeInterval = 2
) throws -> Int32 {
    let fileManager = FileManager.default
    let directory = url.deletingLastPathComponent()
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        throw PersistedFileLockError.openFailed
    }

    let descriptor = url.path.withCString { path in
        open(path, O_RDWR | O_CREAT | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
    }
    guard descriptor >= 0 else {
        throw PersistedFileLockError.openFailed
    }
    var releaseOnFailure = true
    defer {
        if releaseOnFailure {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    let clock = ContinuousClock()
    let timeout = timeoutSeconds.isFinite && timeoutSeconds >= 0
        ? timeoutSeconds
        : 0
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while true {
        if withUnsafeCurrentTask(body: { $0?.isCancelled == true }) {
            throw PersistedFileLockError.cancelled
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
            break
        }
        if errno == EINTR { continue }
        guard errno == EWOULDBLOCK || errno == EAGAIN else {
            throw PersistedFileLockError.lockFailed
        }
        guard clock.now < deadline else {
            throw PersistedFileLockError.timedOut
        }
        usleep(10_000)
    }
    // A custom path may already contain a lock file created with broad
    // permissions. Tighten it while holding the lock before any data access.
    do {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    } catch {
        throw PersistedFileLockError.lockFailed
    }
    releaseOnFailure = false
    return descriptor
}

private func releaseExclusivePersistedFileLock(_ descriptor: Int32) {
    _ = flock(descriptor, LOCK_UN)
    close(descriptor)
}

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

    /// Whether this status describes a captured value with a representable
    /// wall-clock timestamp. A usable quality without a timestamp is not
    /// enough to establish freshness or to become a process baseline.
    public var hasFiniteSampleTimestamp: Bool {
        guard quality.isUsable, let sampledAt else { return false }
        return sampledAt.timeIntervalSince1970.isFinite
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
        guard let available = rawAvailableEstimateBytes else { return 0 }
        return min(totalBytes, available)
    }

    /// The arithmetic behind `availableEstimateBytes` is intentionally
    /// checked. A malformed provider value must not turn an overflow into a
    /// believable "all memory is available" result.
    private var rawAvailableEstimateBytes: UInt64? {
        // Darwin's free_count already includes speculative pages. Counting it
        // again would overstate the amount that can be made available.
        let (freeAndInactive, firstOverflow) = freeBytes.addingReportingOverflow(inactiveBytes)
        let (available, secondOverflow) = freeAndInactive.addingReportingOverflow(purgeableBytes)
        guard !firstOverflow, !secondOverflow else { return nil }
        return available
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
        totalBytes > 0
            && pageSize > 0
            && timestamp.timeIntervalSince1970.isFinite
            && rawAvailableEstimateBytes != nil
            && swapUsedBytes <= swapTotalBytes
            && swapFreeBytes <= swapTotalBytes
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

    /// Mach reports the number of integer_t fields it actually populated.
    /// Reading a partially filled struct would otherwise silently consume
    /// zero-initialized fields as real measurements.
    static func hasSufficientStatisticsCount(
        actual: mach_msg_type_number_t,
        expected: mach_msg_type_number_t
    ) -> Bool {
        actual >= expected
    }

    /// Multiplies a kernel page count without allowing malformed provider
    /// data to trap the sampler with a Swift integer-overflow fatal error.
    /// Kept internal so boundary tests can exercise the arithmetic directly.
    static func checkedPageBytes(_ pages: UInt64, pageSize: UInt64) -> UInt64? {
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow ? nil : bytes
    }

    /// `sysctlbyname` reports the number of bytes actually copied through its
    /// length argument. Accepting a short payload would make zero-initialized
    /// tail fields look like real kernel values.
    static func hasExpectedSysctlByteCount(actual: Int, expected: Int) -> Bool {
        expected > 0 && actual == expected
    }

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
        let expectedCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        guard Self.hasSufficientStatisticsCount(actual: count, expected: expectedCount) else {
            throw MemoryMonitorError.invalidData(description: "host_statistics64 返回的字段数量不足")
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapStatus = withUnsafeMutablePointer(to: &swap) { pointer in
            "vm.swapusage".withCString { name in
                sysctlbyname(name, pointer, &swapSize, nil, 0)
            }
        }
        let swapError = Int32(Darwin.errno)
        guard swapStatus == 0 else {
            throw MemoryMonitorError.systemCall(name: "sysctl(vm.swapusage)", code: swapError)
        }
        guard Self.hasExpectedSysctlByteCount(
            actual: swapSize,
            expected: MemoryLayout<xsw_usage>.size
        ) else {
            throw MemoryMonitorError.invalidData(
                description: "sysctl(vm.swapusage) 返回的数据大小异常"
            )
        }

        let pageBytes = UInt64(pageSize)
        let totalBytes = try sysctlUInt64(named: "hw.memsize")
        guard pageBytes > 0, totalBytes > 0 else {
            throw MemoryMonitorError.invalidData(description: "系统内存采样返回了无效的总量或页大小")
        }
        func bytes(for pages: UInt64, field: String) throws -> UInt64 {
            guard let value = Self.checkedPageBytes(pages, pageSize: pageBytes) else {
                throw MemoryMonitorError.invalidData(description: "系统内存采样的 \(field) 数值溢出")
            }
            return value
        }
        return SystemMemorySnapshot(
            totalBytes: totalBytes,
            pageSize: pageBytes,
            freeBytes: try bytes(for: UInt64(statistics.free_count), field: "free_count"),
            activeBytes: try bytes(for: UInt64(statistics.active_count), field: "active_count"),
            inactiveBytes: try bytes(for: UInt64(statistics.inactive_count), field: "inactive_count"),
            speculativeBytes: try bytes(for: UInt64(statistics.speculative_count), field: "speculative_count"),
            wiredBytes: try bytes(for: UInt64(statistics.wire_count), field: "wire_count"),
            purgeableBytes: try bytes(for: UInt64(statistics.purgeable_count), field: "purgeable_count"),
            compressedBytes: try bytes(for: UInt64(statistics.compressor_page_count), field: "compressor_page_count"),
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

    static func hasSufficientStatisticsCount(
        actual: mach_msg_type_number_t,
        expected: mach_msg_type_number_t
    ) -> Bool {
        actual >= expected
    }

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
        let expectedCount = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        guard Self.hasSufficientStatisticsCount(actual: count, expected: expectedCount) else {
            throw MemoryMonitorError.invalidData(description: "host_statistics 返回的字段数量不足")
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
        let normalizedFraction: Double?
        if let fraction {
            guard fraction.isFinite, (0...1).contains(fraction) else {
                self.fraction = nil
                self.status = .error("GPU 利用率数据无效")
                return
            }
            normalizedFraction = fraction
        } else {
            normalizedFraction = nil
        }

        guard status.quality.isUsable else {
            // A value without a usable status must never be consumed as a
            // current metric. Keep the status as the diagnostic source of
            // truth and discard a caller-supplied stale fraction.
            self.fraction = nil
            self.status = status
            return
        }
        guard status.hasFiniteSampleTimestamp else {
            self.fraction = nil
            self.status = .error("GPU 采样时间无效")
            return
        }
        guard normalizedFraction != nil else {
            self.fraction = nil
            self.status = .unavailable(message: status.message ?? "GPU 利用率不可用")
            return
        }
        self.fraction = normalizedFraction
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

    /// Whether the identity can have come from the kernel's process table.
    /// This is deliberately structural rather than wall-clock based so a
    /// captured snapshot remains usable after a clock adjustment.
    public var isStructurallyValid: Bool {
        pid > 0
            && startTimeSeconds > 0
            && startTimeSeconds <= maximumProcessStartTimeSeconds
            && startTimeMicroseconds < 1_000_000
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
        sanitizedDisplayText(component, limit: maxLength)
    }

    /// Cleans arbitrary persisted display text (for example workload IDs and
    /// titles read from an older or hand-edited history file). It removes
    /// control and bidi/invisible scalars, replaces path separators, collapses
    /// whitespace and applies an explicit length limit.
    public static func sanitizedDisplayText(
        _ value: String,
        limit: Int = 256
    ) -> String? {
        var filtered = ""
        for scalar in value.unicodeScalars {
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

        let safeLimit = max(limit, 1)
        let limited = String(collapsed.prefix(safeLimit))
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
        guard identity.isStructurallyValid else { return nil }
        let seconds = Double(identity.startTimeSeconds)
            + Double(identity.startTimeMicroseconds) / 1_000_000
        guard seconds.isFinite,
              seconds <= maximumPersistableUnixSeconds else { return nil }
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
        if lhs.identity.pid != rhs.identity.pid {
            return lhs.identity.pid < rhs.identity.pid
        }
        // PID is only unique while a process is alive. Include the captured
        // start instant (and sanitized labels as a final fallback) so hand-
        // crafted or rapidly changing snapshots still sort deterministically.
        if lhs.identity.startTimeSeconds != rhs.identity.startTimeSeconds {
            return lhs.identity.startTimeSeconds < rhs.identity.startTimeSeconds
        }
        if lhs.identity.startTimeMicroseconds != rhs.identity.startTimeMicroseconds {
            return lhs.identity.startTimeMicroseconds < rhs.identity.startTimeMicroseconds
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return (lhs.executablePath ?? "") < (rhs.executablePath ?? "")
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
        self.name = WorkingDirectoryLabelSanitizer.label(fromComponent: name) ?? "(unknown)"
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

public enum ProcessActionKind: String, Codable, Sendable, Equatable {
    case gracefulExit
    case forceTerminate

    public var displayName: String {
        switch self {
        case .gracefulExit: return "优雅退出"
        case .forceTerminate: return "强制结束"
        }
    }
}

public enum ProcessActionOutcome: String, Codable, Sendable, Equatable {
    case completed
    case timedOut
    case denied
    case failed
    case cancelled

    public var displayName: String {
        switch self {
        case .completed: return "已完成"
        case .timedOut: return "等待超时"
        case .denied: return "已拒绝"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

/// Lifecycle stage of a process-action audit record. Older JSONL records did
/// not carry a stage and are decoded as terminal results.
public enum ProcessActionAuditPhase: String, Codable, Sendable, Equatable {
    case intent
    case signalSent
    case terminal

    public var displayName: String {
        switch self {
        case .intent: return "已确认"
        case .signalSent: return "已发送"
        case .terminal: return "最终结果"
        }
    }
}

public enum ProcessActionBlockReason: String, Codable, Sendable, Equatable {
    case missingSnapshot
    case invalidIdentity
    case identityChanged
    case userMismatch
    case protectedProcess
    case selfProcess
    case executablePathUnavailable
    case executablePathChanged
    case parentUnavailable
    case parentChanged
    case kernelIdentityUnavailable

    public var displayMessage: String {
        switch self {
        case .missingSnapshot:
            return "无法重新读取进程，进程可能已退出或受到权限限制。"
        case .invalidIdentity:
            return "无法确认进程的有效 PID 或启动时间，已拒绝操作。"
        case .identityChanged:
            return "进程启动身份已变化，已拒绝继续操作。"
        case .userMismatch:
            return "只允许操作当前登录用户的进程。"
        case .protectedProcess:
            return "系统或受保护进程不可操作。"
        case .selfProcess:
            return "不会操作 Memory Monitor 自身。"
        case .executablePathUnavailable:
            return "无法确认可执行路径，已拒绝操作。"
        case .executablePathChanged:
            return "可执行路径在确认前发生变化，已拒绝操作。"
        case .parentUnavailable:
            return "无法确认父进程关系，已拒绝操作。"
        case .parentChanged:
            return "父进程关系在确认前发生变化，已拒绝操作。"
        case .kernelIdentityUnavailable:
            return "无法建立内核绑定的进程身份，已拒绝强制结束。"
        }
    }
}

/// Result of the final identity and safety check immediately before sending
/// a termination request. A missing or changed field is a hard denial.
public struct ProcessActionValidation: Codable, Sendable, Equatable {
    public let allowed: Bool
    public let reason: ProcessActionBlockReason?
    public let message: String

    public init(
        allowed: Bool,
        reason: ProcessActionBlockReason? = nil,
        message: String
    ) {
        self.allowed = allowed
        self.reason = reason
        self.message = message
    }

    public static let allowedResult = ProcessActionValidation(
        allowed: true,
        message: "已通过身份和安全校验。"
    )

    public static func denied(_ reason: ProcessActionBlockReason) -> ProcessActionValidation {
        ProcessActionValidation(
            allowed: false,
            reason: reason,
            message: reason.displayMessage
        )
    }
}

/// Conservative policy for process controls. It intentionally rejects
/// uncertain data instead of trying to infer whether a PID is safe to reuse.
public struct ProcessActionPolicy: Sendable, Equatable {
    public let currentUserID: UInt32
    public let monitorPID: Int32?

    public init(currentUserID: UInt32, monitorPID: Int32? = nil) {
        self.currentUserID = currentUserID
        self.monitorPID = monitorPID
    }

    public func validate(
        expected: ProcessSnapshot,
        current: ProcessSnapshot?
    ) -> ProcessActionValidation {
        guard let current else {
            return .denied(.missingSnapshot)
        }
        guard Self.isValidIdentity(expected.identity),
              Self.isValidIdentity(current.identity) else {
            return .denied(.invalidIdentity)
        }
        guard expected.identity == current.identity else {
            return .denied(.identityChanged)
        }
        guard expected.userID != 0, current.userID != 0 else {
            return .denied(.protectedProcess)
        }
        guard expected.userID == current.userID, current.userID == currentUserID else {
            return .denied(.userMismatch)
        }
        guard !expected.isSystem, !current.isSystem else {
            return .denied(.protectedProcess)
        }
        if let monitorPID, current.identity.pid == monitorPID {
            return .denied(.selfProcess)
        }
        guard expected.parentPID > 0, current.parentPID > 0 else {
            return .denied(.parentUnavailable)
        }
        guard expected.parentPID == current.parentPID else {
            return .denied(.parentChanged)
        }
        guard let expectedPath = expected.executablePath,
              let currentPath = current.executablePath,
              expectedPath.hasPrefix("/"),
              currentPath.hasPrefix("/"),
              !expectedPath.isEmpty,
              !currentPath.isEmpty else {
            return .denied(.executablePathUnavailable)
        }
        guard Self.normalizedPath(expectedPath) == Self.normalizedPath(currentPath) else {
            return .denied(.executablePathChanged)
        }
        guard !Self.isProtected(process: current) else {
            return .denied(.protectedProcess)
        }
        return .allowedResult
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func isValidIdentity(_ identity: ProcessIdentity) -> Bool {
        identity.isStructurallyValid
    }

    private static func isProtected(process: ProcessSnapshot) -> Bool {
        let name = process.name.lowercased()
        let executable = normalizedPath(process.executablePath ?? "").lowercased()
        let bundleID = process.bundleIdentifier?.lowercased()
        if let bundleID, protectedBundleIdentifiers.contains(bundleID) {
            return true
        }
        if protectedNames.contains(name) {
            return true
        }
        return protectedPathPrefixes.contains { executable.hasPrefix($0) }
    }

    /// Bundle identifiers are the stable identity for shell and security
    /// agents. Name-only checks are kept as a fallback for processes whose
    /// bundle metadata is unavailable, but they are deliberately not the
    /// primary protection mechanism.
    private static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.windowserver",
        "com.apple.loginwindow",
        "com.apple.runningboardd",
        "com.apple.tccd",
        "com.apple.securityd",
        "com.apple.cfprefsd",
        "com.apple.securityagent",
        "com.apple.systemsettings",
        "com.apple.systempreferences"
    ]

    private static let protectedNames: Set<String> = [
        "kernel_task",
        "launchd",
        "windowserver",
        "controlcenter",
        "runningboardd",
        "loginwindow",
        "memory-monitor-app",
        "finder",
        "dock",
        "systemuiserver",
        "notificationcenter",
        "securityagent",
        "tccd",
        "securityd",
        "cfprefsd"
    ]

    private static let protectedPathPrefixes = [
        "/system/",
        "/system/library/core services/",
        "/system/library/launchservices/",
        "/usr/libexec/",
        "/private/var/db/"
    ]
}

/// A privacy-preserving record of a user-confirmed action attempt. Process
/// IDs, start times, command lines and paths are deliberately absent. The
/// operation ID links the intent, signal-sent, and terminal records without
/// exposing process identity.
public struct ProcessActionAuditEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let operationID: String
    public let timestamp: Date
    public let action: ProcessActionKind
    public let phase: ProcessActionAuditPhase
    public let outcome: ProcessActionOutcome
    public let processLabel: String
    public let applicationName: String?
    public let detail: String

    public var statusDisplayName: String {
        phase == .terminal ? outcome.displayName : phase.displayName
    }

    public init(
        id: String = UUID().uuidString,
        operationID: String? = nil,
        timestamp: Date = Date(),
        action: ProcessActionKind,
        phase: ProcessActionAuditPhase = .terminal,
        outcome: ProcessActionOutcome,
        processLabel: String,
        applicationName: String? = nil,
        detail: String
    ) {
        self.id = String(id.prefix(80))
        self.operationID = String((operationID ?? id).prefix(80))
        self.timestamp = timestamp
        self.action = action
        self.phase = phase
        self.outcome = outcome
        self.processLabel = WorkingDirectoryLabelSanitizer.label(fromComponent: processLabel) ?? "未知进程"
        self.applicationName = applicationName.flatMap(WorkingDirectoryLabelSanitizer.label(fromComponent:))
        self.detail = Self.sanitizedDetail(detail)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case operationID
        case timestamp
        case action
        case phase
        case outcome
        case processLabel
        case applicationName
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let operationID = try container.decodeIfPresent(String.self, forKey: .operationID) ?? id
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let processLabel = try container.decode(String.self, forKey: .processLabel)
        let applicationName = try container.decodeIfPresent(String.self, forKey: .applicationName)
        let detail = try container.decode(String.self, forKey: .detail)
        let decoded = Self(
            id: id,
            operationID: operationID,
            timestamp: timestamp,
            action: try container.decode(ProcessActionKind.self, forKey: .action),
            phase: try container.decodeIfPresent(ProcessActionAuditPhase.self, forKey: .phase) ?? .terminal,
            outcome: try container.decode(ProcessActionOutcome.self, forKey: .outcome),
            processLabel: processLabel,
            applicationName: applicationName,
            detail: detail
        )
        guard decoded.hasValidPersistedFields else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "Audit event contains invalid persisted fields"
            )
        }
        self = decoded
    }

    fileprivate var hasValidPersistedFields: Bool {
        Self.hasValidPersistedFields(
            id: id,
            operationID: operationID,
            timestamp: timestamp,
            phase: phase,
            processLabel: processLabel,
            applicationName: applicationName,
            detail: detail
        )
    }

    private static func hasValidPersistedFields(
        id: String,
        operationID: String,
        timestamp: Date,
        phase: ProcessActionAuditPhase,
        processLabel: String,
        applicationName: String?,
        detail: String
    ) -> Bool {
        let idIsValid = !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && id.count <= 80
            && Self.hasNoControlCharacters(id)
        let operationIDIsValid = !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && operationID.count <= 80
            && Self.hasNoControlCharacters(operationID)
        let processLabelIsValid = !processLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.hasNoControlCharacters(processLabel)
        let applicationNameIsValid = applicationName.map {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && Self.hasNoControlCharacters($0)
        } ?? true
        let detailIsValid = !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Self.hasNoControlCharacters(detail)
        return idIsValid
            && operationIDIsValid
            && isPersistableDate(timestamp)
            && processLabelIsValid
            && applicationNameIsValid
            && detailIsValid
    }

    private static func hasNoControlCharacters(_ value: String) -> Bool {
        !value.unicodeScalars.contains { scalar in
            let code = scalar.value
            return code < 0x20 || (0x7F...0x9F).contains(code)
        }
    }

    private static func sanitizedDetail(_ value: String) -> String {
        let filtered = value.unicodeScalars.filter { scalar in
            let code = scalar.value
            return !(code < 0x20 || (0x7F...0x9F).contains(code))
        }
        var sanitized = String(String.UnicodeScalarView(filtered))

        // Details are generated by the app today, but keep the storage type
        // defensive if a future caller accidentally passes an identity value.
        // Redact absolute paths and explicit PID labels before truncating.
        sanitized = sanitized.replacingOccurrences(
            of: #"(?i)\bpid\s*[:#]?\s*\d+\b"#,
            with: "PID [已隐藏]",
            options: .regularExpression
        )
        sanitized = sanitized.replacingOccurrences(
            of: #"(?<![A-Za-z0-9_])/(?:[^\s/]+/)*[^\s]+"#,
            with: "[路径已隐藏]",
            options: .regularExpression
        )
        return String(sanitized.prefix(240))
    }
}

public enum ProcessReadFailure: String, Sendable, Equatable {
    case permissionDenied, disappeared, unstableIdentity, unavailable
}

public struct ProcessReadDiagnostic: Sendable, Equatable {
    public let pid: Int32
    public let parentPID: Int32?
    public let userID: UInt32?
    public let executablePath: String?
    public let reason: ProcessReadFailure

    public init(pid: Int32, parentPID: Int32? = nil, userID: UInt32? = nil,
                executablePath: String? = nil, reason: ProcessReadFailure) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.executablePath = executablePath
        self.reason = reason
    }
}

public struct ProcessSamplingResult: Sendable, Equatable {
    public static let minimumUsableCoverage = 0.5

    public let processes: [ProcessSnapshot]
    public let listedProcessCount: Int
    public let sampledProcessCount: Int
    public let skippedProcessCount: Int
    public let status: SampleStatus
    public let readFailures: [ProcessReadDiagnostic]
    public var permissionDeniedProcessCount: Int {
        min(readFailures.filter { $0.reason == .permissionDenied }.count,
            listedProcessCount - sampledProcessCount)
    }

    public init(
        processes: [ProcessSnapshot],
        listedProcessCount: Int,
        sampledProcessCount: Int,
        skippedProcessCount: Int,
        status: SampleStatus,
        readFailures: [ProcessReadDiagnostic] = []
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
        let sampledPIDs = Set(processes.map(\.identity.pid))
        var seenPIDs = Set<Int32>()
        self.readFailures = readFailures.filter {
            $0.pid > 0 && !sampledPIDs.contains($0.pid) && seenPIDs.insert($0.pid).inserted
        }
    }

    /// A scan may return a technically valid but nearly empty list when most
    /// processes disappear during enumeration. Only proven OS permission
    /// denials are excluded from the refresh denominator; missing/unstable
    /// reads still prevent an unreliable scan replacing the last good rows.
    public var isUsable: Bool {
        guard status.quality.isUsable,
              status.hasFiniteSampleTimestamp,
              !processes.isEmpty,
              listedProcessCount > 0 else {
            return false
        }
        let coverage = Double(sampledProcessCount) / Double(listedProcessCount - permissionDeniedProcessCount)
        return coverage.isFinite && coverage >= Self.minimumUsableCoverage
    }
}

public struct ProcessSampler: Sendable {
    public init() {}

    /// `proc_listpids` accepts a signed 32-bit byte count. Keep all capacity
    /// arithmetic checked before allocating or converting to that C type.
    static func checkedPIDBufferByteCount(capacity: Int) -> Int? {
        guard capacity > 0 else { return nil }
        let stride = MemoryLayout<pid_t>.stride
        guard stride > 0 else { return nil }
        let (bytes, overflow) = capacity.multipliedReportingOverflow(by: stride)
        guard !overflow, bytes <= Int(Int32.max) else { return nil }
        return bytes
    }

    static func isPIDByteCountAligned(_ byteCount: Int) -> Bool {
        let stride = MemoryLayout<pid_t>.stride
        return stride > 0 && byteCount >= 0 && byteCount % stride == 0
    }

    /// A PID may be recycled while the sampler is reading rusage, paths, and
    /// working-directory metadata. Accept the assembled snapshot only when a
    /// final kernel identity read still describes the process that started it.
    static func hasStableIdentity(
        requestedPID: Int32,
        initial: ProcessIdentity,
        final: ProcessIdentity
    ) -> Bool {
        requestedPID > 0
            && initial.pid == requestedPID
            && initial.isStructurallyValid
            && final.isStructurallyValid
            && initial == final
    }

    /// A usable quality requires at least one complete process snapshot. An
    /// attempted scan that reads zero rows is still useful diagnostic evidence,
    /// but it must not look like a fresh estimated payload.
    static func sampleStatus(
        at timestamp: Date,
        listedProcessCount: Int,
        sampledProcessCount: Int,
        hasEstimatedFootprint: Bool,
        permissionDeniedProcessCount: Int = 0
    ) -> SampleStatus {
        guard timestamp.timeIntervalSince1970.isFinite else {
            return .error("进程采样时间无效")
        }
        let sampled = max(sampledProcessCount, 0)
        let listed = max(max(listedProcessCount, 0), sampled)
        guard sampled > 0 else {
            let message = listed > 0
                ? "已枚举 \(listed) 个进程，但没有获得可用快照"
                : "进程列表未返回可读取条目"
            return .unavailable(message: message)
        }
        if sampled == listed, !hasEstimatedFootprint {
            return .available(at: timestamp)
        }

        var reasons = [String]()
        let skipped = listed - sampled
        if skipped > 0 {
            let denied = min(max(permissionDeniedProcessCount, 0), skipped)
            if denied > 0 { reasons.append("\(denied) 个进程被系统拒绝读取") }
            if skipped > denied { reasons.append("\(skipped - denied) 个进程在扫描期间退出、身份变化或读取失败") }
        }
        if hasEstimatedFootprint {
            reasons.append("部分 footprint 使用 RSS 估算")
        }
        return .estimated(at: timestamp, message: reasons.joined(separator: "；"))
    }

    public func sample() throws -> [ProcessSnapshot] {
        try sampleDetailed().processes
    }

    /// Reads one process by PID for an immediate identity re-check before a
    /// user-confirmed action. A nil result is intentionally ambiguous: the
    /// caller must separately determine whether the process exited or became
    /// unavailable.
    public func sample(pid: Int32) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }
        var failure = ProcessReadFailure.unavailable
        return snapshot(pid: pid_t(pid), failure: &failure)
    }

    /// Enumerate relationships independently of task/BSD-info permission.
    /// Cleanup uses this to detect unreadable children without treating every
    /// protected system process as a possible child of every application.
    public func descendantProcessIDs(of rootPID: Int32) throws -> Set<Int32> {
        guard rootPID > 0 else { throw MemoryMonitorError.invalidData(description: "无效的父进程") }
        var seen: Set<Int32> = [rootPID]
        var frontier = [rootPID]
        let started = DispatchTime.now().uptimeNanoseconds
        while let parent = frontier.popLast() {
            guard !Task.isCancelled, seen.count <= 8192,
                  DispatchTime.now().uptimeNanoseconds - started < 1_000_000_000 else {
                throw MemoryMonitorError.invalidData(description: "进程族枚举未完成")
            }
            var capacity = 32
            var children: [Int32]?
            while capacity <= 8192 {
                var buffer = [pid_t](repeating: 0, count: capacity)
                let bytes = Int32(capacity * MemoryLayout<pid_t>.stride)
                errno = 0
                let returned = buffer.withUnsafeMutableBytes {
                    proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), $0.baseAddress, bytes)
                }
                let code = errno
                guard returned >= 0, returned > 0 || code == 0,
                      Self.isPIDByteCountAligned(Int(returned)) else {
                    throw MemoryMonitorError.systemCall(name: "proc_listpids(children)", code: code)
                }
                if returned < bytes {
                    children = Array(buffer.prefix(Int(returned) / MemoryLayout<pid_t>.stride))
                    break
                }
                capacity *= 2
            }
            guard let children else {
                throw MemoryMonitorError.invalidData(description: "进程族列表被截断")
            }
            for child in children where child > 0 && seen.insert(child).inserted { frontier.append(child) }
        }
        seen.remove(rootPID)
        return seen
    }

    /// Enumerates all visible processes and reports processes that disappear
    /// or become inaccessible during the scan instead of silently hiding the
    /// partial result.
    public func sampleDetailed(at timestamp: Date = Date()) throws -> ProcessSamplingResult {
        guard timestamp.timeIntervalSince1970.isFinite else {
            throw MemoryMonitorError.invalidData(description: "进程采样时间无效")
        }
        let requestedBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requestedBytes > 0 else {
            throw MemoryMonitorError.systemCall(name: "proc_listpids(size)", code: requestedBytes)
        }

        let pidStride = MemoryLayout<pid_t>.stride
        guard pidStride > 0 else {
            throw MemoryMonitorError.invalidData(description: "进程列表元素大小无效")
        }
        let requested = Int(requestedBytes)
        guard Self.isPIDByteCountAligned(requested) else {
            throw MemoryMonitorError.invalidData(description: "进程列表大小未按 PID 元素对齐")
        }
        guard requested <= Int.max - pidStride else {
            throw MemoryMonitorError.invalidData(description: "进程列表大小溢出")
        }
        var capacity = requested / pidStride + 1
        var pids = [pid_t]()
        var returnedBytes: Int32 = 0
        for _ in 0..<3 {
            guard let bufferByteCount = Self.checkedPIDBufferByteCount(capacity: capacity) else {
                throw MemoryMonitorError.invalidData(description: "进程列表缓冲区大小无效")
            }
            pids = [pid_t](repeating: 0, count: capacity)
            returnedBytes = pids.withUnsafeMutableBytes { rawBuffer in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, rawBuffer.baseAddress, Int32(bufferByteCount))
            }
            guard returnedBytes > 0 else {
                throw MemoryMonitorError.systemCall(name: "proc_listpids", code: returnedBytes)
            }
            guard Self.isPIDByteCountAligned(Int(returnedBytes)) else {
                throw MemoryMonitorError.invalidData(description: "proc_listpids 返回大小未按 PID 元素对齐")
            }
            if Int(returnedBytes) < bufferByteCount {
                break
            }
            let returned = Int(returnedBytes)
            guard returned <= Int.max - pidStride else {
                throw MemoryMonitorError.invalidData(description: "进程列表返回大小溢出")
            }
            let requiredCapacity = returned / pidStride + 1
            let (doubledCapacity, doubledOverflow) = capacity.multipliedReportingOverflow(by: 2)
            guard !doubledOverflow else {
                throw MemoryMonitorError.invalidData(description: "进程列表容量增长溢出")
            }
            capacity = max(doubledCapacity, requiredCapacity)
        }
        guard let finalBufferByteCount = Self.checkedPIDBufferByteCount(capacity: pids.count),
              Int(returnedBytes) < finalBufferByteCount else {
            throw MemoryMonitorError.invalidData(description: "proc_listpids returned a truncated process list")
        }

        let returnedCount = min(Int(returnedBytes) / pidStride, pids.count)
        var seenPIDs = Set<pid_t>()
        let candidatePIDs = pids.prefix(returnedCount).filter { pid in
            pid > 0 && seenPIDs.insert(pid).inserted
        }
        var processes: [ProcessSnapshot] = []
        var failures: [ProcessReadDiagnostic] = []
        for pid in candidatePIDs {
            var failure = ProcessReadFailure.unavailable
            if let process = snapshot(pid: pid, failure: &failure) {
                processes.append(process)
            } else {
                failures.append(readDiagnostic(pid: pid, reason: failure))
            }
        }
        let skippedCount = candidatePIDs.count - processes.count
        let hasEstimatedFootprint = processes.contains { $0.physicalFootprintIsEstimated }
        let status = Self.sampleStatus(
            at: timestamp,
            listedProcessCount: candidatePIDs.count,
            sampledProcessCount: processes.count,
            hasEstimatedFootprint: hasEstimatedFootprint,
            permissionDeniedProcessCount: failures.filter { $0.reason == .permissionDenied }.count
        )
        return ProcessSamplingResult(
            processes: processes,
            listedProcessCount: candidatePIDs.count,
            sampledProcessCount: processes.count,
            skippedProcessCount: skippedCount,
            status: status,
            readFailures: failures
        )
    }

    static func readFailure(errno code: Int32) -> ProcessReadFailure {
        switch code {
        case EPERM, EACCES: return .permissionDenied
        case ESRCH, ENOENT: return .disappeared
        default: return .unavailable
        }
    }

    private func readDiagnostic(pid: pid_t, reason: ProcessReadFailure) -> ProcessReadDiagnostic {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let count = withUnsafeMutablePointer(to: &bsd) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
        return ProcessReadDiagnostic(pid: pid, parentPID: count >= size ? Int32(bsd.pbi_ppid) : nil,
                                     userID: count >= size ? bsd.pbi_uid : nil,
                                     executablePath: executablePath(for: pid), reason: reason)
    }

    private func snapshot(pid: pid_t, failure: inout ProcessReadFailure) -> ProcessSnapshot? {
        var info = proc_taskallinfo()
        let infoSize = Int32(MemoryLayout<proc_taskallinfo>.stride)
        errno = 0
        let infoBytes = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, pointer, infoSize)
        }
        let infoError = errno
        guard infoBytes >= infoSize else { failure = Self.readFailure(errno: infoError); return nil }

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

        let identity = ProcessIdentity(
            pid: Int32(bsd.pbi_pid),
            startTimeSeconds: bsd.pbi_start_tvsec,
            startTimeMicroseconds: bsd.pbi_start_tvusec
        )
        guard identity.isStructurallyValid else { failure = .unstableIdentity; return nil }

        let path = executablePath(for: pid)
        let application = ApplicationIdentityResolver.resolve(executablePath: path)

        var finalBSD = proc_bsdinfo()
        let finalBSDSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        errno = 0
        let finalBSDBytes = withUnsafeMutablePointer(to: &finalBSD) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, finalBSDSize)
        }
        let finalError = errno
        guard finalBSDBytes >= finalBSDSize else { failure = Self.readFailure(errno: finalError); return nil }
        let finalIdentity = ProcessIdentity(
            pid: Int32(finalBSD.pbi_pid),
            startTimeSeconds: finalBSD.pbi_start_tvsec,
            startTimeMicroseconds: finalBSD.pbi_start_tvusec
        )
        guard Self.hasStableIdentity(
            requestedPID: Int32(pid),
            initial: identity,
            final: finalIdentity
        ) else {
            failure = .unstableIdentity
            return nil
        }
        return ProcessSnapshot(
            identity: identity,
            parentPID: Int32(finalBSD.pbi_ppid),
            userID: UInt32(finalBSD.pbi_uid),
            isSystem: (finalBSD.pbi_flags & UInt32(PROC_FLAG_SYSTEM)) != 0,
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

    /// Higher values represent a more specific or better-evidenced attribution.
    /// This order is also used when one stable group receives processes whose
    /// classifications were produced by different rules.
    fileprivate var confidencePriority: Int {
        switch self {
        case .systemProcess: return 100
        case .codexSession: return 95
        case .codexAncestor: return 90
        case .chromeIdentity: return 85
        case .maibotIdentity: return 84
        case .virtualizationIdentity: return 83
        case .safariAncestor: return 80
        case .ghosttyAncestor: return 75
        case .runtimeWorkingDirectory: return 70
        case .runtimeAncestorWorkingDirectory: return 65
        case .runtimeFallback: return 60
        case .unattributedWebKit: return 40
        case .processName: return 10
        }
    }

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

    /// Exact physical-footprint samples are not numerically comparable with
    /// RSS fallbacks. Consumers that rank groups should place exact groups
    /// first and only then compare the selected memory metric.
    public static func qualityComesBefore(
        _ lhs: WorkloadGroupSnapshot,
        _ rhs: WorkloadGroupSnapshot
    ) -> Bool {
        if lhs.containsEstimatedFootprint != rhs.containsEstimatedFootprint {
            return !lhs.containsEstimatedFootprint
        }
        return false
    }

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
            if classification.reason.confidencePriority > bucket.reason.confidencePriority
                || (classification.reason.confidencePriority == bucket.reason.confidencePriority
                    && classification.reason.rawValue < bucket.reason.rawValue) {
                bucket.reason = classification.reason
            }
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
                memberProcessIdentities: bucket.processes
                    .map(\.identity)
                    .sorted(by: Self.identityAscending)
            )
        }
        .sorted {
            if WorkloadGroupSnapshot.qualityComesBefore($0, $1) { return true }
            if WorkloadGroupSnapshot.qualityComesBefore($1, $0) { return false }
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
        let ancestors = Array(names.dropFirst())
        let own = process.name

        // Match process names and bundle components at explicit boundaries.
        // A substring search would classify paths such as
        // `/work/chrome-project/...` or `/archive/vmmigration/...` as real
        // browser/virtualization workloads.
        let codexNames: Set<String> = ["codex"]
        let codexPrefixes = ["codex helper"]
        let chromeNames: Set<String> = ["chrome", "google chrome", "chromium"]
        let chromePrefixes = [
            "google chrome helper",
            "chrome helper",
            "chrome_crashpad"
        ]
        let safariNames: Set<String> = ["safari"]
        let safariPrefixes = [
            "safari networking",
            "safari history",
            "safari web",
            "safari helper",
            "com.apple.safari"
        ]
        let webKitNames: Set<String> = ["webkit"]
        let webKitPrefixes = ["webkit", "com.apple.webkit"]
        let ghosttyNames: Set<String> = ["ghostty"]
        let ghosttyPrefixes = ["ghostty"]
        let maiBotNames: Set<String> = ["maibot"]
        let maiBotPrefixes = ["maibot worker", "maibot server"]
        // Common host-side VM applications and helpers. Keep hyphenated
        // variants as explicit exact names: the shared prefix matcher treats a
        // hyphen as an ordinary word character so `chrome-project` and similar
        // project paths are not misclassified.
        let virtualizationNames: Set<String> = [
            "vmm", "virtualization", "virtual machine", "virtualmachine",
            "utm", "utm se", "utm-se",
            "parallels", "parallels desktop",
            "vmware", "vmware fusion", "vmware-vmx", "vmware-vmx-debug",
            "virtualbox", "virtualboxvm", "vboxheadless",
            "qemu", "qemu-system", "qemu-system-aarch64", "qemu-system-x86_64",
            "qemu-system-arm", "qemu-system-i386", "qemu-system-ppc",
            "qemu-system-riscv64",
            "lima", "limactl", "colima", "multipass", "multipassd",
            "prl_vm_app", "prl_client_app"
        ]
        let virtualizationPrefixes = [
            "vmm", "virtualization", "virtual machine", "virtualmachine",
            "utm", "parallels", "vmware", "virtualbox", "vbox",
            "qemu", "lima", "colima", "multipass", "prl"
        ]

        let ownIsCodex = processNameMatches(own, exact: codexNames, prefixes: codexPrefixes)
        let pathIsCodex = pathComponentMatches(
            process.executablePath,
            exact: codexNames,
            prefixes: codexPrefixes
        )
        let applicationIsCodex = processNameMatches(
            process.applicationName,
            exact: codexNames,
            prefixes: codexPrefixes
        )
        let bundleIsCodex = bundleContainsComponent(process.bundleIdentifier, anyOf: codexNames)

        let isChrome = processNameMatches(own, exact: chromeNames, prefixes: chromePrefixes)
            || pathComponentMatches(process.executablePath, exact: chromeNames, prefixes: chromePrefixes)
            || processNameMatches(process.applicationName, exact: chromeNames, prefixes: chromePrefixes)
            || bundleContainsComponent(process.bundleIdentifier, anyOf: chromeNames)
        let isSafari = processNameMatches(own, exact: safariNames, prefixes: safariPrefixes)
            || pathComponentMatches(process.executablePath, exact: safariNames, prefixes: safariPrefixes)
            || processNameMatches(process.applicationName, exact: safariNames, prefixes: safariPrefixes)
            || bundleContainsComponent(process.bundleIdentifier, anyOf: safariNames)
        let isWebKit = processNameMatches(own, exact: webKitNames, prefixes: webKitPrefixes)
            || pathComponentMatches(process.executablePath, exact: webKitNames, prefixes: webKitPrefixes)
            || processNameMatches(process.applicationName, exact: webKitNames, prefixes: webKitPrefixes)
            || bundleContainsComponent(process.bundleIdentifier, anyOf: webKitNames)
        let isGhostty = processNameMatches(own, exact: ghosttyNames, prefixes: ghosttyPrefixes)
            || pathComponentMatches(process.executablePath, exact: ghosttyNames, prefixes: ghosttyPrefixes)
            || processNameMatches(process.applicationName, exact: ghosttyNames, prefixes: ghosttyPrefixes)
            || bundleContainsComponent(process.bundleIdentifier, anyOf: ghosttyNames)
        let isMaiBot = processNameMatches(own, exact: maiBotNames, prefixes: maiBotPrefixes)
            || pathComponentMatches(process.executablePath, exact: maiBotNames, prefixes: maiBotPrefixes)
            || processNameMatches(process.applicationName, exact: maiBotNames, prefixes: maiBotPrefixes)
            || bundleContainsComponent(process.bundleIdentifier, anyOf: maiBotNames)
        let isVirtualization = processNameMatches(
            own,
            exact: virtualizationNames,
            prefixes: virtualizationPrefixes
        )
            || pathComponentMatches(
                process.executablePath,
                exact: virtualizationNames,
                prefixes: virtualizationPrefixes
            )
            || processNameMatches(
                process.applicationName,
                exact: virtualizationNames,
                prefixes: virtualizationPrefixes
            )
            || bundleContainsComponent(process.bundleIdentifier, anyOf: virtualizationNames)
        let runtime = runtimeDescriptor(for: own.lowercased())
        let isNode = runtime?.id == "node"
        let isPython = runtime?.id == "python"
        // Runtime working-directory resolution is also used to recognize a
        // MaiBot Python worker that inherited its project label from an
        // ancestor. Resolve it once instead of walking the parent chain twice.
        let workingDirectory = runtime == nil
            ? nil
            : workingDirectoryResolution(for: process, byPID: byPID)
        let maiBotWorkingDirectory = processNameMatches(
            process.workingDirectoryLabel,
            exact: maiBotNames,
            prefixes: maiBotPrefixes
        ) || (workingDirectory.map {
            processNameMatches($0.label, exact: maiBotNames, prefixes: maiBotPrefixes)
        } ?? false)

        let ancestorHasCodex = ancestors.contains {
            processNameMatches($0, exact: codexNames, prefixes: codexPrefixes)
        }
        let ancestorHasSafari = ancestors.contains {
            processNameMatches($0, exact: safariNames, prefixes: safariPrefixes)
        }
        let ancestorHasGhostty = ancestors.contains {
            processNameMatches($0, exact: ghosttyNames, prefixes: ghosttyPrefixes)
        }
        let ancestorHasMaiBot = ancestors.contains {
            processNameMatches($0, exact: maiBotNames, prefixes: maiBotPrefixes)
        }
        let ancestorHasVirtualization = ancestors.contains {
            processNameMatches($0, exact: virtualizationNames, prefixes: virtualizationPrefixes)
        }

        if process.isSystem || process.userID == 0 || ["kernel_task", "windowserver", "controlcenter", "launchd"].contains(own.lowercased()) {
            return Classification(id: "system", title: "系统", isSystem: true, reason: .systemProcess)
        }
        if ownIsCodex || pathIsCodex || applicationIsCodex || bundleIsCodex {
            let hasAutomationDescendant = isChrome || isNode || isWebKit || isPython
            return hasAutomationDescendant
                ? Classification(id: "codex-automation", title: "Codex 自动化", isSystem: false, reason: .codexAncestor)
                : Classification(id: "codex-session", title: "Codex 会话", isSystem: false, reason: .codexSession)
        }
        if ancestorHasCodex && (isChrome || isNode || isWebKit || isPython) {
            return Classification(id: "codex-automation", title: "Codex 自动化", isSystem: false, reason: .codexAncestor)
        }
        if isSafari || ancestorHasSafari {
            return Classification(id: "safari-webkit", title: "Safari/WebKit", isSystem: false, reason: .safariAncestor)
        }
        if isWebKit {
            return Classification(id: "unattributed-webkit", title: "未归属 WebKit", isSystem: false, reason: .unattributedWebKit)
        }
        if isChrome {
            return Classification(id: "chrome", title: "Chrome", isSystem: false, reason: .chromeIdentity)
        }
        // Specific application identities must win over the broad Ghostty
        // subtree. A MaiBot Python worker or a VM launched from a terminal is
        // still MaiBot/VM, not a generic development service.
        if isMaiBot || ancestorHasMaiBot || maiBotWorkingDirectory {
            return Classification(id: "maibot", title: "MaiBot", isSystem: false, reason: .maibotIdentity)
        }
        if isVirtualization || ancestorHasVirtualization {
            return Classification(id: "virtual-machines", title: "虚拟机", isSystem: false, reason: .virtualizationIdentity)
        }
        if isGhostty || ancestorHasGhostty {
            return Classification(id: "ghostty-services", title: "Ghostty/开发服务", isSystem: false, reason: .ghosttyAncestor)
        }
        if let runtime {
            if let resolution = workingDirectory {
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
        return Classification(
            id: "process-\(own.lowercased())",
            title: process.name,
            isSystem: false,
            reason: .processName
        )
    }

    private func processNameMatches(
        _ value: String?,
        exact: Set<String>,
        prefixes: [String]
    ) -> Bool {
        guard let value else { return false }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if exact.contains(normalized) { return true }
        return prefixes.contains { prefix in
            guard normalized.hasPrefix(prefix) else { return false }
            let suffix = normalized.dropFirst(prefix.count)
            guard let first = suffix.first else { return true }
            // Hyphens are deliberately excluded: `safari-backup` and
            // `chrome-project` are ordinary names, not browser identities.
            return first == " " || first == "(" || first == "." || first == "_"
        }
    }

    private func pathComponentMatches(
        _ path: String?,
        exact: Set<String>,
        prefixes: [String]
    ) -> Bool {
        guard let path, path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: true).contains { rawComponent in
            var component = String(rawComponent).lowercased()
            if component.hasSuffix(".app") {
                component.removeLast(4)
            }
            return processNameMatches(component, exact: exact, prefixes: prefixes)
        }
    }

    private func bundleContainsComponent(_ bundle: String?, anyOf components: Set<String>) -> Bool {
        guard let bundle else { return false }
        return bundle
            .lowercased()
            .split(separator: ".", omittingEmptySubsequences: true)
            .contains { components.contains(String($0)) }
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

    private static func identityAscending(_ lhs: ProcessIdentity, _ rhs: ProcessIdentity) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        if lhs.startTimeSeconds != rhs.startTimeSeconds {
            return lhs.startTimeSeconds < rhs.startTimeSeconds
        }
        return lhs.startTimeMicroseconds < rhs.startTimeMicroseconds
    }
}

/// A complete sampling pass. Every source has its own status so a failure in
/// process enumeration cannot discard otherwise valid system metrics.
public struct MonitorSnapshot: Sendable, Equatable {
    /// System providers normally finish within the same sampling pass as the
    /// enclosing snapshot. Reject a stale or future value before it can drive
    /// pressure, history, or recommendations.
    public static let systemSampleTimestampTolerance: TimeInterval = 5 * 60

    /// Process providers normally timestamp their result within the same
    /// sampling pass as the enclosing snapshot. Keep a deliberately generous
    /// bound for a slow scan or a caller-supplied clock, while rejecting stale
    /// or malformed timestamps that could make a retained process list look
    /// fresh indefinitely.
    public static let processSampleTimestampTolerance: TimeInterval = 5 * 60

    /// GPU providers may query a separate IORegistry tree and therefore have
    /// a small completion skew, but a value from a different wall-clock era
    /// must not be presented as current utilization.
    public static let gpuSampleTimestampTolerance: TimeInterval = 5 * 60

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
    public let permissionDeniedProcessCount: Int
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
        diagnostics: SamplingDiagnostics? = nil,
        permissionDeniedProcessCount: Int = 0
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
        // The array is the authoritative set of rows exposed by this
        // immutable snapshot. Accepting a larger caller-provided count would
        // make coverage and UI diagnostics disagree with the actual data.
        let normalizedSampledCount = processes.count
        self.listedProcessCount = max(normalizedListedCount, normalizedSampledCount)
        self.sampledProcessCount = normalizedSampledCount
        self.permissionDeniedProcessCount = min(max(permissionDeniedProcessCount, 0),
                                                 self.listedProcessCount - normalizedSampledCount)
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

    /// The system sample is trusted only when the value, its status marker,
    /// and the enclosing pass all describe a finite, nearby instant.
    public var validatedSystemSampleAt: Date? {
        guard let system,
              system.isStructurallyValid,
              systemStatus.quality.isUsable,
              let statusAt = systemStatus.sampledAt else {
            return nil
        }
        let snapshotSeconds = timestamp.timeIntervalSince1970
        let systemSeconds = system.timestamp.timeIntervalSince1970
        let statusSeconds = statusAt.timeIntervalSince1970
        let tolerance = Self.systemSampleTimestampTolerance
        guard snapshotSeconds.isFinite,
              systemSeconds.isFinite,
              statusSeconds.isFinite,
              tolerance.isFinite,
              tolerance >= 0 else {
            return nil
        }
        let systemSkew = systemSeconds - snapshotSeconds
        let statusSkew = statusSeconds - systemSeconds
        let statusToSnapshotSkew = statusSeconds - snapshotSeconds
        guard systemSkew.isFinite,
              statusSkew.isFinite,
              statusToSnapshotSkew.isFinite,
              abs(systemSkew) <= tolerance,
              abs(statusSkew) <= tolerance,
              abs(statusToSnapshotSkew) <= tolerance else {
            return nil
        }
        return system.timestamp
    }

    public var validatedSystemSample: SystemMemorySnapshot? {
        guard validatedSystemSampleAt != nil else { return nil }
        return system
    }

    public var systemDataIsUsable: Bool {
        validatedSystemSample != nil
    }

    /// True only when this pass produced enough trustworthy process rows to
    /// replace the app's retained process/workload snapshot.
    public var processDataIsUsable: Bool {
        guard didSampleProcesses,
              processStatus.quality.isUsable,
              validatedProcessSampleAt != nil,
              sampledProcessCount > 0,
              listedProcessCount > 0 else {
            return false
        }
        let coverage = Double(sampledProcessCount) / Double(listedProcessCount - permissionDeniedProcessCount)
        return coverage.isFinite && coverage >= ProcessSamplingResult.minimumUsableCoverage
    }

    /// A provider returned a captured result, even if its coverage is too low
    /// to replace the retained snapshot. Failed/unavailable statuses have no
    /// sample timestamp and therefore are not considered successful.
    public var processSamplingSucceeded: Bool {
        didSampleProcesses
            && validatedProcessSampleAt != nil
    }

    /// The process sample instant is trusted only when both dates are finite
    /// and close enough to describe the same sampling pass. This value is the
    /// single source of truth for process freshness in the app and history.
    public var validatedProcessSampleAt: Date? {
        guard didSampleProcesses,
              processStatus.quality.isUsable,
              let sampledAt = processStatus.sampledAt else {
            return nil
        }
        let sampledSeconds = sampledAt.timeIntervalSince1970
        let snapshotSeconds = timestamp.timeIntervalSince1970
        guard sampledSeconds.isFinite,
              snapshotSeconds.isFinite,
              Self.processSampleTimestampTolerance.isFinite,
              Self.processSampleTimestampTolerance >= 0 else {
            return nil
        }
        let skew = sampledSeconds - snapshotSeconds
        guard skew.isFinite,
              abs(skew) <= Self.processSampleTimestampTolerance else {
            return nil
        }
        return sampledAt
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
        guard timestamp.timeIntervalSince1970.isFinite else {
            let safeTimestamp = Date(timeIntervalSince1970: 0)
            let diagnostics = SamplingDiagnostics(
                mode: mode,
                totalDurationMilliseconds: 0,
                processDurationMilliseconds: nil,
                processSamplingPerformed: false,
                processCount: 0,
                listedProcessCount: 0
            )
            return MonitorSnapshot(
                timestamp: safeTimestamp,
                system: nil,
                systemStatus: .error("采样时间无效"),
                cpuTime: nil,
                cpuStatus: .error("采样时间无效"),
                gpuUsageFraction: nil,
                gpuStatus: .error("采样时间无效"),
                processes: [],
                processStatus: .error("采样时间无效"),
                listedProcessCount: 0,
                sampledProcessCount: 0,
                groups: [],
                samplingMode: mode,
                diagnostics: diagnostics
            )
        }
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

        let gpuSample = Self.validatedGPU(
            gpuProvider(),
            at: timestamp
        )

        var processes: [ProcessSnapshot] = []
        let processSamplingPerformed = mode.samplesProcesses
        let processStartedAt = processSamplingPerformed
            ? DispatchTime.now().uptimeNanoseconds
            : nil
        var processStatus: SampleStatus
        var listedProcessCount = 0
        var sampledProcessCount = 0
        var permissionDeniedProcessCount = 0
        if processSamplingPerformed {
            do {
                let result = try processProvider()
                processes = result.processes.sorted(by: ProcessSnapshot.memoryDescending)
                processStatus = result.status
                listedProcessCount = result.listedProcessCount
                sampledProcessCount = processes.count
                permissionDeniedProcessCount = result.permissionDeniedProcessCount
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
            diagnostics: diagnostics,
            permissionDeniedProcessCount: permissionDeniedProcessCount
        )
    }

    private static func errorStatus(for error: Error) -> SampleStatus {
        SampleStatus.error(error.localizedDescription)
    }

    private static func validatedGPU(
        _ sample: GPUUsageSample,
        at timestamp: Date
    ) -> GPUUsageSample {
        guard sample.status.quality.isUsable else { return sample }
        guard let sampledAt = sample.status.sampledAt,
              let fraction = sample.fraction,
              fraction.isFinite,
              (0...1).contains(fraction),
              timestamp.timeIntervalSince1970.isFinite,
              sampledAt.timeIntervalSince1970.isFinite,
              Self.gpuTimestampSkew(sampledAt, timestamp: timestamp) else {
            return GPUUsageSample(
                fraction: nil,
                status: .error("GPU 采样时间无效或与当前采样不一致")
            )
        }
        return sample
    }

    private static func gpuTimestampSkew(_ sampledAt: Date, timestamp: Date) -> Bool {
        let skew = sampledAt.timeIntervalSince(timestamp)
        return skew.isFinite
            && MonitorSnapshot.gpuSampleTimestampTolerance.isFinite
            && MonitorSnapshot.gpuSampleTimestampTolerance >= 0
            && abs(skew) <= MonitorSnapshot.gpuSampleTimestampTolerance
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
    public let containsEstimatedFootprint: Bool

    public init(
        id: String,
        title: String,
        deltaBytes: UInt64,
        currentFootprintBytes: UInt64,
        rateBytesPerSecond: Double,
        containsEstimatedFootprint: Bool = false
    ) {
        self.id = id
        self.title = title
        self.deltaBytes = deltaBytes
        self.currentFootprintBytes = currentFootprintBytes
        self.rateBytesPerSecond = rateBytesPerSecond
        self.containsEstimatedFootprint = containsEstimatedFootprint
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case deltaBytes
        case currentFootprintBytes
        case rateBytesPerSecond
        case containsEstimatedFootprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            deltaBytes: try container.decode(UInt64.self, forKey: .deltaBytes),
            currentFootprintBytes: try container.decode(UInt64.self, forKey: .currentFootprintBytes),
            rateBytesPerSecond: try container.decode(Double.self, forKey: .rateBytesPerSecond),
            containsEstimatedFootprint: try container.decodeIfPresent(
                Bool.self,
                forKey: .containsEstimatedFootprint
            ) ?? false
        )
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
        guard intervalSeconds.isFinite, intervalSeconds > 0 else { return [] }

        let previousByID = Dictionary(uniqueKeysWithValues: Self.canonicalGroups(previous).map { ($0.id, $0) })
        return Self.canonicalGroups(current).compactMap { group in
            guard let old = previousByID[group.id], group.physicalFootprintBytes > old.physicalFootprintBytes else {
                return nil
            }
            let delta = group.physicalFootprintBytes - old.physicalFootprintBytes
            let rate = Double(delta) / intervalSeconds
            guard rate.isFinite else { return nil }
            return WorkloadGrowth(
                id: group.id,
                title: group.title,
                deltaBytes: delta,
                currentFootprintBytes: group.physicalFootprintBytes,
                rateBytesPerSecond: rate,
                containsEstimatedFootprint: group.containsEstimatedFootprint
            )
        }
        .sorted {
            if $0.containsEstimatedFootprint != $1.containsEstimatedFootprint {
                return !$0.containsEstimatedFootprint
            }
            if $0.rateBytesPerSecond != $1.rateBytesPerSecond {
                return $0.rateBytesPerSecond > $1.rateBytesPerSecond
            }
            if $0.deltaBytes != $1.deltaBytes {
                return $0.deltaBytes > $1.deltaBytes
            }
            return $0.id < $1.id
        }
    }

    private static func canonicalGroups(_ groups: [WorkloadGroupSnapshot]) -> [WorkloadGroupSnapshot] {
        var byID = [String: WorkloadGroupSnapshot]()
        for group in groups {
            if let existing = byID[group.id] {
                byID[group.id] = preferred(group, over: existing)
            } else {
                byID[group.id] = group
            }
        }
        return byID.values.sorted {
            if $0.id != $1.id {
                return $0.id < $1.id
            }
            return $0.title < $1.title
        }
    }

    private static func preferred(
        _ candidate: WorkloadGroupSnapshot,
        over existing: WorkloadGroupSnapshot
    ) -> WorkloadGroupSnapshot {
        // A duplicate ID can be supplied by a malformed or hand-built
        // snapshot. An RSS fallback must never mask an exact footprint just
        // because its numeric value happens to be larger.
        if candidate.containsEstimatedFootprint != existing.containsEstimatedFootprint {
            return candidate.containsEstimatedFootprint ? existing : candidate
        }
        if candidate.physicalFootprintBytes != existing.physicalFootprintBytes {
            return candidate.physicalFootprintBytes > existing.physicalFootprintBytes ? candidate : existing
        }
        if candidate.residentBytes != existing.residentBytes {
            return candidate.residentBytes > existing.residentBytes ? candidate : existing
        }
        if candidate.processCount != existing.processCount {
            return candidate.processCount > existing.processCount ? candidate : existing
        }
        if candidate.title != existing.title {
            return candidate.title < existing.title ? candidate : existing
        }
        if candidate.representativeProcess != existing.representativeProcess {
            return candidate.representativeProcess < existing.representativeProcess ? candidate : existing
        }
        return existing
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

public enum RecommendationSource: String, Codable, Sendable, Hashable {
    case system
    case processes
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
    /// Sources that must produce a fresh usable observation before the app
    /// can confirm that this recommendation still applies or clear it.
    public let requiredSources: Set<RecommendationSource>
    /// Updated even when display de-duplication keeps `generatedAt` stable.
    public let lastConfirmedAt: Date

    public init(
        id: String,
        severity: RecommendationSeverity,
        title: String,
        detail: String,
        evidence: [RecommendationEvidence],
        confidence: Double,
        targetGroupID: String? = nil,
        generatedAt: Date,
        requiredSources: Set<RecommendationSource> = [],
        lastConfirmedAt: Date? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.evidence = evidence
        self.confidence = min(max(confidence.isFinite ? confidence : 0, 0), 1)
        self.targetGroupID = targetGroupID
        self.generatedAt = generatedAt
        self.requiredSources = requiredSources
        if let lastConfirmedAt, isPersistableDate(lastConfirmedAt) {
            self.lastConfirmedAt = lastConfirmedAt
        } else {
            self.lastConfirmedAt = generatedAt
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case severity
        case title
        case detail
        case evidence
        case confidence
        case targetGroupID
        case generatedAt
        case requiredSources
        case lastConfirmedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        let lastConfirmedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastConfirmedAt
        ) ?? generatedAt
        guard isPersistableDate(generatedAt),
              isPersistableDate(lastConfirmedAt) else {
            throw DecodingError.dataCorruptedError(
                forKey: .generatedAt,
                in: container,
                debugDescription: "Recommendation timestamp is invalid"
            )
        }
        self.init(
            id: try container.decode(String.self, forKey: .id),
            severity: try container.decode(RecommendationSeverity.self, forKey: .severity),
            title: try container.decode(String.self, forKey: .title),
            detail: try container.decode(String.self, forKey: .detail),
            evidence: try container.decode([RecommendationEvidence].self, forKey: .evidence),
            confidence: try container.decode(Double.self, forKey: .confidence),
            targetGroupID: try container.decodeIfPresent(String.self, forKey: .targetGroupID),
            generatedAt: generatedAt,
            requiredSources: try container.decodeIfPresent(
                Set<RecommendationSource>.self,
                forKey: .requiredSources
            ) ?? [],
            lastConfirmedAt: lastConfirmedAt
        )
    }

    public func confirmed(at timestamp: Date) -> MemoryRecommendation {
        MemoryRecommendation(
            id: id,
            severity: severity,
            title: title,
            detail: detail,
            evidence: evidence,
            confidence: confidence,
            targetGroupID: targetGroupID,
            generatedAt: generatedAt,
            requiredSources: requiredSources,
            lastConfirmedAt: timestamp
        )
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
    /// Whether every enumerated process produced a row in the previous
    /// process sample. Estimated footprint values are allowed as long as the
    /// inventory itself is complete; their quality is checked per group.
    public let previousProcessInventoryIsComplete: Bool
    /// Process IDs that must never become actionable recommendation targets.
    /// The app supplies its own PID to enforce the documented self-exclusion
    /// rule without relying on executable names.
    public let excludedProcessIDs: Set<Int32>
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
        previousProcessInventoryIsComplete: Bool = false,
        excludedProcessIDs: Set<Int32> = [],
        pressureLevel: MemoryPressureLevel? = nil,
        previousPressureLevel: MemoryPressureLevel? = nil
    ) {
        self.current = current
        self.previousSystem = previousSystem
        self.previousProcessSystem = previousProcessSystem
        self.previousGroups = previousGroups
        self.previousProcessStatus = previousProcessStatus
        self.previousProcessInventoryIsComplete = previousProcessInventoryIsComplete
        self.excludedProcessIDs = excludedProcessIDs
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
    public let maximumGrowthIntervalSeconds: TimeInterval

    public init(
        minimumGrowthBytes: UInt64 = 16 * 1024 * 1024,
        swapGrowthThresholdBytes: UInt64 = 64 * 1024 * 1024,
        residualSwapThresholdBytes: UInt64 = 1 * 1024 * 1024 * 1024,
        criticalGroupFraction: Double = 0.10,
        maximumGrowthIntervalSeconds: TimeInterval = 5 * 60
    ) {
        self.minimumGrowthBytes = minimumGrowthBytes
        self.swapGrowthThresholdBytes = swapGrowthThresholdBytes
        self.residualSwapThresholdBytes = residualSwapThresholdBytes
        self.criticalGroupFraction = min(max(criticalGroupFraction.isFinite ? criticalGroupFraction : 0.10, 0), 1)
        self.maximumGrowthIntervalSeconds = maximumGrowthIntervalSeconds.isFinite
            ? max(maximumGrowthIntervalSeconds, 0)
            : 5 * 60
    }

    public func evaluate(_ context: RecommendationContext) -> [MemoryRecommendation] {
        guard context.current.timestamp.timeIntervalSince1970.isFinite else {
            return []
        }

        let system = context.current.validatedSystemSample
        let observedLevel = system.map { MemoryPressureEvaluator.observedLevel(for: $0) }
        let currentPressureLevel = context.pressureLevel ?? observedLevel
        // A baseline from the future can be produced by a wall-clock rollback
        // or malformed persisted value. It must not drive recovery.
        let previousSystem = system.flatMap { currentSystem in
            validatedSystem(
                context.previousSystem,
                notAfter: currentSystem.timestamp
            )
        }
        let previousProcessSystem = validatedSystem(
            context.previousProcessSystem,
            notAfter: system?.timestamp
        )
        let currentProcessSampleAt = context.current.validatedProcessSampleAt
        let previousProcessSampleAt = context.previousProcessStatus.flatMap { status -> Date? in
            guard status.quality.isUsable,
                  let sampledAt = status.sampledAt,
                  sampledAt.timeIntervalSince1970.isFinite else {
                return nil
            }
            return sampledAt
        }
        let growthInterval: TimeInterval? = {
            guard processInventoryHasCompleteRows(context.current),
                  context.previousProcessInventoryIsComplete,
                  let currentProcessSampleAt,
                  let previousProcessSampleAt else {
                return nil
            }
            let interval = currentProcessSampleAt.timeIntervalSince(previousProcessSampleAt)
            guard interval.isFinite,
                  interval > 0,
                  interval <= maximumGrowthIntervalSeconds else {
                return nil
            }
            return interval
        }()
        let pairedSwapSystems: (
            current: SystemMemorySnapshot,
            previous: SystemMemorySnapshot
        )? = {
            guard let system,
                  let previousProcessSystem,
                  let currentProcessSampleAt,
                  let previousProcessSampleAt,
                  systemIsPaired(system, with: currentProcessSampleAt),
                  systemIsPaired(previousProcessSystem, with: previousProcessSampleAt) else {
                return nil
            }
            return (system, previousProcessSystem)
        }()
        let baseConfidence = confidence(
            systemStatus: context.current.systemStatus,
            processStatus: context.current.processStatus,
            hasBaseline: growthInterval != nil || previousSystem != nil
        )
        var recommendations = [MemoryRecommendation]()

        // A critical recommendation is an actionable prioritization signal,
        // so it must be based on a complete, exact process inventory. An
        // `estimated` process result may still be useful for a best-effort
        // ranking, but RSS fallback, skipped rows, or even a 50% boundary
        // coverage cannot establish that this is the largest user group.
        if let system,
           currentPressureLevel == .critical,
           processInventoryIsComplete(context.current),
           let group = largestActionableGroup(
               in: context.current.groups,
               excluding: context.excludedProcessIDs
           ),
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
                        RecommendationEvidence(
                            label: "归因量/物理内存",
                            value: String(format: "%.0f%%（含共享重复）", fraction * 100)
                        )
                    ],
                    confidence: baseConfidence,
                    targetGroupID: group.id,
                    generatedAt: context.current.timestamp,
                    requiredSources: [.system, .processes]
                )
            )
        }

        if let growthInterval {
            let growth = WorkloadTrendAnalyzer().growingGroups(
                previous: context.previousGroups,
                current: context.current.groups,
                intervalSeconds: growthInterval
            )
            if let growing = growth.first(where: { candidate in
                guard !candidate.title.isEmpty,
                      candidate.deltaBytes >= minimumGrowthBytes,
                      let currentGroup = canonicalGroup(candidate.id, in: context.current.groups),
                      let previousGroup = canonicalGroup(candidate.id, in: context.previousGroups),
                      !currentGroup.isSystem,
                      !previousGroup.isSystem,
                      !containsExcludedProcess(
                          currentGroup,
                          excludedProcessIDs: context.excludedProcessIDs
                      ),
                      !containsExcludedProcess(
                          previousGroup,
                          excludedProcessIDs: context.excludedProcessIDs
                      ) else {
                    return false
                }
                // Comparing RSS fallback to a physical-footprint sample can
                // manufacture a large delta without any real change. Keep
                // 同一口径的估算值仍可用于观察趋势（并明确警告），
                // but fail closed on a quality transition.
                return currentGroup.containsEstimatedFootprint == previousGroup.containsEstimatedFootprint
            }) {
                let currentGroup = canonicalGroup(growing.id, in: context.current.groups)
                let previousGroup = canonicalGroup(growing.id, in: context.previousGroups)
                let usesEstimatedFootprint = currentGroup?.containsEstimatedFootprint == true
                    || previousGroup?.containsEstimatedFootprint == true
                let swapDelta = pairedSwapSystems.map {
                    positiveDelta(
                        current: $0.current.swapUsedBytes,
                        previous: $0.previous.swapUsedBytes
                    )
                } ?? 0
                let swapIsGrowing = swapDelta > 0 && swapDelta >= swapGrowthThresholdBytes
                let pressureElevated = currentPressureLevel == .attention
                    || currentPressureLevel == .critical
                let severity: RecommendationSeverity =
                    swapIsGrowing || pressureElevated ? .attention : .info
                var evidence = [RecommendationEvidence]()
                if usesEstimatedFootprint {
                    // Put the caveat first because the compact UI/probe show
                    // only the first three evidence items.
                    evidence.append(
                        RecommendationEvidence(label: "footprint 口径", value: "RSS 估算")
                    )
                }
                evidence.append(contentsOf: [
                    RecommendationEvidence(label: "增长", value: MemoryFormatter.bytes(growing.deltaBytes)),
                    RecommendationEvidence(label: "速度", value: rateDescription(growing.rateBytesPerSecond)),
                    RecommendationEvidence(label: "当前归因总量", value: MemoryFormatter.bytes(growing.currentFootprintBytes))
                ])
                if swapDelta > 0 {
                    evidence.append(
                        RecommendationEvidence(label: "Swap 增量", value: MemoryFormatter.bytes(swapDelta))
                    )
                }
                recommendations.append(
                    MemoryRecommendation(
                        id: "growth-\(growing.id)",
                        severity: severity,
                        title: "\(growing.title) 较上一轮增加",
                        detail: growthDetail(
                            swapIsGrowing: swapIsGrowing,
                            usesEstimatedFootprint: usesEstimatedFootprint
                        ),
                        evidence: evidence,
                        confidence: min(
                            baseConfidence,
                            context.current.processStatus.quality == .estimated
                                || context.previousProcessStatus?.quality == .estimated
                                ? 0.70
                                : 0.90,
                            usesEstimatedFootprint ? 0.50 : 0.90
                        ),
                        targetGroupID: growing.id,
                        generatedAt: context.current.timestamp,
                        requiredSources: [.processes]
                    )
                )
            }

        }

        // Recovery is a system-only signal, so it must remain available when
        // the current pass intentionally skips the expensive process scan.
        if let system, let previousSystem {
            let previousPressureLevel = context.previousPressureLevel
                ?? MemoryPressureEvaluator.observedLevel(for: previousSystem)
            if previousPressureLevel != .normal,
               currentPressureLevel == .normal,
               system.availableFraction > previousSystem.availableFraction,
               system.swapUsedBytes > 0,
               system.swapUsedBytes < previousSystem.swapUsedBytes,
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
                        generatedAt: context.current.timestamp,
                        requiredSources: [.system]
                    )
                )
            }
        }

        let hasEstimatedFootprint = context.current.groups.contains {
            $0.containsEstimatedFootprint
        }
        if recommendations.isEmpty,
           context.current.didSampleProcesses,
           (context.current.processStatus.quality == .estimated || hasEstimatedFootprint) {
            let detail = hasEstimatedFootprint
                ? "本轮部分 footprint 使用 RSS 估算，建议把当前排行作为方向参考，不据此执行清理。"
                : "本轮有进程退出或受权限限制，建议把当前排行作为方向参考，不据此执行清理。"
            var evidence = [
                RecommendationEvidence(label: "成功读取", value: String(context.current.sampledProcessCount)),
                RecommendationEvidence(label: "已枚举", value: String(context.current.listedProcessCount))
            ]
            if hasEstimatedFootprint {
                evidence.append(
                    RecommendationEvidence(label: "footprint 口径", value: "RSS 估算")
                )
            }
            recommendations.append(
                MemoryRecommendation(
                    id: "data-quality-processes",
                    severity: .info,
                    title: "进程数据部分可用",
                    detail: detail,
                    evidence: evidence,
                    confidence: 0.60,
                    generatedAt: context.current.timestamp,
                    requiredSources: [.processes]
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

    private func largestActionableGroup(
        in groups: [WorkloadGroupSnapshot],
        excluding excludedProcessIDs: Set<Int32>
    ) -> WorkloadGroupSnapshot? {
        groups
            .filter {
                !$0.isSystem
                    && !$0.id.hasPrefix("other-")
                    && !$0.containsEstimatedFootprint
                    && !containsExcludedProcess(
                        $0,
                        excludedProcessIDs: excludedProcessIDs
                    )
            }
            .max {
                if $0.attributedFootprintBytes != $1.attributedFootprintBytes {
                    return $0.attributedFootprintBytes < $1.attributedFootprintBytes
                }
                return $0.id > $1.id
            }
    }

    private func processInventoryIsComplete(_ snapshot: MonitorSnapshot) -> Bool {
        processInventoryHasCompleteRows(snapshot)
            && snapshot.processStatus.quality == .available
    }

    private func processInventoryHasCompleteRows(_ snapshot: MonitorSnapshot) -> Bool {
        snapshot.processDataIsUsable
            && snapshot.sampledProcessCount > 0
            && snapshot.sampledProcessCount == snapshot.listedProcessCount
    }

    private func containsExcludedProcess(
        _ group: WorkloadGroupSnapshot,
        excludedProcessIDs: Set<Int32>
    ) -> Bool {
        !excludedProcessIDs.isEmpty
            && group.memberProcessIdentities.contains {
                excludedProcessIDs.contains($0.pid)
            }
    }

    /// Returns the same deterministic representative used by
    /// `WorkloadTrendAnalyzer` when malformed callers provide duplicate IDs.
    private func canonicalGroup(
        _ id: String,
        in groups: [WorkloadGroupSnapshot]
    ) -> WorkloadGroupSnapshot? {
        groups
            .filter { $0.id == id }
            .max { lhs, rhs in
                if lhs.containsEstimatedFootprint != rhs.containsEstimatedFootprint {
                    return lhs.containsEstimatedFootprint && !rhs.containsEstimatedFootprint
                }
                if lhs.physicalFootprintBytes != rhs.physicalFootprintBytes {
                    return lhs.physicalFootprintBytes < rhs.physicalFootprintBytes
                }
                if lhs.residentBytes != rhs.residentBytes {
                    return lhs.residentBytes < rhs.residentBytes
                }
                if lhs.processCount != rhs.processCount {
                    return lhs.processCount < rhs.processCount
                }
                if lhs.title != rhs.title {
                    return lhs.title > rhs.title
                }
                return lhs.representativeProcess > rhs.representativeProcess
            }
    }

    private func growthDetail(
        swapIsGrowing: Bool,
        usesEstimatedFootprint: Bool
    ) -> String {
        let base = swapIsGrowing
            ? "该工作组较上一轮增加，并伴随 Swap 上升；建议检查任务是否仍有必要运行。"
            : "该工作组较上一轮增加；建议继续观察下一轮趋势。"
        return usesEstimatedFootprint
            ? base + "当前 footprint 为 RSS 估算，先确认后再判断实际内存影响。"
            : base
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

    private func systemIsPaired(
        _ system: SystemMemorySnapshot,
        with processSampleAt: Date
    ) -> Bool {
        let interval = system.timestamp.timeIntervalSince(processSampleAt)
        return interval.isFinite
            && abs(interval) <= MonitorSnapshot.processSampleTimestampTolerance
    }

    private func validatedSystem(
        _ candidate: SystemMemorySnapshot?,
        notAfter reference: Date? = nil
    ) -> SystemMemorySnapshot? {
        guard let candidate,
              candidate.isStructurallyValid,
              candidate.timestamp.timeIntervalSince1970.isFinite else {
            return nil
        }
        if let reference {
            let interval = reference.timeIntervalSince(candidate.timestamp)
            guard interval.isFinite, interval >= 0 else { return nil }
        }
        return candidate
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

    private enum CodingKeys: String, CodingKey {
        case mode
        case totalDurationMilliseconds
        case processDurationMilliseconds
        case processSamplingPerformed
        case processCount
        case listedProcessCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decode(SamplingMode.self, forKey: .mode),
            totalDurationMilliseconds: try container.decode(Double.self, forKey: .totalDurationMilliseconds),
            processDurationMilliseconds: try container.decodeIfPresent(
                Double.self,
                forKey: .processDurationMilliseconds
            ),
            processSamplingPerformed: try container.decode(Bool.self, forKey: .processSamplingPerformed),
            processCount: try container.decode(Int.self, forKey: .processCount),
            listedProcessCount: try container.decode(Int.self, forKey: .listedProcessCount)
        )
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
    public static let defaultMaximumObservationGapSeconds: TimeInterval = 60

    public let transitionIntervalSeconds: TimeInterval
    public let maximumObservationGapSeconds: TimeInterval
    public private(set) var stableLevel: MemoryPressureLevel?
    public private(set) var pendingLevel: MemoryPressureLevel?

    private var pendingSince: Date?
    private var pendingElapsedSeconds: TimeInterval = 0
    private var lastObservationAt: Date?

    public init(
        transitionIntervalSeconds: TimeInterval = MemoryPressureEvaluator.defaultTransitionIntervalSeconds,
        maximumObservationGapSeconds: TimeInterval? = nil
    ) {
        self.transitionIntervalSeconds = Self.validatedInterval(transitionIntervalSeconds)
        let defaultGap = max(
            Self.defaultMaximumObservationGapSeconds,
            self.transitionIntervalSeconds * 2
        )
        self.maximumObservationGapSeconds = Self.validatedObservationGap(
            maximumObservationGapSeconds ?? defaultGap,
            fallback: defaultGap
        )
    }

    public var pressureActiveForSampling: Bool {
        isElevated(stableLevel) || isElevated(pendingLevel)
    }

    public mutating func update(snapshot: SystemMemorySnapshot) -> MemoryPressureLevel {
        // Invalid data interrupts continuity but does not replace the last
        // stable level.
        guard snapshot.isStructurallyValid else {
            interruptPendingTransition()
            return stableLevel ?? .critical
        }
        return update(observed: Self.observedLevel(for: snapshot), at: snapshot.timestamp)
    }

    public mutating func update(
        snapshot: SystemMemorySnapshot,
        elapsedSincePrevious: TimeInterval?
    ) -> MemoryPressureLevel {
        guard snapshot.isStructurallyValid else {
            interruptPendingTransition()
            return stableLevel ?? .critical
        }
        return update(
            observed: Self.observedLevel(for: snapshot),
            at: snapshot.timestamp,
            elapsedSincePrevious: elapsedSincePrevious
        )
    }

    @discardableResult
    public mutating func update(
        observed: MemoryPressureLevel,
        at timestamp: Date,
        elapsedSincePrevious suppliedElapsed: TimeInterval? = nil
    ) -> MemoryPressureLevel {
        // A non-finite timestamp cannot establish continuous evidence.
        guard timestamp.timeIntervalSince1970.isFinite else {
            interruptPendingTransition()
            return stableLevel ?? observed
        }

        let elapsed: TimeInterval?
        if let suppliedElapsed {
            guard suppliedElapsed.isFinite, suppliedElapsed >= 0 else {
                interruptPendingTransition()
                return stableLevel ?? observed
            }
            elapsed = suppliedElapsed
        } else if let lastObservationAt {
            let wallElapsed = timestamp.timeIntervalSince(lastObservationAt)
            if wallElapsed.isFinite, wallElapsed >= 0 {
                elapsed = wallElapsed
            } else {
                clearPendingLevel()
                elapsed = nil
            }
        } else {
            elapsed = nil
        }
        lastObservationAt = timestamp

        guard let stableLevel else {
            self.stableLevel = observed
            clearPendingLevel()
            return observed
        }

        guard observed != stableLevel else {
            clearPendingLevel()
            return stableLevel
        }

        if pendingLevel != observed {
            pendingLevel = observed
            pendingSince = timestamp
            pendingElapsedSeconds = 0
            if transitionIntervalSeconds == 0 {
                return commitPendingLevel()
            }
            return stableLevel
        }

        guard pendingSince != nil else {
            self.pendingSince = timestamp
            pendingElapsedSeconds = 0
            return stableLevel
        }

        guard let elapsed, elapsed <= maximumObservationGapSeconds else {
            // Failure gaps, sleep, and delayed providers begin a new evidence
            // window instead of committing a candidate from two isolated
            // observations.
            self.pendingSince = timestamp
            pendingElapsedSeconds = 0
            return stableLevel
        }

        pendingElapsedSeconds += elapsed
        if pendingElapsedSeconds >= transitionIntervalSeconds {
            return commitPendingLevel()
        }
        return stableLevel
    }

    public mutating func interruptPendingTransition() {
        clearPendingLevel()
        lastObservationAt = nil
    }

    public static func observedLevel(for snapshot: SystemMemorySnapshot) -> MemoryPressureLevel {
        // This API predates optional validation metadata and remains
        // non-optional for source compatibility. Invalid data is treated as a
        // conservative critical observation; `update(snapshot:)` above will
        // ignore it rather than committing that observation.
        guard snapshot.isStructurallyValid else { return .critical }
        if snapshot.availableFraction < 0.10
            || (snapshot.swapTotalBytes > 0
                && snapshot.swapUsedBytes > 0
                && snapshot.swapFreeBytes < 1 * 1024 * 1024 * 1024)
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
        clearPendingLevel()
        return committed
    }

    private mutating func clearPendingLevel() {
        pendingLevel = nil
        pendingSince = nil
        pendingElapsedSeconds = 0
    }

    private static func validatedInterval(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultTransitionIntervalSeconds }
        return max(value, 0)
    }

    private static func validatedObservationGap(
        _ value: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite, value >= 0 else { return fallback }
        return value
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
    /// Whether the attributed footprint contains one or more RSS fallbacks.
    /// This marker is persisted so history consumers never compare values
    /// from different footprint sources as if they were equivalent.
    public let containsEstimatedFootprint: Bool
    public let isSystem: Bool

    public init(
        id: String,
        title: String,
        processCount: Int,
        attributedFootprintBytes: UInt64,
        attributedResidentBytes: UInt64,
        isSystem: Bool,
        containsEstimatedFootprint: Bool = false
    ) {
        self.id = id
        self.title = title
        self.processCount = processCount
        self.attributedFootprintBytes = attributedFootprintBytes
        self.attributedResidentBytes = attributedResidentBytes
        self.containsEstimatedFootprint = containsEstimatedFootprint
        self.isSystem = isSystem
    }

    public init(group: WorkloadGroupSnapshot) {
        self.init(
            id: group.id,
            title: group.title,
            processCount: group.processCount,
            attributedFootprintBytes: group.attributedFootprintBytes,
            attributedResidentBytes: group.attributedResidentBytes,
            isSystem: group.isSystem,
            containsEstimatedFootprint: group.containsEstimatedFootprint
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case processCount
        case attributedFootprintBytes
        case attributedResidentBytes
        case containsEstimatedFootprint
        case isSystem
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try container.decode(String.self, forKey: .id)
        let rawTitle = try container.decode(String.self, forKey: .title)
        let processCount = try container.decode(Int.self, forKey: .processCount)
        guard let id = WorkingDirectoryLabelSanitizer.sanitizedDisplayText(rawID),
              let title = WorkingDirectoryLabelSanitizer.sanitizedDisplayText(rawTitle),
              Self.hasValidText(id),
              Self.hasValidText(title),
              processCount >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .processCount,
                in: container,
                debugDescription: "Persisted workload contains invalid fields"
            )
        }
        self.init(
            id: id,
            title: title,
            processCount: processCount,
            attributedFootprintBytes: try container.decode(UInt64.self, forKey: .attributedFootprintBytes),
            attributedResidentBytes: try container.decode(UInt64.self, forKey: .attributedResidentBytes),
            isSystem: try container.decode(Bool.self, forKey: .isSystem),
            // v1 history files predate this quality marker. Their footprint
            // values were physical-footprint samples, so retain the exact
            // interpretation when the field is absent.
            containsEstimatedFootprint: try container.decodeIfPresent(
                Bool.self,
                forKey: .containsEstimatedFootprint
            ) ?? false
        )
    }

    fileprivate var hasValidPersistedFields: Bool {
        Self.hasValidText(id) && Self.hasValidText(title) && processCount >= 0
    }

    private static func hasValidText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.count <= 256
            && !value.unicodeScalars.contains { scalar in
                let code = scalar.value
                return code < 0x20 || (0x7F...0x9F).contains(code)
            }
    }
}

/// One minute-level system and workload sample retained by `HistoryStore`.
public struct MemoryHistoryRecord: Codable, Sendable, Identifiable, Equatable {
    public let timestamp: Date
    /// The wall-clock instant at which the source system sample was captured.
    /// `timestamp` is normalized to a minute bucket by `HistoryStore`, so this
    /// optional marker is needed to choose the newest system values when two
    /// callers update the same bucket. It is optional for v1 history files.
    public let sourceSampledAt: Date?
    public let availableFraction: Double
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let workloads: [PersistedWorkloadRecord]
    /// The timestamp of the process snapshot used to derive `workloads`.
    /// `nil` means this system sample had no fresh workload attribution.
    /// This is optional for backwards compatibility with v1.0 history files.
    public let workloadsSampledAt: Date?
    /// `true` means every enumerated process contributed to this workload
    /// payload, `false` means the payload is partial, and `nil` means an older
    /// file/caller did not provide enough information to decide.
    public let workloadInventoryIsComplete: Bool?
    // Public initializers intentionally remain non-throwing for source
    // compatibility, but remember invalid non-nil markers so a later store
    // append/merge can fail closed instead of silently turning them into nil.
    private let hasInvalidFreshnessMarker: Bool

    public var id: Date { timestamp }

    /// Reclaim-aware memory usage represented by this minute-level record.
    /// This is the same estimate used by the live pressure indicator.
    public var usedFraction: Double {
        guard availableFraction.isFinite else { return 0 }
        return min(max(1 - availableFraction, 0), 1)
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case sourceSampledAt
        case availableFraction
        case compressedBytes
        case swapUsedBytes
        case workloads
        case workloadsSampledAt
        case workloadInventoryIsComplete
    }

    /// Backwards-compatible initializer for callers that provide workloads
    /// without an explicit source timestamp. Historically those workloads
    /// represented the same sample as `timestamp`, so retain that inference.
    public init(
        timestamp: Date,
        availableFraction: Double,
        compressedBytes: UInt64,
        swapUsedBytes: UInt64,
        workloads: [PersistedWorkloadRecord] = []
    ) {
        self.init(
            timestamp: timestamp,
            availableFraction: availableFraction,
            compressedBytes: compressedBytes,
            swapUsedBytes: swapUsedBytes,
            workloads: workloads,
            workloadsSampledAt: workloads.isEmpty ? nil : timestamp,
            workloadInventoryIsComplete: nil,
            sourceSampledAt: timestamp
        )
    }

    /// Initializer with an explicit workload-source timestamp. Passing `nil`
    /// is meaningful: it records that the workload list has no trustworthy
    /// freshness marker and must not be used for transition events.
    public init(
        timestamp: Date,
        availableFraction: Double,
        compressedBytes: UInt64,
        swapUsedBytes: UInt64,
        workloads: [PersistedWorkloadRecord] = [],
        workloadsSampledAt: Date?,
        workloadInventoryIsComplete: Bool? = nil,
        sourceSampledAt: Date? = nil
    ) {
        self.timestamp = timestamp
        self.hasInvalidFreshnessMarker =
            (sourceSampledAt != nil && !isPersistableDate(sourceSampledAt!))
            || (workloadsSampledAt != nil && !isPersistableDate(workloadsSampledAt!))
        if let sourceSampledAt,
           isPersistableDate(sourceSampledAt) {
            self.sourceSampledAt = sourceSampledAt
        } else {
            self.sourceSampledAt = nil
        }
        self.availableFraction = min(max(availableFraction, 0), 1)
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.workloads = workloads
        if let workloadsSampledAt,
           isPersistableDate(workloadsSampledAt) {
            self.workloadsSampledAt = workloadsSampledAt
        } else {
            self.workloadsSampledAt = nil
        }
        self.workloadInventoryIsComplete = workloadsSampledAt == nil
            ? nil
            : workloadInventoryIsComplete
    }

    /// Backwards-compatible snapshot initializer. A non-empty group list is
    /// assumed to have been captured with the snapshot timestamp.
    public init(snapshot: SystemMemorySnapshot, groups: [WorkloadGroupSnapshot] = []) {
        self.init(
            snapshot: snapshot,
            groups: groups,
            workloadsSampledAt: groups.isEmpty ? nil : snapshot.timestamp,
            workloadInventoryIsComplete: nil
        )
    }

    public init(
        snapshot: SystemMemorySnapshot,
        groups: [WorkloadGroupSnapshot] = [],
        workloadsSampledAt: Date?,
        workloadInventoryIsComplete: Bool? = nil
    ) {
        self.init(
            timestamp: snapshot.timestamp,
            availableFraction: snapshot.availableFraction,
            compressedBytes: snapshot.compressedBytes,
            swapUsedBytes: snapshot.swapUsedBytes,
            workloads: groups.map(PersistedWorkloadRecord.init(group:)),
            workloadsSampledAt: workloadsSampledAt,
            workloadInventoryIsComplete: workloadInventoryIsComplete,
            sourceSampledAt: snapshot.timestamp
        )
    }

    public init(entry: MemoryHistoryEntry) {
        self.init(
            timestamp: entry.timestamp,
            availableFraction: entry.availableFraction,
            compressedBytes: entry.compressedBytes,
            swapUsedBytes: entry.swapUsedBytes,
            workloadsSampledAt: nil,
            workloadInventoryIsComplete: nil,
            sourceSampledAt: entry.timestamp
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let sourceSampledAt = try container.decodeIfPresent(Date.self, forKey: .sourceSampledAt)
        let availableFraction = try container.decode(Double.self, forKey: .availableFraction)
        let workloads = try container.decodeIfPresent([PersistedWorkloadRecord].self, forKey: .workloads) ?? []
        let workloadsSampledAt = try container.decodeIfPresent(Date.self, forKey: .workloadsSampledAt)
        let workloadInventoryIsComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .workloadInventoryIsComplete
        )
        guard isPersistableDate(timestamp),
              sourceSampledAt.map(isPersistableDate) ?? true,
              availableFraction.isFinite,
              (0...1).contains(availableFraction),
              workloadsSampledAt.map(isPersistableDate) ?? true,
              workloadsSampledAt != nil || workloadInventoryIsComplete == nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .timestamp,
                in: container,
                debugDescription: "History record contains invalid persisted fields"
            )
        }
        self.init(
            timestamp: timestamp,
            availableFraction: availableFraction,
            compressedBytes: try container.decode(UInt64.self, forKey: .compressedBytes),
            swapUsedBytes: try container.decode(UInt64.self, forKey: .swapUsedBytes),
            workloads: workloads,
            workloadsSampledAt: workloadsSampledAt,
            workloadInventoryIsComplete: workloadInventoryIsComplete,
            sourceSampledAt: sourceSampledAt
        )
    }

    fileprivate var hasValidPersistedFields: Bool {
        isPersistableDate(timestamp)
            && (sourceSampledAt.map(isPersistableDate) ?? true)
            && availableFraction.isFinite
            && (0...1).contains(availableFraction)
            && (workloadsSampledAt.map(isPersistableDate) ?? true)
            && (workloadsSampledAt != nil || workloadInventoryIsComplete == nil)
            && workloads.allSatisfy(\.hasValidPersistedFields)
            && !hasInvalidFreshnessMarker
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
    /// A workload marker must describe an observation near the minute record
    /// that carries it. This prevents an old or future process snapshot from
    /// being interpreted as a change in the current history bucket.
    public static let defaultWorkloadMarkerRecordSkewSeconds: TimeInterval = 5 * 60

    public let eventLimit: Int
    public let workloadEventThresholdBytes: UInt64
    public let workloadGrowthThresholdBytes: UInt64
    public let swapAttentionThresholdBytes: UInt64
    public let swapCriticalThresholdBytes: UInt64
    public let workloadTransitionGapSeconds: TimeInterval
    public let workloadMarkerRecordSkewSeconds: TimeInterval

    public init(
        eventLimit: Int = MemoryHistoryAnalyzer.defaultEventLimit,
        workloadEventThresholdBytes: UInt64 = MemoryHistoryAnalyzer.defaultWorkloadEventThresholdBytes,
        workloadGrowthThresholdBytes: UInt64 = MemoryHistoryAnalyzer.defaultWorkloadGrowthThresholdBytes,
        swapAttentionThresholdBytes: UInt64 = MemoryHistoryAnalyzer.defaultSwapAttentionThresholdBytes,
        swapCriticalThresholdBytes: UInt64 = MemoryHistoryAnalyzer.defaultSwapCriticalThresholdBytes,
        workloadTransitionGapSeconds: TimeInterval = MemoryHistoryAnalyzer.defaultWorkloadTransitionGapSeconds,
        workloadMarkerRecordSkewSeconds: TimeInterval = MemoryHistoryAnalyzer.defaultWorkloadMarkerRecordSkewSeconds
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
        self.workloadMarkerRecordSkewSeconds = max(
            workloadMarkerRecordSkewSeconds.isFinite ? workloadMarkerRecordSkewSeconds : 0,
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

            }
        }

        // Workload scans have an independent cadence from system samples.
        // Skip system-only, partial, and legacy-unknown payloads while linking
        // complete process inventories by their own strictly increasing
        // source markers.
        var previousWorkloadObservation: MemoryHistoryRecord?
        for current in normalizedRecords {
            guard isValidWorkloadObservation(current),
                  let currentSampleAt = current.workloadsSampledAt else {
                continue
            }
            guard let previous = previousWorkloadObservation,
                  let previousSampleAt = previous.workloadsSampledAt else {
                previousWorkloadObservation = current
                continue
            }
            // A duplicate or rolled-back marker is not a new observation and
            // must not replace the valid baseline.
            guard currentSampleAt > previousSampleAt else { continue }
            let markerGap = currentSampleAt.timeIntervalSince(previousSampleAt)
            let recordGap = current.timestamp.timeIntervalSince(previous.timestamp)
            if markerGap.isFinite,
               markerGap <= workloadTransitionGapSeconds,
               recordGap.isFinite,
               recordGap > 0,
               recordGap <= workloadTransitionGapSeconds {
                events.append(contentsOf: workloadEvents(previous: previous, current: current))
            }
            previousWorkloadObservation = current
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
            guard record.timestamp.timeIntervalSince1970.isFinite,
                  record.availableFraction.isFinite,
                  (0...1).contains(record.availableFraction) else {
                continue
            }
            if let existing = byTimestamp[record.timestamp] {
                byTimestamp[record.timestamp] = merged(existing: existing, candidate: record)
            } else {
                byTimestamp[record.timestamp] = record
            }
        }
        return byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Multiple callers can hand the analyzer records from overlapping
    /// recovery windows. Merge equal timestamps with the same freshness rule
    /// used by `HistoryStore` instead of letting dictionary insertion order
    /// silently discard the workload attribution from one record.
    private func merged(
        existing: MemoryHistoryRecord,
        candidate: MemoryHistoryRecord
    ) -> MemoryHistoryRecord {
        HistoryStore.preferredRecord(existing: existing, candidate: candidate)
    }

    private func isValidWorkloadObservation(_ record: MemoryHistoryRecord) -> Bool {
        guard record.workloadInventoryIsComplete == true,
              let marker = record.workloadsSampledAt,
              isPersistableDate(record.timestamp),
              isPersistableDate(marker),
              workloadMarkerRecordSkewSeconds.isFinite,
              workloadMarkerRecordSkewSeconds >= 0 else {
            return false
        }
        let skew = marker.timeIntervalSince(record.timestamp)
        return skew.isFinite && abs(skew) <= workloadMarkerRecordSkewSeconds
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
        // A system-only record has no fresh workload evidence. Do not turn a
        // missing attribution into a false appeared/disappeared/growth event.
        guard previous.workloadInventoryIsComplete == true,
              current.workloadInventoryIsComplete == true,
              let previousSampleAt = previous.workloadsSampledAt,
              let currentSampleAt = current.workloadsSampledAt,
              currentSampleAt > previousSampleAt else {
            return []
        }
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
                      workload.containsEstimatedFootprint == prior.containsEstimatedFootprint,
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
            // IDs. Choose the strongest deterministic value instead of
            // allowing array order to change the emitted event.
            if let existing = result[workload.id] {
                result[workload.id] = preferredWorkload(workload, over: existing)
            } else {
                result[workload.id] = workload
            }
        }
    }

    private func preferredWorkload(
        _ candidate: PersistedWorkloadRecord,
        over existing: PersistedWorkloadRecord
    ) -> PersistedWorkloadRecord {
        // Exact physical-footprint data is stronger evidence than RSS
        // fallback, even when the fallback happens to report a larger value.
        if candidate.containsEstimatedFootprint != existing.containsEstimatedFootprint {
            return candidate.containsEstimatedFootprint ? existing : candidate
        }
        if candidate.attributedFootprintBytes != existing.attributedFootprintBytes {
            return candidate.attributedFootprintBytes > existing.attributedFootprintBytes
                ? candidate
                : existing
        }
        if candidate.attributedResidentBytes != existing.attributedResidentBytes {
            return candidate.attributedResidentBytes > existing.attributedResidentBytes
                ? candidate
                : existing
        }
        if candidate.processCount != existing.processCount {
            return candidate.processCount > existing.processCount ? candidate : existing
        }
        if candidate.isSystem != existing.isSystem {
            return candidate.isSystem ? existing : candidate
        }
        if candidate.title != existing.title {
            return candidate.title < existing.title ? candidate : existing
        }
        return existing
    }

    private func isActionable(_ workload: PersistedWorkloadRecord) -> Bool {
        !workload.isSystem
            && !workload.id.hasPrefix("other-")
            && workload.attributedFootprintBytes >= workloadEventThresholdBytes
    }

    private func workloadDescending(_ lhs: PersistedWorkloadRecord, _ rhs: PersistedWorkloadRecord) -> Bool {
        if lhs.containsEstimatedFootprint != rhs.containsEstimatedFootprint {
            return !lhs.containsEstimatedFootprint
        }
        if lhs.attributedFootprintBytes != rhs.attributedFootprintBytes {
            return lhs.attributedFootprintBytes > rhs.attributedFootprintBytes
        }
        return lhs.id < rhs.id
    }

    private func eventID(kind: MemoryHistoryEventKind, timestamp: Date, target: String) -> String {
        let seconds = timestamp.timeIntervalSince1970
        // Event IDs are persisted/deduplicated keys, so they must not inherit
        // the user's grouping separators or numeral system. Display strings
        // elsewhere remain locale-aware; this key is intentionally POSIX.
        let timestampKey = String(
            format: "%.0f",
            locale: Locale(identifier: "en_US_POSIX"),
            seconds
        )
        return "\(kind.rawValue)-\(timestampKey)-\(target)"
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
    /// Last time the store durably wrote a snapshot or journal append. Nil
    /// means the current process has not written yet; it is not a claim that
    /// no prior process ever wrote.
    public let lastSuccessfulWriteAt: Date?
    public let fullReloadCount: Int
    public let generationFastPathCount: Int
    public let snapshotWriteBytes: Int
    public let segmentWriteCount: Int

    public init(
        snapshotBytes: Int,
        journalBytes: Int,
        pendingRecordCount: Int,
        journalRecordCount: Int,
        compactionCount: Int,
        lastCompactionAt: Date?,
        lastSuccessfulWriteAt: Date? = nil,
        fullReloadCount: Int = 0,
        generationFastPathCount: Int = 0,
        snapshotWriteBytes: Int = 0,
        segmentWriteCount: Int = 0
    ) {
        self.snapshotBytes = max(snapshotBytes, 0)
        self.journalBytes = max(journalBytes, 0)
        self.pendingRecordCount = max(pendingRecordCount, 0)
        self.journalRecordCount = max(journalRecordCount, 0)
        self.compactionCount = max(compactionCount, 0)
        self.lastCompactionAt = lastCompactionAt
        self.lastSuccessfulWriteAt = lastSuccessfulWriteAt
        self.fullReloadCount = max(fullReloadCount, 0)
        self.generationFastPathCount = max(generationFastPathCount, 0)
        self.snapshotWriteBytes = max(snapshotWriteBytes, 0)
        self.segmentWriteCount = max(segmentWriteCount, 0)
    }

    public var totalBytes: Int {
        let (value, overflow) = snapshotBytes.addingReportingOverflow(journalBytes)
        return overflow ? Int.max : value
    }
}

public enum HistoryStoreError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    case readFailed
    case writeFailed
    case fileTooLarge
    case lockTimedOut
    case invalidData
    case recoveryRequired
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .readFailed:
            return "无法读取 24 小时历史文件"
        case .writeFailed:
            return "无法写入 24 小时历史文件"
        case .fileTooLarge:
            return "24 小时历史文件超过安全大小限制"
        case .lockTimedOut:
            return "等待 24 小时历史文件锁超时"
        case .invalidData:
            return "24 小时历史文件格式无效或已损坏"
        case let .unsupportedVersion(version):
            return "不支持的历史文件版本 " + String(version)
        case .recoveryRequired:
            return "检测到未完成的数据恢复事务，请先运行 storage recover"
        }
    }

    public var errorDescription: String? { description }
}

/// Classifies a JSON byte prefix without relying on Foundation's localized
/// parser messages. Only an EOF reached while parsing an otherwise valid
/// prefix is recoverable as a crash-truncated final journal line.
private enum JSONPrefixState: Equatable {
    case complete
    case incomplete
    case invalid
}

private struct JSONPrefixScanner {
    private let bytes: [UInt8]
    private let maximumDepth: Int
    private var index = 0

    init(_ data: Data, maximumDepth: Int = PersistedDataLimit.jsonNestingDepth) {
        bytes = Array(data)
        self.maximumDepth = max(maximumDepth, 0)
    }

    mutating func scan() -> JSONPrefixState {
        switch validateUTF8(bytes) {
        case .invalid:
            return .invalid
        case .valid:
            break
        case let .truncated(prefixLength):
            // JSONEncoder emits non-ASCII UTF-8 inside strings. A crash can
            // cut a scalar after the final byte written, but bytes outside a
            // string are never a recoverable JSON tail.
            let prefix = Array(bytes[..<prefixLength])
            guard isInsideJSONString(prefix) else { return .invalid }
            var prefixScanner = JSONPrefixScanner(
                Data(prefix),
                maximumDepth: maximumDepth
            )
            return prefixScanner.scan() == .incomplete ? .incomplete : .invalid
        }
        skipWhitespace()
        let state = scanValue(depth: 0)
        guard state == .complete else { return state }
        skipWhitespace()
        return index == bytes.count ? .complete : .invalid
    }

    private mutating func scanValue(depth: Int) -> JSONPrefixState {
        guard let byte = current else { return .incomplete }
        switch byte {
        case 0x7B: // {
            guard depth < maximumDepth else { return .invalid }
            return scanObject(depth: depth + 1)
        case 0x5B: // [
            guard depth < maximumDepth else { return .invalid }
            return scanArray(depth: depth + 1)
        case 0x22: // "
            return scanString()
        case 0x74: // true
            return scanLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66: // false
            return scanLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E: // null
            return scanLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39:
            return scanNumber()
        default:
            return .invalid
        }
    }

    private mutating func scanObject(depth: Int) -> JSONPrefixState {
        index += 1
        skipWhitespace()
        guard let byte = current else { return .incomplete }
        if byte == 0x7D {
            index += 1
            return .complete
        }

        while true {
            guard current != nil else { return .incomplete }
            guard current == 0x22 else { return .invalid }
            let keyState = scanString()
            guard keyState == .complete else { return keyState }
            skipWhitespace()
            guard let separator = current else { return .incomplete }
            guard separator == 0x3A else { return .invalid }
            index += 1
            skipWhitespace()
            let valueState = scanValue(depth: depth)
            guard valueState == .complete else { return valueState }
            skipWhitespace()
            guard let terminator = current else { return .incomplete }
            if terminator == 0x7D {
                index += 1
                return .complete
            }
            guard terminator == 0x2C else { return .invalid }
            index += 1
            skipWhitespace()
            guard current != nil else { return .incomplete }
        }
    }

    private mutating func scanArray(depth: Int) -> JSONPrefixState {
        index += 1
        skipWhitespace()
        guard let byte = current else { return .incomplete }
        if byte == 0x5D {
            index += 1
            return .complete
        }

        while true {
            let valueState = scanValue(depth: depth)
            guard valueState == .complete else { return valueState }
            skipWhitespace()
            guard let terminator = current else { return .incomplete }
            if terminator == 0x5D {
                index += 1
                return .complete
            }
            guard terminator == 0x2C else { return .invalid }
            index += 1
            skipWhitespace()
            guard current != nil else { return .incomplete }
        }
    }

    private mutating func scanString() -> JSONPrefixState {
        guard current == 0x22 else { return .invalid }
        index += 1
        while let byte = current {
            index += 1
            switch byte {
            case 0x22:
                return .complete
            case 0x00...0x1F:
                return .invalid
            case 0x5C:
                guard let escaped = current else { return .incomplete }
                index += 1
                switch escaped {
                case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    continue
                case 0x75:
                    for _ in 0..<4 {
                        guard let hex = current else { return .incomplete }
                        guard isHexDigit(hex) else { return .invalid }
                        index += 1
                    }
                default:
                    return .invalid
                }
            default:
                continue
            }
        }
        return .incomplete
    }

    private mutating func scanLiteral(_ literal: [UInt8]) -> JSONPrefixState {
        for expected in literal {
            guard let byte = current else { return .incomplete }
            guard byte == expected else { return .invalid }
            index += 1
        }
        return .complete
    }

    private mutating func scanNumber() -> JSONPrefixState {
        if current == 0x2D {
            index += 1
            guard current != nil else { return .incomplete }
        }

        guard let first = current else { return .incomplete }
        if first == 0x30 {
            index += 1
            if let byte = current, (0x30...0x39).contains(byte) {
                return .invalid
            }
        } else if (0x31...0x39).contains(first) {
            index += 1
            consumeDigits()
        } else {
            return .invalid
        }

        if current == 0x2E {
            index += 1
            guard let digit = current else { return .incomplete }
            guard (0x30...0x39).contains(digit) else { return .invalid }
            consumeDigits()
        }

        if current == 0x65 || current == 0x45 {
            index += 1
            guard current != nil else { return .incomplete }
            if current == 0x2B || current == 0x2D {
                index += 1
                guard current != nil else { return .incomplete }
            }
            guard let digit = current, (0x30...0x39).contains(digit) else {
                return .invalid
            }
            consumeDigits()
        }
        return .complete
    }

    private mutating func consumeDigits() {
        while let byte = current, (0x30...0x39).contains(byte) {
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while let byte = current,
              byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A {
            index += 1
        }
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}

private enum UTF8ValidationResult {
    case valid
    case truncated(prefixLength: Int)
    case invalid
}

/// Validates UTF-8 without replacing malformed scalars. The positional
/// restrictions on E0/ED/F0/F4 reject overlong encodings, UTF-16 surrogates,
/// and code points above U+10FFFF.
private func validateUTF8(_ bytes: [UInt8]) -> UTF8ValidationResult {
    var index = 0
    while index < bytes.count {
        let lead = bytes[index]
        if lead <= 0x7F {
            index += 1
            continue
        }

        let expectedLength: Int
        switch lead {
        case 0xC2...0xDF:
            expectedLength = 2
        case 0xE0...0xEF:
            expectedLength = 3
        case 0xF0...0xF4:
            expectedLength = 4
        default:
            return .invalid
        }

        let availableLength = bytes.count - index
        let bytesToValidate = min(availableLength, expectedLength) - 1
        if bytesToValidate > 0 {
            for offset in 1...bytesToValidate {
                guard isValidUTF8Continuation(
                    bytes[index + offset],
                    lead: lead,
                    position: offset
                ) else {
                    return .invalid
                }
            }
        }
        guard availableLength >= expectedLength else {
            return .truncated(prefixLength: index)
        }
        index += expectedLength
    }
    return .valid
}

private func isValidUTF8Continuation(
    _ byte: UInt8,
    lead: UInt8,
    position: Int
) -> Bool {
    switch (lead, position) {
    case (0xE0, 1):
        return (0xA0...0xBF).contains(byte)
    case (0xF0, 1):
        // U+10000 starts at F0 90 80 80; 0x8F and below are overlong.
        return (0x90...0xBF).contains(byte)
    case (0xED, 1):
        return (0x80...0x9F).contains(byte)
    case (0xF4, 1):
        return (0x80...0x8F).contains(byte)
    default:
        return (0x80...0xBF).contains(byte)
    }
}

/// Reports whether a truncated scalar starts while the JSON lexer is inside
/// a string. This is intentionally lexical: the full JSON grammar is checked
/// by `JSONPrefixScanner` immediately afterwards.
private func isInsideJSONString(_ bytes: [UInt8]) -> Bool {
    var inString = false
    var escaped = false
    var unicodeEscapeDigits = 0

    for byte in bytes {
        if inString {
            if unicodeEscapeDigits > 0 {
                guard isHexDigit(byte) else { return false }
                unicodeEscapeDigits -= 1
                continue
            }
            if escaped {
                escaped = false
                if byte == 0x75 { // u
                    unicodeEscapeDigits = 4
                } else if ![0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte) {
                    return false
                }
                continue
            }
            switch byte {
            case 0x22:
                inString = false
            case 0x5C:
                escaped = true
            case 0x00...0x1F:
                return false
            default:
                continue
            }
        } else if byte == 0x22 {
            inString = true
        } else if byte >= 0x80 {
            // A non-ASCII scalar outside a JSON string is invalid JSON.
            return false
        }
    }

    return inString && !escaped && unicodeEscapeDigits == 0
}

private func isHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
        || (0x41...0x46).contains(byte)
        || (0x61...0x66).contains(byte)
}

private func isIncompleteJSONLine(_ data: Data) -> Bool {
    var scanner = JSONPrefixScanner(data)
    return scanner.scan() == .incomplete
}

private func isCompleteBoundedJSON(_ data: Data) -> Bool {
    var scanner = JSONPrefixScanner(data)
    return scanner.scan() == .complete
}

private struct HistoryDurableGeneration: Equatable {
    let snapshot: PersistedFileGeneration?
    let journal: PersistedFileGeneration?
    let clock: PersistedFileGeneration?
    let segments: [PersistedFileGeneration?]
}

/// Immutable, content-addressed chunks keep retention pruning bounded to the
/// two edges of the window. `records` makes older binaries reach their explicit
/// unsupported-version guard instead of treating the index as corrupt JSON.
private struct HistorySegmentIndex: Codable {
    let version: Int
    let records: [MemoryHistoryRecord]
    let segments: [HistorySegmentReference]
}

private struct HistorySegmentReference: Codable, Equatable {
    let bucket: Int64
    let digest: String
    var fileName: String { "segment-\(bucket)-\(digest).json" }
    var isValid: Bool {
        digest.count == 64 && digest.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

private struct HistoryCachedSegment {
    let reference: HistorySegmentReference
    let records: [MemoryHistoryRecord]
}

/// Resolves the small set of files written by the monitor.
///
/// Production callers continue to use the normal Application Support
/// directory unless the explicitly named UI-check environment variable is
/// present. The override is deliberately a path string rather than a URL so
/// the validation rules stay deterministic and easy to exercise without
/// mutating the process environment in tests.
public enum MemoryMonitorStoragePaths {
    public static let overrideEnvironmentKey = "MEMORY_MONITOR_UI_CHECK_STORAGE_ROOT"

    private static let directoryName = "MemoryMonitor"
    private static let historyFileName = "history.json"
    private static let auditFileName = "actions.jsonl"

    /// The unmodified application-support location used by normal launches.
    public static var defaultRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return base
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
    }

    /// Resolves an optional path override without touching global process
    /// state. Empty, relative, root-only, and otherwise malformed values are
    /// ignored so an accidental setting cannot redirect the store silently.
    public static func rootURL(
        overridePath: String?,
        fallbackRootURL: URL = Self.defaultRootURL
    ) -> URL {
        guard let overridePath else { return fallbackRootURL }
        let trimmed = overridePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.hasPrefix("/"),
              !trimmed.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return fallbackRootURL
        }

        let candidate = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        guard candidate.isFileURL,
              candidate.path.hasPrefix("/"),
              !candidate.path.isEmpty,
              candidate.path != "/" else {
            return fallbackRootURL
        }
        return candidate
    }

    /// Resolves the explicit UI-check override from an injected environment.
    /// Supplying an environment dictionary keeps unit tests deterministic.
    public static func rootURL(
        environment: [String: String],
        fallbackRootURL: URL = Self.defaultRootURL
    ) -> URL {
        rootURL(
            overridePath: environment[overrideEnvironmentKey],
            fallbackRootURL: fallbackRootURL
        )
    }

    /// Resolves a storage root for the paired isolated UI-check launch.
    /// Unlike the general override resolver, this entry point only accepts a
    /// canonical path below the host-provided Darwin user temporary directory
    /// or `/tmp`; the caller's `TMPDIR` value is never used as an anchor.
    /// Returning `nil` lets the app fail closed when the fixture switch and
    /// its storage root are not supplied together.
    public static func isolatedRootURL(
        environment: [String: String]
    ) -> URL? {
        isolatedRootURL(
            environment: environment,
            trustedTemporaryRoots: trustedTemporaryRootPaths()
        )
    }

    /// Test-only trust-root injection used to exercise path boundaries without
    /// mutating the process environment. Resolution performs read-only
    /// filesystem checks so dangling symlink escapes are rejected; production
    /// code must use the one-argument overload so callers cannot provide their
    /// own trust anchor.
    static func isolatedRootURL(
        environment: [String: String],
        trustedTemporaryRoots: [String]
    ) -> URL? {
        guard let rawOverride = environment[overrideEnvironmentKey] else {
            return nil
        }
        guard let candidatePath = canonicalTemporaryPath(rawOverride),
              let candidateBoundary = boundaryPath(candidatePath) else {
            return nil
        }

        let temporaryRoots = trustedTemporaryRoots.compactMap { rawRoot -> String? in
            guard let rootPath = canonicalTemporaryPath(rawRoot) else { return nil }
            return boundaryPath(rootPath)
        }
        guard temporaryRoots.contains(where: { root in
            candidateBoundary.hasPrefix(root + "/")
        }) else {
            return nil
        }
        return URL(fileURLWithPath: candidatePath, isDirectory: true)
    }

    /// Returns fixed system trust anchors. `confstr` is intentionally used
    /// instead of `TMPDIR` or `FileManager.temporaryDirectory`: both can be
    /// influenced by the caller's environment, while the Darwin user temp
    /// root remains the host-provided boundary for the current account.
    private static func trustedTemporaryRootPaths() -> [String] {
        var roots = ["/tmp"]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(
            Int32(_CS_DARWIN_USER_TEMP_DIR),
            &buffer,
            buffer.count
        )
        if length > 0,
           length < buffer.count,
           let root = String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8),
           !root.isEmpty {
            roots.insert(root, at: 0)
        }
        return roots
    }

    private static func canonicalTemporaryPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.hasPrefix("/"),
              !trimmed.contains(where: { $0 == "\n" || $0 == "\r" }),
              !trimmed.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              url.path != "/" else {
            return nil
        }
        return url.path
    }

    /// Resolve symlink components for boundary comparison, including a
    /// dangling link followed by a not-yet-created suffix. Foundation's
    /// `resolvingSymlinksInPath()` intentionally leaves that suffix untouched,
    /// which can otherwise make an escape look as though it were still below
    /// the trusted root. The returned path is used only for comparison; the
    /// public resolver keeps Foundation's established spelling (for example,
    /// `/tmp` rather than `/private/tmp`). Filesystem races remain the
    /// launcher's responsibility.
    private static func boundaryPath(_ path: String) -> String? {
        var pending = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var resolved: [String] = []
        var index = 0
        var symlinkDepth = 0

        while index < pending.count {
            let component = pending[index]
            index += 1

            if component == "." || component.isEmpty {
                continue
            }
            if component == ".." {
                guard !resolved.isEmpty else { return nil }
                resolved.removeLast()
                continue
            }

            var candidateComponents = resolved
            candidateComponents.append(component)
            let candidate = "/" + candidateComponents.joined(separator: "/")
            var information = stat()
            if lstat(candidate, &information) == 0 {
                let fileType = information.st_mode & S_IFMT
                if fileType == S_IFLNK {
                    symlinkDepth += 1
                    guard symlinkDepth <= 32 else { return nil }

                    var targetBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                    let targetLength = candidate.withCString { candidatePointer in
                        targetBuffer.withUnsafeMutableBufferPointer { buffer in
                            readlink(candidatePointer, buffer.baseAddress, buffer.count)
                        }
                    }
                    guard targetLength > 0,
                          targetLength < targetBuffer.count,
                          let target = String(
                              bytes: targetBuffer.prefix(Int(targetLength)).map {
                                  UInt8(bitPattern: $0)
                              },
                              encoding: .utf8
                          ),
                          !target.isEmpty else {
                        return nil
                    }

                    let remaining = Array(pending[index...])
                    pending = target.split(separator: "/", omittingEmptySubsequences: true)
                        .map(String.init) + remaining
                    index = 0
                    if target.hasPrefix("/") {
                        resolved.removeAll(keepingCapacity: true)
                    }
                    continue
                }

                // A non-directory component cannot have a meaningful child.
                if index < pending.count && fileType != S_IFDIR {
                    return nil
                }
            } else {
                switch errno {
                case ENOENT:
                    // No later component can currently be a symlink. Normalize
                    // the not-yet-created suffix lexically and finish.
                    resolved.append(component)
                    while index < pending.count {
                        let remaining = pending[index]
                        index += 1
                        if remaining == "." || remaining.isEmpty {
                            continue
                        }
                        if remaining == ".." {
                            guard !resolved.isEmpty else { return nil }
                            resolved.removeLast()
                        } else {
                            resolved.append(remaining)
                        }
                    }
                    guard !resolved.isEmpty else { return nil }
                    return "/" + resolved.joined(separator: "/")
                default:
                    return nil
                }
            }

            resolved.append(component)
        }

        guard !resolved.isEmpty else { return nil }
        return "/" + resolved.joined(separator: "/")
    }

    public static func historyFileURL(root: URL) -> URL {
        root.appendingPathComponent(historyFileName, isDirectory: false)
    }

    public static func auditFileURL(root: URL) -> URL {
        root.appendingPathComponent(auditFileName, isDirectory: false)
    }

    /// Root selected for the current process. This is the only entry point
    /// that reads ProcessInfo; tests should use one of the pure overloads.
    public static var currentRootURL: URL {
        rootURL(environment: ProcessInfo.processInfo.environment)
    }
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
    /// Tolerate a small clock skew, but never let a far-future sample stay in
    /// a retention window indefinitely.
    public static let maximumFutureSkew: TimeInterval = 5 * 60
    /// Freshness markers describe the sample carried by a minute bucket. A
    /// marker from a distant wall-clock era is rejected at write boundaries;
    /// old files remain readable and are filtered by history analysis.
    public static let maximumFreshnessMarkerRecordSkew: TimeInterval = 5 * 60
    /// Prevent floating-point retention arithmetic from overflowing and
    /// turning a bounded store into an effectively unbounded one.
    public static let maximumRetentionInterval: TimeInterval = 10 * 365 * 24 * 60 * 60
    public static let defaultMaxPersistedWorkloads = 40
    public static let defaultCompactionRecordThreshold = 120
    public static let defaultCompactionByteThreshold = 1 * 1024 * 1024
    public static let maximumSnapshotFileBytes = 128 * 1024 * 1024
    public static let maximumJournalFileBytes = 64 * 1024 * 1024
    public static let maximumJournalLineBytes = 1 * 1024 * 1024
    public static let maximumClockFileBytes = PersistedDataLimit.clockBytes
    public static let defaultLockTimeoutSeconds: TimeInterval = 2

    public static var defaultFileURL: URL {
        MemoryMonitorStoragePaths.historyFileURL(
            root: MemoryMonitorStoragePaths.currentRootURL
        )
    }

    public nonisolated let fileURL: URL
    /// A sidecar append-only file. It is intentionally derived from
    /// `fileURL`, so custom/test stores remain self-contained.
    public nonisolated let journalURL: URL
    private let clockURL: URL
    private let lockURL: URL
    private let segmentsURL: URL
    private var segmentCache: [Int64: HistoryCachedSegment] = [:]
    private var usesSegmentIndex = false
    private var snapshotWriteBytes = 0
    private var segmentWriteCount = 0
    private static let segmentSeconds: TimeInterval = 15 * 60
    private static let maximumSegmentCount = 16_384
    public let retentionInterval: TimeInterval
    public let maxPersistedWorkloads: Int
    public let compactionRecordThreshold: Int
    public let compactionByteThreshold: Int
    public let lockTimeoutSeconds: TimeInterval

    private var records: [MemoryHistoryRecord] = []
    private var hasLoaded = false
    private var dirty = false
    private var lastPersistedMinute: Date?
    private var pendingRecords: [Date: MemoryHistoryRecord] = [:]
    private var pendingWriteNeedsRetry = false
    private var journalRecordCount = 0
    private var journalByteCount = 0
    private var snapshotExists = false
    private var compactionCount = 0
    private var lastCompactionAt: Date?
    private var lastSuccessfulWriteAt: Date?
    /// Highest validated wall-clock instant observed by this store. The
    /// sidecar anchor restores it after a restart so a clock rollback cannot
    /// make otherwise-valid history look like far-future garbage.
    private var lastObservedNow: Date?
    /// Once an empty durable view has been established, a leftover sidecar no
    /// longer protects any records. Ignore it until the next successful write
    /// so resetting history cannot make the first new sample look expired.
    private var ignorePersistedClockAnchorUntilWrite = false
    private var durableGeneration: HistoryDurableGeneration?
    private var fullReloadCount = 0
    private var generationFastPathCount = 0

    public init(
        fileURL: URL = HistoryStore.defaultFileURL,
        retentionInterval: TimeInterval = HistoryStore.defaultRetentionInterval,
        maxPersistedWorkloads: Int = HistoryStore.defaultMaxPersistedWorkloads,
        compactionRecordThreshold: Int = HistoryStore.defaultCompactionRecordThreshold,
        compactionByteThreshold: Int = HistoryStore.defaultCompactionByteThreshold,
        lockTimeoutSeconds: TimeInterval = HistoryStore.defaultLockTimeoutSeconds
    ) {
        self.fileURL = fileURL
        self.journalURL = URL(fileURLWithPath: fileURL.path + ".journal")
        self.clockURL = URL(fileURLWithPath: fileURL.path + ".clock")
        self.lockURL = URL(fileURLWithPath: fileURL.path + ".lock")
        self.segmentsURL = URL(fileURLWithPath: fileURL.path + ".segments", isDirectory: true)
        // An unbounded or NaN retention value would silently disable pruning
        // and allow the local file to grow forever. Fall back to the bounded
        // product default for non-finite input.
        self.retentionInterval = retentionInterval.isFinite
            ? min(max(retentionInterval, 0), Self.maximumRetentionInterval)
            : Self.defaultRetentionInterval
        self.maxPersistedWorkloads = max(maxPersistedWorkloads, 1)
        self.compactionRecordThreshold = max(compactionRecordThreshold, 1)
        self.compactionByteThreshold = max(compactionByteThreshold, 1)
        self.lockTimeoutSeconds = lockTimeoutSeconds.isFinite && lockTimeoutSeconds >= 0
            ? lockTimeoutSeconds
            : Self.defaultLockTimeoutSeconds
    }

    private var clockRollbackLimit: TimeInterval {
        min(
            max(retentionInterval, 0) + Self.maximumFutureSkew,
            Self.maximumRetentionInterval
        )
    }

    /// Advances the in-memory anchor monotonically and returns the reference
    /// used for retention. A disk anchor that is implausibly far ahead is
    /// discarded instead of allowing an arbitrary future value to survive.
    private func retentionReferenceNow(_ now: Date) -> Date {
        if hasLoaded,
           records.isEmpty,
           pendingRecords.isEmpty,
           !dirty {
            lastObservedNow = now
            ignorePersistedClockAnchorUntilWrite = true
            return now
        }

        let diskAnchor = ignorePersistedClockAnchorUntilWrite
            ? nil
            : readClockAnchor(at: clockURL)
        var candidate = lastObservedNow
        if let diskAnchor, (candidate == nil || diskAnchor > candidate!) {
            candidate = diskAnchor
        }
        let reference = boundedRetentionReference(
            now: now,
            anchor: candidate,
            rollbackLimit: clockRollbackLimit
        )
        if reference == now, let candidate,
           candidate.timeIntervalSince(now).isFinite,
           candidate.timeIntervalSince(now) > clockRollbackLimit {
            lastObservedNow = now
        } else if let current = lastObservedNow {
            if now > current { lastObservedNow = now }
        } else {
            lastObservedNow = now
        }
        if let candidate, candidate <= now || reference == candidate {
            lastObservedNow = max(lastObservedNow ?? now, candidate)
        }
        return reference
    }

    private func persistClockAnchor(at date: Date) throws {
        guard isPersistableDate(date) else { throw HistoryStoreError.invalidData }
        let previousAnchorData = try? readBoundedFile(
            at: clockURL,
            maximumBytes: Self.maximumClockFileBytes
        )
        let previousObservedNow = lastObservedNow
        let previousIgnorePersistedAnchor = ignorePersistedClockAnchorUntilWrite
        let observedAt: Date
        var candidates = [date]
        if let current = lastObservedNow {
            candidates.append(current)
        }
        if !ignorePersistedClockAnchorUntilWrite,
           let disk = readClockAnchor(at: clockURL),
           disk > date,
           disk.timeIntervalSince(date).isFinite,
           disk.timeIntervalSince(date) <= clockRollbackLimit {
            candidates.append(disk)
        }
        observedAt = candidates.max() ?? date
        lastObservedNow = observedAt
        let data: Data
        do {
            data = try clockAnchorData(for: observedAt)
            guard data.count <= Self.maximumClockFileBytes else {
                throw HistoryStoreError.fileTooLarge
            }
            try prepareDirectory()
            try data.write(to: clockURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: clockURL.path
            )
            ignorePersistedClockAnchorUntilWrite = false
        } catch let error as HistoryStoreError {
            lastObservedNow = previousObservedNow
            ignorePersistedClockAnchorUntilWrite = previousIgnorePersistedAnchor
            if let previousAnchorData {
                try? previousAnchorData.write(to: clockURL, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: clockURL.path
                )
            } else {
                try? FileManager.default.removeItem(at: clockURL)
            }
            throw error
        } catch {
            lastObservedNow = previousObservedNow
            ignorePersistedClockAnchorUntilWrite = previousIgnorePersistedAnchor
            if let previousAnchorData {
                try? previousAnchorData.write(to: clockURL, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: clockURL.path
                )
            } else {
                try? FileManager.default.removeItem(at: clockURL)
            }
            throw HistoryStoreError.writeFailed
        }
    }

    private func withStoreLock<T>(
        failure: HistoryStoreError,
        _ body: () throws -> T
    ) throws -> T {
        do {
            let maintenanceDescriptor = try MaintenanceLock.acquire(
                root: fileURL.deletingLastPathComponent(),
                mode: .shared,
                timeoutSeconds: lockTimeoutSeconds
            )
            defer { MaintenanceLock.release(maintenanceDescriptor) }
            guard !MaintenanceTransaction.exists(root: fileURL.deletingLastPathComponent()) else {
                throw HistoryStoreError.recoveryRequired
            }
            let lockDescriptor = try acquireExclusivePersistedFileLock(
                at: lockURL,
                timeoutSeconds: lockTimeoutSeconds
            )
            defer { releaseExclusivePersistedFileLock(lockDescriptor) }
            try validateFileSize(
                at: fileURL,
                maximumBytes: Self.maximumSnapshotFileBytes
            )
            try validateFileSize(
                at: journalURL,
                maximumBytes: Self.maximumJournalFileBytes
            )
            try validateFileSize(
                at: clockURL,
                maximumBytes: Self.maximumClockFileBytes
            )
            let result = try body()
            durableGeneration = try currentDurableGeneration()
            return result
        } catch let error as HistoryStoreError {
            durableGeneration = nil
            throw error
        } catch BoundedFileReadError.tooLarge {
            durableGeneration = nil
            throw HistoryStoreError.fileTooLarge
        } catch PersistedFileLockError.timedOut {
            durableGeneration = nil
            throw HistoryStoreError.lockTimedOut
        } catch PersistedFileLockError.cancelled {
            durableGeneration = nil
            throw CancellationError()
        } catch is CancellationError {
            durableGeneration = nil
            throw CancellationError()
        } catch MaintenanceLockError.timedOut {
            durableGeneration = nil
            throw HistoryStoreError.lockTimedOut
        } catch {
            durableGeneration = nil
            throw failure
        }
    }

    private func currentDurableGeneration() throws -> HistoryDurableGeneration {
        HistoryDurableGeneration(
            snapshot: try persistedFileGeneration(at: fileURL),
            journal: try persistedFileGeneration(at: journalURL),
            clock: try persistedFileGeneration(at: clockURL),
            segments: try segmentCache.values.sorted { $0.reference.bucket < $1.reference.bucket }.map {
                try persistedFileGeneration(at: segmentsURL.appendingPathComponent($0.reference.fileName))
            }
        )
    }

    public func diagnostics() -> HistoryStoreDiagnostics {
        HistoryStoreDiagnostics(
            snapshotBytes: byteCount(at: fileURL) + segmentCache.values.reduce(0) {
                $0 + byteCount(at: segmentsURL.appendingPathComponent($1.reference.fileName))
            },
            journalBytes: byteCount(at: journalURL),
            pendingRecordCount: pendingRecords.count,
            journalRecordCount: journalRecordCount,
            compactionCount: compactionCount,
            lastCompactionAt: lastCompactionAt,
            lastSuccessfulWriteAt: lastSuccessfulWriteAt,
            fullReloadCount: fullReloadCount,
            generationFastPathCount: generationFastPathCount,
            snapshotWriteBytes: snapshotWriteBytes,
            segmentWriteCount: segmentWriteCount
        )
    }

    @discardableResult
    public func load(now: Date = Date()) throws -> [MemoryHistoryRecord] {
        guard isPersistableDate(now) else {
            throw HistoryStoreError.invalidData
        }
        return try withStoreLock(failure: .readFailed) {
            if hasLoaded {
                // A previously loaded actor may still have a valid in-memory
                // view when the backing path becomes unreadable. Read APIs
                // must surface that failure so health/UI callers do not
                // mistake stale data for a successful refresh. Write paths
                // intentionally keep the boolean fallback semantics below.
                guard try synchronizeDurableViewLocked(now: now) else {
                    throw HistoryStoreError.readFailed
                }
                return records
            }
            return try loadLocked(now: now)
        }
    }

    @discardableResult
    private func loadLocked(now: Date) throws -> [MemoryHistoryRecord] {
        guard isPersistableDate(now) else {
            throw HistoryStoreError.invalidData
        }
        let referenceNow = retentionReferenceNow(now)
        guard !hasLoaded else {
            let before = records
            records = Self.pruned(
                coalesced(records),
                now: referenceNow,
                retentionInterval: retentionInterval
            )
            if records != before {
                dirty = true
                try compactSnapshot(at: now)
            }
            return records
        }

        let fileManager = FileManager.default
        let hasSnapshot = fileManager.fileExists(atPath: fileURL.path)
        let hasJournal = fileManager.fileExists(atPath: journalURL.path)
        // An orphaned segmented store cannot be reconstructed from a journal
        // containing only recent increments. Preserve it for explicit repair.
        if !hasSnapshot, fileManager.fileExists(atPath: segmentsURL.path) {
            throw HistoryStoreError.readFailed
        }
        var snapshotRecords: [MemoryHistoryRecord] = []
        var snapshotData = Data()
        var snapshotError: HistoryStoreError?

        if hasSnapshot {
            do {
                snapshotData = try readBoundedFile(
                    at: fileURL,
                    maximumBytes: Self.maximumSnapshotFileBytes
                )
            } catch BoundedFileReadError.tooLarge {
                snapshotError = .fileTooLarge
            } catch {
                snapshotError = .readFailed
            }

            if snapshotError == nil {
                do {
                    guard isCompleteBoundedJSON(snapshotData) else {
                        throw HistoryStoreError.invalidData
                    }
                    let file = try Self.decoder().decode(MemoryHistoryFile.self, from: snapshotData)
                    if file.version == 2 {
                        usesSegmentIndex = true
                        // Do not recover a broken v2 index/segment from a journal
                        // that may contain only a fraction of the retained view.
                        snapshotRecords = try loadSegments(from: snapshotData)
                    } else {
                        guard file.version == MemoryHistoryFile.currentVersion else {
                            throw HistoryStoreError.unsupportedVersion(file.version)
                        }
                        snapshotRecords = file.records
                    }
                } catch BoundedFileReadError.tooLarge {
                    snapshotError = .fileTooLarge
                } catch let error as HistoryStoreError {
                    snapshotError = error
                } catch {
                    snapshotError = .invalidData
                }
            }
        }

        var journalRecords: [MemoryHistoryRecord] = []
        var journalData = Data()
        var journalError: HistoryStoreError?
        if hasJournal {
            do {
                journalData = try readBoundedFile(
                    at: journalURL,
                    maximumBytes: Self.maximumJournalFileBytes
                )
            } catch BoundedFileReadError.tooLarge {
                journalError = .fileTooLarge
            } catch {
                journalError = .readFailed
            }
            if journalError == nil {
                do {
                    let decodedJournal = try decodeJournal(journalData)
                    journalRecords = decodedJournal.records
                    if decodedJournal.validByteCount < journalData.count {
                        journalData = Data(journalData.prefix(decodedJournal.validByteCount))
                        do {
                            try journalData.write(to: journalURL, options: [.atomic])
                            try fileManager.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath: journalURL.path
                            )
                        } catch {
                            throw HistoryStoreError.writeFailed
                        }
                    }
                } catch let error as HistoryStoreError {
                    journalError = error
                } catch {
                    journalError = .invalidData
                }
            }
        }

        // A malformed journal is never silently ignored: unlike a damaged
        // snapshot it may contain the only copy of the newest records.
        if let journalError {
            throw journalError
        }
        // A damaged or unreadable snapshot can be rebuilt from a successfully
        // decoded journal. Unsupported versions remain hard failures so a
        // newer file is never overwritten by an older binary.
        if let snapshotError {
            // A damaged/unreadable snapshot can be reconstructed from a
            // valid journal. Unsupported versions remain hard failures so a
            // newer file is never overwritten by this binary.
            guard !usesSegmentIndex,
                  !fileManager.fileExists(atPath: segmentsURL.path),
                  (snapshotError == .invalidData || snapshotError == .readFailed),
                  !journalRecords.isEmpty else {
                throw snapshotError
            }
        }

        let coalescedRecords = coalesced(snapshotRecords + journalRecords)
        let compactedRecords = Self.compactingWorkloads(
            coalescedRecords,
            limit: maxPersistedWorkloads
        )
        records = Self.pruned(
            compactedRecords,
            now: referenceNow,
            retentionInterval: retentionInterval
        )
        hasLoaded = true
        snapshotExists = hasSnapshot
        journalRecordCount = journalRecords.count
        journalByteCount = journalData.count
        pendingRecords.removeAll(keepingCapacity: false)
        pendingWriteNeedsRetry = false
        dirty = false
        lastPersistedMinute = records.last?.timestamp

        let canonicalSnapshot: Data
        do {
            canonicalSnapshot = usesSegmentIndex ? Data()
                : try Self.encoder().encode(MemoryHistoryFile(records: records))
            guard canonicalSnapshot.count <= Self.maximumSnapshotFileBytes else {
                throw HistoryStoreError.fileTooLarge
            }
        } catch let error as HistoryStoreError {
            dirty = true
            throw error
        } catch {
            // Keep the actor retryable if a malformed value somehow made it
            // through decoding. The caller may repair the source and call
            // `flush()`/`load()` again instead of being left in a clean state.
            dirty = true
            throw HistoryStoreError.invalidData
        }
        let needsCompaction = (!hasSnapshot && !journalRecords.isEmpty)
            || (snapshotError != nil && !journalRecords.isEmpty)
            || (records != coalescedRecords)
            || (hasSnapshot && !hasJournal && !usesSegmentIndex && snapshotData != canonicalSnapshot)
        if needsCompaction {
            do {
                try compactSnapshot(at: now)
            } catch {
                // `hasLoaded` intentionally remains true so a later flush can
                // retry the repair. Do not report a clean store after a
                // successful parse followed by a failed write.
                dirty = true
                throw error
            }
        }
        // Legacy files may predate the clock sidecar. Establish the anchor
        // after their contents have been validated so a later wall-clock
        // rollback cannot prune otherwise-valid history.
        if (hasSnapshot || hasJournal), readClockAnchor(at: clockURL) == nil {
            do {
                try persistClockAnchor(at: now)
            } catch {
                dirty = true
                throw error
            }
        }
        if usesSegmentIndex {
            try removeUnreferencedSegments()
        }
        return records
    }

    /// Discards only the in-memory durable view before re-reading the files.
    /// The monotonic clock anchor and diagnostic counters intentionally stay
    /// local to this actor; the record/journal counters are rebuilt by load.
    private func resetDurableViewForReload() {
        records.removeAll(keepingCapacity: false)
        pendingRecords.removeAll(keepingCapacity: false)
        pendingWriteNeedsRetry = false
        journalRecordCount = 0
        journalByteCount = 0
        snapshotExists = false
        lastPersistedMinute = nil
        dirty = false
        hasLoaded = false
        segmentCache = [:]
        usesSegmentIndex = false
    }

    private func reloadFromDiskLocked(now: Date) throws {
        resetDurableViewForReload()
        _ = try loadLocked(now: now)
    }

    /// Refreshes the durable view while preserving records from a prior
    /// failed/pending local write. The lock makes the disk read and any later
    /// rewrite one transaction; without this step a stale actor could compact
    /// away a journal line committed by another instance.
    @discardableResult
    private func synchronizeDurableViewLocked(now: Date) throws -> Bool {
        guard hasLoaded else {
            _ = try loadLocked(now: now)
            return true
        }

        if let durableGeneration,
           let currentGeneration = try? currentDurableGeneration(),
           durableGeneration == currentGeneration {
            generationFastPathCount += 1
            return true
        }
        fullReloadCount += 1

        let preserveLocal = dirty || pendingWriteNeedsRetry || !pendingRecords.isEmpty
        let localRecords = preserveLocal ? records : []
        let localRetry = pendingWriteNeedsRetry

        // Keep a complete rollback point. A failed read (for example, a test
        // or a transient filesystem race replacing the target with a
        // directory) must not erase an in-memory pending sample.
        let savedRecords = records
        let savedPendingRecords = pendingRecords
        let savedPendingRetry = pendingWriteNeedsRetry
        let savedJournalRecordCount = journalRecordCount
        let savedJournalByteCount = journalByteCount
        let savedSnapshotExists = snapshotExists
        let savedLastPersistedMinute = lastPersistedMinute
        let savedDirty = dirty
        let savedHasLoaded = hasLoaded
        let savedLastObservedNow = lastObservedNow
        let savedIgnorePersistedAnchor = ignorePersistedClockAnchorUntilWrite
        let savedSegmentCache = segmentCache
        let savedUsesSegmentIndex = usesSegmentIndex
        do {
            try reloadFromDiskLocked(now: now)
        } catch let error as HistoryStoreError {
            records = savedRecords
            pendingRecords = savedPendingRecords
            pendingWriteNeedsRetry = savedPendingRetry
            journalRecordCount = savedJournalRecordCount
            journalByteCount = savedJournalByteCount
            snapshotExists = savedSnapshotExists
            lastPersistedMinute = savedLastPersistedMinute
            dirty = savedDirty
            hasLoaded = savedHasLoaded
            lastObservedNow = savedLastObservedNow
            ignorePersistedClockAnchorUntilWrite = savedIgnorePersistedAnchor
            segmentCache = savedSegmentCache
            usesSegmentIndex = savedUsesSegmentIndex
            if error == .readFailed {
                // A write operation can encounter a target that is
                // temporarily unreadable (for example, a path replaced by a
                // directory). Keep the last known-good view and let the
                // caller stage its record; the actual write path then reports
                // writeFailed and leaves the state retryable. Malformed data
                // and unsupported versions must still stop the operation.
                return false
            }
            throw error
        } catch {
            records = savedRecords
            pendingRecords = savedPendingRecords
            pendingWriteNeedsRetry = savedPendingRetry
            journalRecordCount = savedJournalRecordCount
            journalByteCount = savedJournalByteCount
            snapshotExists = savedSnapshotExists
            lastPersistedMinute = savedLastPersistedMinute
            dirty = savedDirty
            hasLoaded = savedHasLoaded
            lastObservedNow = savedLastObservedNow
            ignorePersistedClockAnchorUntilWrite = savedIgnorePersistedAnchor
            segmentCache = savedSegmentCache
            usesSegmentIndex = savedUsesSegmentIndex
            throw error
        }
        guard preserveLocal else { return true }

        let diskRecords = records
        let referenceNow = retentionReferenceNow(now)
        let mergedRecords = Self.pruned(
            Self.compactingWorkloads(
                coalesced(diskRecords + localRecords),
                limit: maxPersistedWorkloads
            ),
            now: referenceNow,
            retentionInterval: retentionInterval
        )
        records = mergedRecords
        let diskByTimestamp = Dictionary(uniqueKeysWithValues: diskRecords.map { ($0.timestamp, $0) })
        pendingRecords = Dictionary(uniqueKeysWithValues: mergedRecords.compactMap { record in
            guard diskByTimestamp[record.timestamp] != record else { return nil }
            return (record.timestamp, record)
        })
        let changed = mergedRecords != diskRecords
        dirty = changed
        pendingWriteNeedsRetry = localRetry && !pendingRecords.isEmpty
        if !changed {
            pendingRecords.removeAll(keepingCapacity: false)
            pendingWriteNeedsRetry = false
        }
        return true
    }

    /// A fresh instance is loaded under the caller's file lock. An already
    /// loaded instance is refreshed and any local pending value is merged.
    private func synchronizeBeforeAppendLocked(now: Date) throws -> Bool {
        try synchronizeDurableViewLocked(now: now)
    }

    @discardableResult
    public func append(
        snapshot: SystemMemorySnapshot,
        groups: [WorkloadGroupSnapshot] = [],
        workloadsSampledAt: Date? = nil,
        workloadInventoryIsComplete: Bool? = nil,
        now: Date = Date()
    ) throws -> [MemoryHistoryRecord] {
        try append(
            MemoryHistoryRecord(
                snapshot: snapshot,
                groups: groups,
                // Preserve the historical convenience behavior for this
                // overload: callers that provide groups but no marker have
                // traditionally meant "captured with this snapshot".
                workloadsSampledAt: workloadsSampledAt ?? (groups.isEmpty ? nil : snapshot.timestamp),
                workloadInventoryIsComplete: workloadInventoryIsComplete
            ),
            now: now
        )
    }

    @discardableResult
    public func append(_ record: MemoryHistoryRecord, now: Date = Date()) throws -> [MemoryHistoryRecord] {
        guard isPersistableDate(now) else {
            throw HistoryStoreError.invalidData
        }
        return try withStoreLock(failure: .writeFailed) {
            try appendLocked(record, now: now)
        }
    }

    @discardableResult
    private func appendLocked(_ record: MemoryHistoryRecord, now: Date) throws -> [MemoryHistoryRecord] {
        let sourceSampleIsFresh = record.sourceSampledAt.map {
            isWithinFutureSkew($0, now: now, allowance: Self.maximumFutureSkew)
        } ?? true
        let workloadSampleIsFresh = record.workloadsSampledAt.map {
            isWithinFutureSkew($0, now: now, allowance: Self.maximumFutureSkew)
        } ?? true
        guard isPersistableDate(now),
              record.hasValidPersistedFields,
              Self.hasFreshnessMarkersNearRecord(record),
              isWithinFutureSkew(record.timestamp, now: now, allowance: Self.maximumFutureSkew),
              sourceSampleIsFresh,
              workloadSampleIsFresh else {
            throw HistoryStoreError.invalidData
        }
        let didSynchronize = try synchronizeBeforeAppendLocked(now: now)
        if !didSynchronize {
            // Force a canonical rewrite after a failed refresh. Appending a
            // journal line against an unreadable snapshot could otherwise
            // leave the new record stranded behind the damaged path.
            dirty = true
        }
        let referenceNow = retentionReferenceNow(now)

        let normalized = normalized(record)
        let recordsBeforeAppend = records
        let existingIndex = records.firstIndex(where: { $0.timestamp == normalized.timestamp })
        if let index = existingIndex {
            records[index] = merged(existing: records[index], candidate: normalized)
        } else {
            records.append(normalized)
        }
        let sortedRecords = records.sorted { $0.timestamp < $1.timestamp }
        records = Self.pruned(
            sortedRecords,
            now: referenceNow,
            retentionInterval: retentionInterval
        )
        let recordsChanged = records != recordsBeforeAppend

        if recordsChanged {
            dirty = true
            if let retained = records.first(where: { $0.timestamp == normalized.timestamp }) {
                pendingRecords[normalized.timestamp] = retained
            } else {
                // A caller may backfill a sample older than the retention
                // window. It must not be resurrected in the journal after
                // being pruned from the in-memory snapshot.
                pendingRecords.removeValue(forKey: normalized.timestamp)
            }
            // Pruning is a deletion from the persisted view. A journal append
            // cannot represent that deletion, so compact the canonical
            // snapshot instead of leaving expired rows on disk.
            pendingRecords = pendingRecords.filter { entry in
                records.contains(entry.value)
            }
        }

        guard recordsChanged else {
            // A previous journal/compaction failure may have left the value
            // unchanged but still dirty. Retry only after an actual failure;
            // ordinary same-minute updates remain coalesced in memory.
            if pendingWriteNeedsRetry {
                try appendPending(at: now)
            } else if !didSynchronize || (dirty && pendingRecords.isEmpty) {
                try compactSnapshot(at: now)
            }
            return records
        }

        // The first sample creates a compact snapshot. Later samples append a
        // single line when the minute changes; updates within one minute stay
        // in memory until the next boundary or an explicit flush.
        let removedExpiredRecords = records.count < sortedRecords.count
        if removedExpiredRecords || !didSynchronize {
            do {
                try compactSnapshot(at: now)
            } catch {
                dirty = true
                throw error
            }
        } else if !snapshotExists {
            // Avoid creating an empty snapshot for a record that was already
            // outside the retention window and therefore produced no state.
            if !records.isEmpty || journalRecordCount > 0 || !pendingRecords.isEmpty {
                do {
                    try compactSnapshot(at: now)
                } catch {
                    dirty = true
                    throw error
                }
            } else {
                dirty = false
            }
        } else if lastPersistedMinute != normalized.timestamp {
            try appendPending(at: now)
        }
        return records
    }

    public func currentRecords(now: Date = Date()) throws -> [MemoryHistoryRecord] {
        guard isPersistableDate(now) else {
            throw HistoryStoreError.invalidData
        }
        return try withStoreLock(failure: .readFailed) {
            try currentRecordsLocked(now: now)
        }
    }

    private func currentRecordsLocked(now: Date) throws -> [MemoryHistoryRecord] {
        guard isPersistableDate(now) else {
            throw HistoryStoreError.invalidData
        }
        guard try synchronizeDurableViewLocked(now: now) else {
            throw HistoryStoreError.readFailed
        }
        let referenceNow = retentionReferenceNow(now)
        let before = records
        records = Self.pruned(records, now: referenceNow, retentionInterval: retentionInterval)
        if records != before {
            dirty = true
            pendingRecords = pendingRecords.filter { records.contains($0.value) }
            try compactSnapshot(at: now)
        }
        return records
    }

    /// Persists pending minute records using the caller's sample/diagnostic
    /// clock. Keeping one validated instant for the whole operation makes
    /// retries deterministic and avoids a wall-clock jump between journal and
    /// snapshot writes.
    public func flush(now: Date = Date()) throws {
        guard isPersistableDate(now) else {
            throw HistoryStoreError.invalidData
        }
        return try withStoreLock(failure: .writeFailed) {
            try flushLocked(now: now)
        }
    }

    private func flushLocked(now: Date) throws {
        guard isPersistableDate(now) else {
            throw HistoryStoreError.invalidData
        }
        guard hasLoaded else { return }
        // `flush()` historically persisted the actor's current view without
        // applying a new retention pass. When a caller supplies a synthetic
        // timestamp (or the wall clock has jumped far ahead), reloading with
        // the current wall clock would incorrectly discard that view. Reuse
        // the latest trusted anchor for the synchronization read in that
        // case; the actual write still records the caller's validated time.
        let synchronizationNow: Date
        if let observed = lastObservedNow,
           isPersistableDate(observed),
           now.timeIntervalSince(observed).isFinite,
           now.timeIntervalSince(observed) > clockRollbackLimit {
            synchronizationNow = observed
        } else {
            synchronizationNow = now
        }
        try synchronizeDurableViewLocked(now: synchronizationNow)
        if !pendingRecords.isEmpty {
            try appendPending(at: now)
        }
        guard dirty || journalRecordCount > 0 else { return }
        try compactSnapshot(at: now)
    }

    /// Merges records accumulated by a caller while the durable store was
    /// unavailable. Records are normalized/coalesced once and written through
    /// a single snapshot compaction, avoiding one disk write per recovered
    /// sample. The actor remains dirty if compaction fails so a later retry can
    /// safely continue.
    @discardableResult
    public func merge(
        records incoming: [MemoryHistoryRecord],
        now: Date = Date()
    ) throws -> [MemoryHistoryRecord] {
        guard isPersistableDate(now) else {
            throw HistoryStoreError.invalidData
        }
        return try withStoreLock(failure: .writeFailed) {
            try mergeLocked(records: incoming, now: now)
        }
    }

    private func mergeLocked(
        records incoming: [MemoryHistoryRecord],
        now: Date
    ) throws -> [MemoryHistoryRecord] {
        guard isPersistableDate(now),
              incoming.allSatisfy({ record in
                  record.hasValidPersistedFields
                      && Self.hasFreshnessMarkersNearRecord(record)
                      && isWithinFutureSkew(record.timestamp, now: now, allowance: Self.maximumFutureSkew)
                      && (record.sourceSampledAt.map {
                          isWithinFutureSkew($0, now: now, allowance: Self.maximumFutureSkew)
                      } ?? true)
                      && (record.workloadsSampledAt.map {
                          isWithinFutureSkew($0, now: now, allowance: Self.maximumFutureSkew)
                      } ?? true)
              }) else {
            throw HistoryStoreError.invalidData
        }
        if !hasLoaded {
            _ = try loadLocked(now: now)
        }
        try synchronizeDurableViewLocked(now: now)
        guard !incoming.isEmpty else { return records }

        let referenceNow = retentionReferenceNow(now)
        let before = records
        let mergedRecords = Self.pruned(
            Self.compactingWorkloads(
                coalesced(records + incoming),
                limit: maxPersistedWorkloads
            ),
            now: referenceNow,
            retentionInterval: retentionInterval
        )
        records = mergedRecords
        let changed = records != before
        if changed {
            dirty = true
        }

        // Even when values are already present, a pending journal or dirty
        // flag means the durable representation still needs repair. A store
        // with no records at all should remain absent on disk: merging only
        // expired recovery entries must not create an empty snapshot.
        let needsCompaction = changed
            || dirty
            || journalRecordCount > 0
            || (!snapshotExists && !records.isEmpty)
        guard needsCompaction else {
            return records
        }
        do {
            try compactSnapshot(at: now)
        } catch {
            // Keep the actor retryable even when the state did not change
            // before the write attempt (for example, a journal-only repair).
            dirty = true
            throw error
        }
        return records
    }

    private static func encoder() -> JSONEncoder {
        persistedJSONEncoder(sortedKeys: true)
    }

    private static func decoder() -> JSONDecoder {
        persistedJSONDecoder()
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
        for (lineIndex, line) in lines.enumerated() {
            let isTerminalEmptyLine = line.isEmpty
                && lineIndex == lines.count - 1
                && data.last == 0x0A
            if line.isEmpty {
                // Exactly one empty component is expected from a final
                // newline. Blank lines in the middle (or multiple trailing
                // newlines) indicate a damaged journal and must not be
                // silently skipped.
                guard isTerminalEmptyLine else {
                    throw HistoryStoreError.invalidData
                }
                continue
            }
            guard line.count <= Self.maximumJournalLineBytes else {
                throw HistoryStoreError.fileTooLarge
            }
            let lineData = Data(line)
            var scanner = JSONPrefixScanner(lineData)
            let prefixState = scanner.scan()
            do {
                guard prefixState == .complete else {
                    throw HistoryStoreError.invalidData
                }
                decoded.append(try decoder.decode(MemoryHistoryRecord.self, from: lineData))
            } catch {
                // A process may be terminated while the final line is being
                // appended. Ignore only that incomplete tail; malformed data
                // in a complete or middle line still invalidates the store.
                let isLastLine = lineIndex == lines.count - 1
                if isLastLine, data.last != 0x0A, prefixState == .incomplete {
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
        let fileManager = FileManager.default
        // Capture the original target before directory preparation so a
        // preparation failure cannot make rollback remove an unrelated file.
        let journalPreviouslyExisted = fileManager.fileExists(atPath: journalURL.path)
        var journalWriteStarted = false
        var originalJournalSize: UInt64 = 0
        do {
            let encoder = Self.encoder()
            for record in ordered {
                let encoded = try encoder.encode(record)
                guard encoded.count <= Self.maximumJournalLineBytes,
                      payload.count <= Self.maximumJournalFileBytes - encoded.count - 1 else {
                    throw HistoryStoreError.fileTooLarge
                }
                payload.append(encoded)
                payload.append(0x0A)
            }

            try prepareDirectory()
            if journalPreviouslyExisted {
                let handle = try FileHandle(forWritingTo: journalURL)
                do {
                    originalJournalSize = try handle.seekToEnd()
                    guard originalJournalSize <= UInt64(Self.maximumJournalFileBytes),
                          payload.count <= Self.maximumJournalFileBytes - Int(originalJournalSize) else {
                        throw HistoryStoreError.fileTooLarge
                    }
                    journalWriteStarted = true
                    if originalJournalSize > 0,
                       !fileEndsWithNewline(at: journalURL) {
                        // The separator is carried by the payload prefix. Do
                        // not write a second newline here: two separators
                        // would decode as an invalid blank journal line.
                        payload.insert(0x0A, at: payload.startIndex)
                    }
                    guard payload.count <= Self.maximumJournalFileBytes - Int(originalJournalSize) else {
                        throw HistoryStoreError.fileTooLarge
                    }
                    try handle.write(contentsOf: payload)
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
            } else {
                journalWriteStarted = true
                try payload.write(to: journalURL, options: [.atomic])
            }
            // Permissions are part of the same transaction as the append. If
            // this step fails, the journal is rolled back and pending records
            // remain available for a later retry.
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: journalURL.path
            )
            // Keep the retention reference durable alongside the journal. If
            // this write fails, the surrounding rollback removes the journal
            // bytes as well, so a retry remains transactional.
            try persistClockAnchor(at: timestamp)
        } catch let error as HistoryStoreError {
            pendingWriteNeedsRetry = true
            if journalWriteStarted {
                rollbackJournalWrite(
                    existed: journalPreviouslyExisted,
                    originalSize: originalJournalSize
                )
            }
            throw error
        } catch {
            pendingWriteNeedsRetry = true
            if journalWriteStarted {
                rollbackJournalWrite(
                    existed: journalPreviouslyExisted,
                    originalSize: originalJournalSize
                )
            }
            throw HistoryStoreError.writeFailed
        }

        journalRecordCount += ordered.count
        journalByteCount += payload.count
        lastSuccessfulWriteAt = timestamp
        pendingRecords.removeAll(keepingCapacity: false)
        pendingWriteNeedsRetry = false
        dirty = false
        lastPersistedMinute = records.last?.timestamp

        if journalRecordCount >= compactionRecordThreshold
            || journalByteCount >= compactionByteThreshold {
            do {
                try compactSnapshot(at: timestamp)
            } catch {
                // The journal append itself succeeded, but the optional
                // compaction did not. Keep the store dirty so `flush()` can
                // retry rather than claiming that the canonical snapshot is
                // current.
                dirty = true
                throw error
            }
        }
    }

    private func rollbackJournalWrite(existed: Bool, originalSize: UInt64) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        if !existed {
            try? fileManager.removeItem(at: journalURL)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: journalURL) else { return }
        do {
            try handle.truncate(atOffset: originalSize)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    private static func segmentBucket(_ timestamp: Date) -> Int64 {
        Int64(floor(timestamp.timeIntervalSince1970 / segmentSeconds))
    }

    private static func segmentDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func loadSegments(from data: Data) throws -> [MemoryHistoryRecord] {
        var directoryInfo = stat()
        guard segmentsURL.path.withCString({ lstat($0, &directoryInfo) }) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw HistoryStoreError.invalidData
        }
        let decoder = Self.decoder()
        let index = try decoder.decode(HistorySegmentIndex.self, from: data)
        guard index.version == 2, index.records.isEmpty,
              index.segments.count <= Self.maximumSegmentCount,
              Set(index.segments.map(\.bucket)).count == index.segments.count else {
            throw HistoryStoreError.invalidData
        }
        var loaded: [MemoryHistoryRecord] = []
        var cache: [Int64: HistoryCachedSegment] = [:]
        var totalBytes = data.count
        for reference in index.segments {
            guard reference.isValid else { throw HistoryStoreError.invalidData }
            let payload = try readBoundedFile(
                at: segmentsURL.appendingPathComponent(reference.fileName),
                maximumBytes: Self.maximumSnapshotFileBytes - totalBytes
            )
            totalBytes += payload.count
            guard isCompleteBoundedJSON(payload), Self.segmentDigest(payload) == reference.digest else {
                throw HistoryStoreError.invalidData
            }
            let file = try decoder.decode(MemoryHistoryFile.self, from: payload)
            guard file.version == 1, !file.records.isEmpty,
                  file.records.allSatisfy({ Self.segmentBucket($0.timestamp) == reference.bucket }) else {
                throw HistoryStoreError.invalidData
            }
            loaded += file.records
            cache[reference.bucket] = HistoryCachedSegment(reference: reference, records: file.records)
        }
        segmentCache = cache
        return loaded
    }

    private func prepareSegmentsDirectory() throws {
        var information = stat()
        let result = segmentsURL.path.withCString { lstat($0, &information) }
        if result == 0 {
            guard information.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw HistoryStoreError.writeFailed
            }
        } else if errno != ENOENT {
            throw HistoryStoreError.writeFailed
        }
        try FileManager.default.createDirectory(at: segmentsURL, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: segmentsURL.path)
    }

    private func writeSegmentedSnapshot() throws {
        try prepareSegmentsDirectory()
        let grouped = Dictionary(grouping: records) { Self.segmentBucket($0.timestamp) }
        guard grouped.count <= Self.maximumSegmentCount else { throw HistoryStoreError.fileTooLarge }
        let encoder = Self.encoder()
        var cache: [Int64: HistoryCachedSegment] = [:]
        var totalBytes = 0
        for bucket in grouped.keys.sorted() {
            let rows = grouped[bucket]!
            if let existing = segmentCache[bucket], existing.records == rows {
                cache[bucket] = existing
                totalBytes += byteCount(at: segmentsURL.appendingPathComponent(existing.reference.fileName))
            } else {
                let data = try encoder.encode(MemoryHistoryFile(records: rows))
                guard data.count <= Self.maximumSnapshotFileBytes - totalBytes else {
                    throw HistoryStoreError.fileTooLarge
                }
                let reference = HistorySegmentReference(bucket: bucket, digest: Self.segmentDigest(data))
                let target = segmentsURL.appendingPathComponent(reference.fileName)
                // Atomic writes also repair an unreferenced partial file left
                // by an interrupted attempt, without touching the old index.
                try data.write(to: target, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                snapshotWriteBytes += data.count
                segmentWriteCount += 1
                totalBytes += data.count
                cache[bucket] = HistoryCachedSegment(reference: reference, records: rows)
            }
            guard totalBytes <= Self.maximumSnapshotFileBytes else { throw HistoryStoreError.fileTooLarge }
        }
        let index = HistorySegmentIndex(version: 2, records: [], segments: cache.values.map(\.reference).sorted {
            $0.bucket < $1.bucket
        })
        let data = try encoder.encode(index)
        guard data.count <= Self.maximumSnapshotFileBytes - totalBytes else {
            throw HistoryStoreError.fileTooLarge
        }
        try data.write(to: fileURL, options: [.atomic])
        // The index is now authoritative even if a later permission, journal,
        // clock or orphan-removal operation fails and needs a retry.
        segmentCache = cache
        usesSegmentIndex = true
        snapshotWriteBytes += data.count
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func removeUnreferencedSegments() throws {
        let referenced = Set(segmentCache.values.map { $0.reference.fileName })
        for name in try FileManager.default.contentsOfDirectory(atPath: segmentsURL.path) {
            guard !referenced.contains(name),
                  name.range(of: "^segment--?[0-9]+-[0-9a-f]{64}\\.json$", options: .regularExpression) != nil else { continue }
            try FileManager.default.removeItem(at: segmentsURL.appendingPathComponent(name))
        }
    }

    private func compactSnapshot(at timestamp: Date) throws {
        let fileManager = FileManager.default
        do {
            try prepareDirectory()
            try writeSegmentedSnapshot()

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
            try persistClockAnchor(at: timestamp)
            try removeUnreferencedSegments()
        } catch let error as HistoryStoreError {
            throw error
        } catch {
            throw HistoryStoreError.writeFailed
        }

        snapshotExists = true
        pendingRecords.removeAll(keepingCapacity: false)
        pendingWriteNeedsRetry = false
        dirty = false
        journalRecordCount = 0
        journalByteCount = 0
        lastPersistedMinute = records.last?.timestamp
        compactionCount += 1
        lastCompactionAt = timestamp
        lastSuccessfulWriteAt = timestamp
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
        let bucket = floor(seconds / 60)
        guard bucket.isFinite else { return date }
        let normalizedSeconds = bucket * 60
        // Floating-point multiplication can overflow to infinity for a
        // finite, attacker-supplied Date. Keep the original value so the
        // caller can reject/prune it rather than constructing another invalid
        // timestamp.
        guard normalizedSeconds.isFinite else { return date }
        return Date(timeIntervalSince1970: normalizedSeconds)
    }

    private func normalized(_ record: MemoryHistoryRecord) -> MemoryHistoryRecord {
        MemoryHistoryRecord(
            timestamp: Self.minuteStart(record.timestamp),
            availableFraction: record.availableFraction,
            compressedBytes: record.compressedBytes,
            swapUsedBytes: record.swapUsedBytes,
            workloads: Self.compactedWorkloads(record.workloads, limit: maxPersistedWorkloads),
            workloadsSampledAt: record.workloadsSampledAt,
            workloadInventoryIsComplete: record.workloadInventoryIsComplete,
            sourceSampledAt: record.sourceSampledAt
        )
    }

    private func merged(
        existing: MemoryHistoryRecord,
        candidate: MemoryHistoryRecord
    ) -> MemoryHistoryRecord {
        Self.preferredRecord(existing: existing, candidate: candidate)
    }

    /// Merges two records for the same minute without depending on insertion
    /// order. System values prefer the newest source sample when available;
    /// legacy records without that marker use a canonical field ordering.
    /// Workload attribution follows the corresponding freshness rule in
    /// `preferredWorkloadPayload` and is canonicalized before serialization.
    public nonisolated static func preferredRecord(
        existing: MemoryHistoryRecord,
        candidate: MemoryHistoryRecord
    ) -> MemoryHistoryRecord {
        let preferredSystem = preferredSystemRecord(
            existing: existing,
            candidate: candidate
        )
        let workloadPayload = preferredWorkloadPayload(
            existing: existing,
            candidate: candidate
        )
        return MemoryHistoryRecord(
            timestamp: candidate.timestamp,
            availableFraction: preferredSystem.availableFraction,
            compressedBytes: preferredSystem.compressedBytes,
            swapUsedBytes: preferredSystem.swapUsedBytes,
            workloads: workloadPayload.workloads,
            workloadsSampledAt: workloadPayload.sampledAt,
            workloadInventoryIsComplete: workloadPayload.inventoryIsComplete,
            sourceSampledAt: preferredSystem.sourceSampledAt
        )
    }

    /// Applies the top-workload policy to records loaded from an older or
    /// hand-edited file, and to records merged by a recovery path. `append`
    /// already normalizes new records; load/merge must not trust their input.
    private nonisolated static func compactingWorkloads(
        _ records: [MemoryHistoryRecord],
        limit: Int
    ) -> [MemoryHistoryRecord] {
        let safeLimit = max(limit, 1)
        return records.map { record in
            guard record.workloads.count > safeLimit else { return record }
            let workloads = compactedWorkloads(record.workloads, limit: safeLimit)
            guard workloads != record.workloads else { return record }
            return MemoryHistoryRecord(
                timestamp: record.timestamp,
                availableFraction: record.availableFraction,
                compressedBytes: record.compressedBytes,
                swapUsedBytes: record.swapUsedBytes,
                workloads: workloads,
                workloadsSampledAt: record.workloadsSampledAt,
                workloadInventoryIsComplete: record.workloadInventoryIsComplete,
                sourceSampledAt: record.sourceSampledAt
            )
        }
    }

    private nonisolated static func preferredSystemRecord(
        existing: MemoryHistoryRecord,
        candidate: MemoryHistoryRecord
    ) -> MemoryHistoryRecord {
        switch (existing.sourceSampledAt, candidate.sourceSampledAt) {
        case (nil, nil):
            return compareSystemPayload(candidate, existing) > 0 ? candidate : existing
        case (nil, _?):
            return candidate
        case (_?, nil):
            return existing
        case let (existingAt?, candidateAt?):
            if candidateAt != existingAt {
                return candidateAt > existingAt ? candidate : existing
            }
            return compareSystemPayload(candidate, existing) > 0 ? candidate : existing
        }
    }

    private nonisolated static func compareSystemPayload(
        _ lhs: MemoryHistoryRecord,
        _ rhs: MemoryHistoryRecord
    ) -> Int {
        if lhs.availableFraction != rhs.availableFraction {
            return lhs.availableFraction < rhs.availableFraction ? -1 : 1
        }
        if lhs.compressedBytes != rhs.compressedBytes {
            return lhs.compressedBytes < rhs.compressedBytes ? -1 : 1
        }
        if lhs.swapUsedBytes != rhs.swapUsedBytes {
            return lhs.swapUsedBytes < rhs.swapUsedBytes ? -1 : 1
        }
        if lhs.sourceSampledAt != rhs.sourceSampledAt {
            guard let left = lhs.sourceSampledAt else { return -1 }
            guard let right = rhs.sourceSampledAt else { return 1 }
            return left < right ? -1 : 1
        }
        return compareWorkloadArrays(lhs.workloads, rhs.workloads)
    }

    private func coalesced(_ source: [MemoryHistoryRecord]) -> [MemoryHistoryRecord] {
        var byMinute: [Date: MemoryHistoryRecord] = [:]
        for record in source {
            let normalizedRecord = normalized(record)
            guard let existing = byMinute[normalizedRecord.timestamp] else {
                byMinute[normalizedRecord.timestamp] = normalizedRecord
                continue
            }

            byMinute[normalizedRecord.timestamp] = merged(
                existing: existing,
                candidate: normalizedRecord
            )
        }
        return byMinute.values.sorted { $0.timestamp < $1.timestamp }
    }

    /// Selects the workload attribution that should survive a merge of two
    /// records representing the same minute. Freshness wins first; when both
    /// sources have the same (or no) marker, a canonical full-field ordering
    /// makes the result independent of input order. The returned list is
    /// canonicalized as well, so equivalent records serialize identically.
    public nonisolated static func preferredWorkloadPayload(
        existing: MemoryHistoryRecord,
        candidate: MemoryHistoryRecord
    ) -> (
        workloads: [PersistedWorkloadRecord],
        sampledAt: Date?,
        inventoryIsComplete: Bool?
    ) {
        let useCandidate: Bool
        switch (existing.workloadsSampledAt, candidate.workloadsSampledAt) {
        case (nil, nil):
            useCandidate = compareWorkloadArrays(candidate.workloads, existing.workloads) > 0
        case (nil, _?):
            useCandidate = true
        case (_?, nil):
            useCandidate = false
        case let (existingAt?, candidateAt?):
            if candidateAt != existingAt {
                useCandidate = candidateAt > existingAt
            } else if candidate.workloadInventoryIsComplete
                        != existing.workloadInventoryIsComplete {
                useCandidate = workloadCompletenessRank(
                    candidate.workloadInventoryIsComplete
                ) > workloadCompletenessRank(existing.workloadInventoryIsComplete)
            } else {
                useCandidate = compareWorkloadArrays(candidate.workloads, existing.workloads) > 0
            }
        }

        let selected = useCandidate ? candidate : existing
        return (
            workloads: canonicalWorkloads(selected.workloads),
            sampledAt: selected.workloadsSampledAt,
            inventoryIsComplete: selected.workloadInventoryIsComplete
        )
    }

    private nonisolated static func workloadCompletenessRank(_ value: Bool?) -> Int {
        switch value {
        case .some(true): return 2
        case .some(false): return 1
        case .none: return 0
        }
    }

    private nonisolated static func canonicalWorkloads(
        _ workloads: [PersistedWorkloadRecord]
    ) -> [PersistedWorkloadRecord] {
        workloads.sorted { compareWorkloads($0, $1) < 0 }
    }

    /// Lexicographic comparison over every persisted workload field. Keeping
    /// this comparison numeric/textual (rather than locale-aware) provides a
    /// stable total order across processes and machines.
    private nonisolated static func compareWorkloads(
        _ lhs: PersistedWorkloadRecord,
        _ rhs: PersistedWorkloadRecord
    ) -> Int {
        if lhs.id != rhs.id { return lhs.id < rhs.id ? -1 : 1 }
        if lhs.containsEstimatedFootprint != rhs.containsEstimatedFootprint {
            // Keep exact values ahead of RSS fallbacks when duplicate IDs are
            // compared. This prevents an estimate from winning solely because
            // its numeric value is larger.
            return lhs.containsEstimatedFootprint ? 1 : -1
        }
        if lhs.title != rhs.title { return lhs.title < rhs.title ? -1 : 1 }
        if lhs.processCount != rhs.processCount {
            return lhs.processCount < rhs.processCount ? -1 : 1
        }
        if lhs.attributedFootprintBytes != rhs.attributedFootprintBytes {
            return lhs.attributedFootprintBytes < rhs.attributedFootprintBytes ? -1 : 1
        }
        if lhs.attributedResidentBytes != rhs.attributedResidentBytes {
            return lhs.attributedResidentBytes < rhs.attributedResidentBytes ? -1 : 1
        }
        if lhs.isSystem != rhs.isSystem {
            return lhs.isSystem ? -1 : 1
        }
        return 0
    }

    private nonisolated static func compareWorkloadArrays(
        _ lhs: [PersistedWorkloadRecord],
        _ rhs: [PersistedWorkloadRecord]
    ) -> Int {
        let left = canonicalWorkloads(lhs)
        let right = canonicalWorkloads(rhs)
        for (leftWorkload, rightWorkload) in zip(left, right) {
            let comparison = compareWorkloads(leftWorkload, rightWorkload)
            if comparison != 0 { return comparison }
        }
        if left.count == right.count { return 0 }
        return left.count < right.count ? -1 : 1
    }

    /// Applies the same top-workload and aggregate policy used by durable
    /// history persistence. Callers that must buffer records in memory can
    /// use this helper to keep their temporary representation bounded too.
    public nonisolated static func compactedWorkloads(
        _ source: [PersistedWorkloadRecord],
        limit: Int
    ) -> [PersistedWorkloadRecord] {
        let safeLimit = max(limit, 1)
        // Existing aggregate rows must survive re-compaction instead of being
        // ranked as ordinary workloads and aggregated again. This keeps the
        // helper idempotent when a canonical history file is loaded.
        let aggregates = source.filter { isAggregateWorkloadID($0.id) }
        let candidates = source.filter { !isAggregateWorkloadID($0.id) }
        let ranked = candidates.sorted(by: workloadRanking)
        guard ranked.count > safeLimit else {
            return (ranked + aggregates).sorted(by: workloadRanking)
        }

        var result = Array(ranked.prefix(safeLimit))
        var aggregateBySystem: [Bool: (
            processCount: Int,
            footprint: UInt64,
            resident: UInt64,
            containsEstimatedFootprint: Bool
        )] = [:]

        for workload in aggregates + Array(ranked.dropFirst(safeLimit)) {
            var aggregate = aggregateBySystem[workload.isSystem] ?? (
                processCount: 0,
                footprint: 0,
                resident: 0,
                containsEstimatedFootprint: false
            )
            aggregate.processCount = adding(aggregate.processCount, workload.processCount)
            aggregate.footprint = adding(aggregate.footprint, workload.attributedFootprintBytes)
            aggregate.resident = adding(aggregate.resident, workload.attributedResidentBytes)
            aggregate.containsEstimatedFootprint = aggregate.containsEstimatedFootprint
                || workload.containsEstimatedFootprint
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
                    isSystem: isSystem,
                    containsEstimatedFootprint: aggregate.containsEstimatedFootprint
                )
            )
        }
        return result.sorted(by: workloadRanking)
    }

    private nonisolated static func isAggregateWorkloadID(_ id: String) -> Bool {
        id == "other-system" || id == "other-processes"
    }

    private nonisolated static func workloadRanking(
        _ lhs: PersistedWorkloadRecord,
        _ rhs: PersistedWorkloadRecord
    ) -> Bool {
        if lhs.containsEstimatedFootprint != rhs.containsEstimatedFootprint {
            return !lhs.containsEstimatedFootprint
        }
        if lhs.attributedFootprintBytes != rhs.attributedFootprintBytes {
            return lhs.attributedFootprintBytes > rhs.attributedFootprintBytes
        }
        if lhs.isSystem != rhs.isSystem {
            return !lhs.isSystem
        }
        return lhs.id < rhs.id
    }

    private nonisolated static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private nonisolated static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        guard rhs > 0 else { return lhs }
        return lhs > Int.max - rhs ? Int.max : lhs + rhs
    }

    private static func pruned(
        _ source: [MemoryHistoryRecord],
        now: Date,
        retentionInterval: TimeInterval
    ) -> [MemoryHistoryRecord] {
        guard isPersistableDate(now), retentionInterval.isFinite else { return [] }
        let cutoff = now.timeIntervalSince1970 - min(max(retentionInterval, 0), maximumRetentionInterval)
        guard cutoff.isFinite else {
            // With the supported retention bound this should not normally be
            // reached, but returning an empty set is safer than retaining an
            // unbounded file when arithmetic receives an extreme value.
            return []
        }
        return source.filter { record in
            let timestamp = record.timestamp.timeIntervalSince1970
            guard timestamp.isFinite,
                  timestamp >= cutoff,
                  isWithinFutureSkew(record.timestamp, now: now, allowance: maximumFutureSkew) else {
                return false
            }
            if let sourceSampledAt = record.sourceSampledAt,
               !isWithinFutureSkew(sourceSampledAt, now: now, allowance: maximumFutureSkew) {
                return false
            }
            if let workloadsSampledAt = record.workloadsSampledAt,
               !isWithinFutureSkew(workloadsSampledAt, now: now, allowance: maximumFutureSkew) {
                return false
            }
            return true
        }
    }

    private nonisolated static func hasFreshnessMarkersNearRecord(
        _ record: MemoryHistoryRecord
    ) -> Bool {
        // Compare against the persisted minute bucket, rather than the
        // caller's unnormalized subsecond timestamp.
        let recordSeconds = minuteStart(record.timestamp).timeIntervalSince1970
        guard recordSeconds.isFinite,
              maximumFreshnessMarkerRecordSkew.isFinite,
              maximumFreshnessMarkerRecordSkew >= 0 else {
            return false
        }
        return [record.sourceSampledAt, record.workloadsSampledAt]
            .compactMap { $0 }
            .allSatisfy { marker in
                let skew = marker.timeIntervalSince1970 - recordSeconds
                return skew.isFinite && abs(skew) <= maximumFreshnessMarkerRecordSkew
            }
    }
}

public enum ProcessActionAuditStoreError: Error, CustomStringConvertible, LocalizedError, Sendable, Equatable {
    case readFailed
    case writeFailed
    case fileTooLarge
    case lockTimedOut
    case invalidData
    case recoveryRequired

    public var description: String {
        switch self {
        case .readFailed:
            return "无法读取进程操作记录"
        case .writeFailed:
            return "无法写入进程操作记录"
        case .fileTooLarge:
            return "进程操作记录超过安全大小限制"
        case .lockTimedOut:
            return "等待进程操作记录文件锁超时"
        case .invalidData:
            return "进程操作记录格式无效或已损坏"
        case .recoveryRequired:
            return "检测到未完成的数据恢复事务，请先运行 storage recover"
        }
    }

    public var errorDescription: String? { description }
}

private struct AuditDurableGeneration: Equatable {
    let log: PersistedFileGeneration?
    let clock: PersistedFileGeneration?
}

/// Small append-only audit log for explicitly confirmed process actions.
/// Records are local, bounded, and contain no PID, start time, command line,
/// executable path, or other process identity data.
public actor ProcessActionAuditStore {
    public static let defaultRetentionInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let defaultMaximumEvents = 200
    public static let maximumFutureSkew: TimeInterval = HistoryStore.maximumFutureSkew
    public static let maximumRetentionInterval: TimeInterval = HistoryStore.maximumRetentionInterval
    public static let maximumFileBytes = 32 * 1024 * 1024
    public static let maximumLineBytes = 1 * 1024 * 1024
    public static let maximumClockFileBytes = PersistedDataLimit.clockBytes
    public static let defaultLockTimeoutSeconds: TimeInterval = 2

    public static var defaultFileURL: URL {
        MemoryMonitorStoragePaths.auditFileURL(
            root: MemoryMonitorStoragePaths.currentRootURL
        )
    }

    public nonisolated let fileURL: URL
    private let clockURL: URL
    private let lockURL: URL
    public let retentionInterval: TimeInterval
    public let maximumEvents: Int
    public let lockTimeoutSeconds: TimeInterval

    private var events: [ProcessActionAuditEvent] = []
    private var hasLoaded = false
    private var dirty = false
    private var lastObservedNow: Date?
    private var ignorePersistedClockAnchorUntilWrite = false
    private var durableGeneration: AuditDurableGeneration?

    public init(
        fileURL: URL = ProcessActionAuditStore.defaultFileURL,
        retentionInterval: TimeInterval = ProcessActionAuditStore.defaultRetentionInterval,
        maximumEvents: Int = ProcessActionAuditStore.defaultMaximumEvents,
        lockTimeoutSeconds: TimeInterval = ProcessActionAuditStore.defaultLockTimeoutSeconds
    ) {
        self.fileURL = fileURL
        self.clockURL = URL(fileURLWithPath: fileURL.path + ".clock")
        self.lockURL = URL(fileURLWithPath: fileURL.path + ".lock")
        self.retentionInterval = retentionInterval.isFinite
            ? min(max(retentionInterval, 0), Self.maximumRetentionInterval)
            : Self.defaultRetentionInterval
        self.maximumEvents = max(maximumEvents, 1)
        self.lockTimeoutSeconds = lockTimeoutSeconds.isFinite && lockTimeoutSeconds >= 0
            ? lockTimeoutSeconds
            : Self.defaultLockTimeoutSeconds
    }

    private var clockRollbackLimit: TimeInterval {
        min(
            max(retentionInterval, 0) + Self.maximumFutureSkew,
            Self.maximumRetentionInterval
        )
    }

    private func retentionReferenceNow(_ now: Date) -> Date {
        if hasLoaded, events.isEmpty, !dirty {
            lastObservedNow = now
            ignorePersistedClockAnchorUntilWrite = true
            return now
        }

        let diskAnchor = ignorePersistedClockAnchorUntilWrite
            ? nil
            : readClockAnchor(at: clockURL)
        var candidate = lastObservedNow
        if let diskAnchor, (candidate == nil || diskAnchor > candidate!) {
            candidate = diskAnchor
        }
        let reference = boundedRetentionReference(
            now: now,
            anchor: candidate,
            rollbackLimit: clockRollbackLimit
        )
        if reference == now, let candidate,
           candidate.timeIntervalSince(now).isFinite,
           candidate.timeIntervalSince(now) > clockRollbackLimit {
            lastObservedNow = now
        } else if let current = lastObservedNow {
            if now > current { lastObservedNow = now }
        } else {
            lastObservedNow = now
        }
        if let candidate, candidate <= now || reference == candidate {
            lastObservedNow = max(lastObservedNow ?? now, candidate)
        }
        return reference
    }

    private func persistClockAnchor(at date: Date) throws {
        guard isPersistableDate(date) else { throw ProcessActionAuditStoreError.invalidData }
        let previousAnchorData = try? readBoundedFile(
            at: clockURL,
            maximumBytes: Self.maximumClockFileBytes
        )
        let previousObservedNow = lastObservedNow
        let previousIgnorePersistedAnchor = ignorePersistedClockAnchorUntilWrite
        let observedAt: Date
        var candidates = [date]
        if let current = lastObservedNow {
            candidates.append(current)
        }
        if !ignorePersistedClockAnchorUntilWrite,
           let disk = readClockAnchor(at: clockURL),
           disk > date,
           disk.timeIntervalSince(date).isFinite,
           disk.timeIntervalSince(date) <= clockRollbackLimit {
            candidates.append(disk)
        }
        observedAt = candidates.max() ?? date
        lastObservedNow = observedAt
        do {
            let data = try clockAnchorData(for: observedAt)
            guard data.count <= Self.maximumClockFileBytes else {
                throw ProcessActionAuditStoreError.fileTooLarge
            }
            try prepareDirectory()
            try data.write(to: clockURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: clockURL.path
            )
            ignorePersistedClockAnchorUntilWrite = false
        } catch let error as ProcessActionAuditStoreError {
            lastObservedNow = previousObservedNow
            ignorePersistedClockAnchorUntilWrite = previousIgnorePersistedAnchor
            if let previousAnchorData {
                try? previousAnchorData.write(to: clockURL, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: clockURL.path
                )
            } else {
                try? FileManager.default.removeItem(at: clockURL)
            }
            throw error
        } catch {
            lastObservedNow = previousObservedNow
            ignorePersistedClockAnchorUntilWrite = previousIgnorePersistedAnchor
            if let previousAnchorData {
                try? previousAnchorData.write(to: clockURL, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: clockURL.path
                )
            } else {
                try? FileManager.default.removeItem(at: clockURL)
            }
            throw ProcessActionAuditStoreError.writeFailed
        }
    }

    private func withStoreLock<T>(
        failure: ProcessActionAuditStoreError,
        _ body: () throws -> T
    ) throws -> T {
        do {
            let maintenanceDescriptor = try MaintenanceLock.acquire(
                root: fileURL.deletingLastPathComponent(),
                mode: .shared,
                timeoutSeconds: lockTimeoutSeconds
            )
            defer { MaintenanceLock.release(maintenanceDescriptor) }
            guard !MaintenanceTransaction.exists(root: fileURL.deletingLastPathComponent()) else {
                throw ProcessActionAuditStoreError.recoveryRequired
            }
            let lockDescriptor = try acquireExclusivePersistedFileLock(
                at: lockURL,
                timeoutSeconds: lockTimeoutSeconds
            )
            defer { releaseExclusivePersistedFileLock(lockDescriptor) }
            try validateFileSize(at: fileURL, maximumBytes: Self.maximumFileBytes)
            try validateFileSize(
                at: clockURL,
                maximumBytes: Self.maximumClockFileBytes
            )
            let result = try body()
            durableGeneration = try currentDurableGeneration()
            return result
        } catch let error as ProcessActionAuditStoreError {
            durableGeneration = nil
            throw error
        } catch BoundedFileReadError.tooLarge {
            durableGeneration = nil
            throw ProcessActionAuditStoreError.fileTooLarge
        } catch PersistedFileLockError.timedOut {
            durableGeneration = nil
            throw ProcessActionAuditStoreError.lockTimedOut
        } catch PersistedFileLockError.cancelled {
            durableGeneration = nil
            throw CancellationError()
        } catch is CancellationError {
            durableGeneration = nil
            throw CancellationError()
        } catch MaintenanceLockError.timedOut {
            durableGeneration = nil
            throw ProcessActionAuditStoreError.lockTimedOut
        } catch {
            durableGeneration = nil
            throw failure
        }
    }

    private func currentDurableGeneration() throws -> AuditDurableGeneration {
        AuditDurableGeneration(
            log: try persistedFileGeneration(at: fileURL),
            clock: try persistedFileGeneration(at: clockURL)
        )
    }

    @discardableResult
    public func load(now: Date = Date()) throws -> [ProcessActionAuditEvent] {
        guard isPersistableDate(now) else {
            throw ProcessActionAuditStoreError.invalidData
        }
        return try withStoreLock(failure: .readFailed) {
            if hasLoaded {
                // Keep the actor's last validated events available to a
                // subsequent write retry, but never report them as a
                // successful read when the durable path cannot be refreshed.
                guard try synchronizeDurableViewLocked(now: now) else {
                    throw ProcessActionAuditStoreError.readFailed
                }
                return events
            }
            return try loadLocked(now: now)
        }
    }

    @discardableResult
    private func loadLocked(now: Date) throws -> [ProcessActionAuditEvent] {
        guard isPersistableDate(now) else {
            throw ProcessActionAuditStoreError.invalidData
        }
        let referenceNow = retentionReferenceNow(now)
        guard !hasLoaded else {
            let prunedEvents = Self.pruned(
                events,
                now: referenceNow,
                retentionInterval: retentionInterval,
                limit: maximumEvents
            )
            if prunedEvents != events {
                events = prunedEvents
                dirty = true
                do {
                    try persist(observedAt: now)
                    dirty = false
                } catch {
                    // Keep the pruned in-memory view and mark it for a later
                    // retry; a transient permission/disk error must not make
                    // the actor look clean.
                    dirty = true
                    throw error
                }
            }
            return events
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            hasLoaded = true
            return []
        }

        let data: Data
        do {
            data = try readBoundedFile(
                at: fileURL,
                maximumBytes: Self.maximumFileBytes
            )
        } catch BoundedFileReadError.tooLarge {
            throw ProcessActionAuditStoreError.fileTooLarge
        } catch {
            throw ProcessActionAuditStoreError.readFailed
        }

        let decoded = try decode(data)
        let uniqueDecodedEvents = Self.deduplicated(decoded.events)
        events = Self.pruned(
            uniqueDecodedEvents,
            now: referenceNow,
            retentionInterval: retentionInterval,
            limit: maximumEvents
        )
        hasLoaded = true

        if decoded.validByteCount < data.count
            || uniqueDecodedEvents.count != decoded.events.count
            || events.count != uniqueDecodedEvents.count {
            dirty = true
            do {
                try persist(observedAt: now)
                dirty = false
            } catch {
                dirty = true
                throw error
            }
        } else if data.isEmpty {
            try setFilePermissionsIfPresent()
        }
        // Older audit logs may not have a clock sidecar. Establish it after
        // validating the complete log so a later rollback cannot evict valid
        // events merely because the first post-upgrade load uses a smaller
        // wall-clock value.
        if readClockAnchor(at: clockURL) == nil {
            do {
                try persistClockAnchor(at: now)
            } catch {
                dirty = true
                throw error
            }
        }
        return events
    }

    private func reloadFromDiskLocked(now: Date) throws {
        events.removeAll(keepingCapacity: false)
        dirty = false
        hasLoaded = false
        _ = try loadLocked(now: now)
    }

    /// Refreshes the durable view under the path lock. A prior failed rewrite
    /// may have left an in-memory event set that is newer than disk; merge it
    /// back after reloading so a repair cannot discard that event or another
    /// instance's concurrent append.
    @discardableResult
    private func synchronizeDurableViewLocked(now: Date) throws -> Bool {
        guard hasLoaded else {
            _ = try loadLocked(now: now)
            return true
        }

        if let durableGeneration,
           let currentGeneration = try? currentDurableGeneration(),
           durableGeneration == currentGeneration {
            return true
        }

        let preserveLocal = dirty
        let localEvents = preserveLocal ? events : []
        let savedEvents = events
        let savedDirty = dirty
        let savedHasLoaded = hasLoaded
        let savedLastObservedNow = lastObservedNow
        let savedIgnorePersistedAnchor = ignorePersistedClockAnchorUntilWrite
        do {
            try reloadFromDiskLocked(now: now)
        } catch let error as ProcessActionAuditStoreError {
            events = savedEvents
            dirty = savedDirty
            hasLoaded = savedHasLoaded
            lastObservedNow = savedLastObservedNow
            ignorePersistedClockAnchorUntilWrite = savedIgnorePersistedAnchor
            if error == .readFailed {
                // Preserve the last validated event set and let the caller
                // attempt the write. This keeps a failed append retryable
                // when the target path is temporarily unreadable; malformed
                // content still remains a hard read failure.
                dirty = true
                return false
            }
            throw error
        } catch {
            events = savedEvents
            dirty = savedDirty
            hasLoaded = savedHasLoaded
            lastObservedNow = savedLastObservedNow
            ignorePersistedClockAnchorUntilWrite = savedIgnorePersistedAnchor
            throw error
        }
        guard preserveLocal else { return true }

        let diskEvents = events
        let referenceNow = retentionReferenceNow(now)
        let mergedEvents = Self.pruned(
            Self.deduplicated(diskEvents + localEvents),
            now: referenceNow,
            retentionInterval: retentionInterval,
            limit: maximumEvents
        )
        events = mergedEvents
        dirty = mergedEvents != diskEvents
        return true
    }

    /// Audit appends are whole-file transactions when retention/repair is
    /// required. Always refresh a previously loaded actor while holding the
    /// path lock so a stale event list cannot replace another instance's
    /// recent events.
    private func synchronizeBeforeAppendLocked(now: Date) throws -> Bool {
        try synchronizeDurableViewLocked(now: now)
    }

    @discardableResult
    public func append(
        _ event: ProcessActionAuditEvent,
        now: Date = Date()
    ) throws -> [ProcessActionAuditEvent] {
        guard isPersistableDate(now) else {
            throw ProcessActionAuditStoreError.invalidData
        }
        return try withStoreLock(failure: .writeFailed) {
            try appendLocked(event, now: now)
        }
    }

    @discardableResult
    private func appendLocked(
        _ event: ProcessActionAuditEvent,
        now: Date
    ) throws -> [ProcessActionAuditEvent] {
        guard isPersistableDate(now),
              event.hasValidPersistedFields,
              isWithinFutureSkew(event.timestamp, now: now, allowance: Self.maximumFutureSkew) else {
            throw ProcessActionAuditStoreError.invalidData
        }
        let didSynchronize = try synchronizeBeforeAppendLocked(now: now)

        let referenceNow = retentionReferenceNow(now)
        let previousEvents = events
        let hadPendingMismatch = dirty || !didSynchronize
        let beforeCount = events.count
        if let existing = events.first(where: { $0.id == event.id }) {
            // Replaying the same event is idempotent; a conflicting duplicate
            // would make SwiftUI's Identifiable collection ambiguous.
            if existing == event { return events }
            throw ProcessActionAuditStoreError.invalidData
        }
        events.append(event)
        let prunedEvents = Self.pruned(
            events,
            now: referenceNow,
            retentionInterval: retentionInterval,
            limit: maximumEvents
        )
        let requiresRewrite = prunedEvents.count != beforeCount + 1
        events = prunedEvents

        do {
            if requiresRewrite || hadPendingMismatch {
                try persist(observedAt: now)
            } else {
                try appendLine(event, observedAt: now)
            }
            dirty = false
        } catch {
            // An append is transactional from the actor's perspective. The
            // failed event must not remain in memory and accidentally appear
            // in a later rewrite; the next `flush()` can repair any residual
            // bytes left by an unusual partial write.
            events = previousEvents
            dirty = true
            throw error
        }
        return events
    }

    public func flush(now: Date = Date()) throws {
        guard isPersistableDate(now) else {
            throw ProcessActionAuditStoreError.invalidData
        }
        return try withStoreLock(failure: .writeFailed) {
            try flushLocked(now: now)
        }
    }

    private func flushLocked(now: Date) throws {
        guard isPersistableDate(now) else {
            throw ProcessActionAuditStoreError.invalidData
        }
        guard hasLoaded else { return }
        let synchronizationNow: Date
        if let observed = lastObservedNow,
           isPersistableDate(observed),
           now.timeIntervalSince(observed).isFinite,
           now.timeIntervalSince(observed) > clockRollbackLimit {
            synchronizationNow = observed
        } else {
            synchronizationNow = now
        }
        try synchronizeDurableViewLocked(now: synchronizationNow)
        _ = retentionReferenceNow(now)
        try persist(observedAt: now)
    }

    private struct DecodeResult {
        let events: [ProcessActionAuditEvent]
        let validByteCount: Int
    }

    private func decode(_ data: Data) throws -> DecodeResult {
        guard !data.isEmpty else { return DecodeResult(events: [], validByteCount: 0) }

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        let decoder = persistedJSONDecoder()
        var decoded: [ProcessActionAuditEvent] = []
        var ignoredIncompleteTail = false

        for (lineIndex, line) in lines.enumerated() {
            let isTerminalEmptyLine = line.isEmpty
                && lineIndex == lines.count - 1
                && data.last == 0x0A
            if line.isEmpty {
                guard isTerminalEmptyLine else {
                    throw ProcessActionAuditStoreError.invalidData
                }
                continue
            }
            guard line.count <= Self.maximumLineBytes else {
                throw ProcessActionAuditStoreError.fileTooLarge
            }
            let lineData = Data(line)
            var scanner = JSONPrefixScanner(lineData)
            let prefixState = scanner.scan()
            do {
                guard prefixState == .complete else {
                    throw ProcessActionAuditStoreError.invalidData
                }
                decoded.append(try decoder.decode(ProcessActionAuditEvent.self, from: lineData))
            } catch {
                let isLastLine = lineIndex == lines.count - 1
                if isLastLine, data.last != 0x0A, prefixState == .incomplete {
                    ignoredIncompleteTail = true
                    break
                }
                throw ProcessActionAuditStoreError.invalidData
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
        return DecodeResult(events: decoded, validByteCount: validByteCount)
    }

    private func appendLine(_ event: ProcessActionAuditEvent, observedAt: Date) throws {
        let fileManager = FileManager.default
        let filePreviouslyExisted = fileManager.fileExists(atPath: fileURL.path)
        var writeStarted = false
        var originalSize: UInt64 = 0
        do {
            try prepareDirectory()
            let encoder = persistedJSONEncoder(sortedKeys: true)
            var payload = try encoder.encode(event)
            guard payload.count <= Self.maximumLineBytes else {
                throw ProcessActionAuditStoreError.fileTooLarge
            }
            payload.append(0x0A)

            if filePreviouslyExisted {
                let handle = try FileHandle(forWritingTo: fileURL)
                do {
                    originalSize = try handle.seekToEnd()
                    guard originalSize <= UInt64(Self.maximumFileBytes),
                          payload.count <= Self.maximumFileBytes - Int(originalSize) else {
                        throw ProcessActionAuditStoreError.fileTooLarge
                    }
                    writeStarted = true
                    if originalSize > 0,
                       !fileEndsWithNewline(at: fileURL) {
                        // The separator is carried by the payload prefix. A
                        // second write would leave an invalid blank JSONL
                        // line between the old and new events.
                        payload.insert(0x0A, at: payload.startIndex)
                    }
                    guard payload.count <= Self.maximumFileBytes - Int(originalSize) else {
                        throw ProcessActionAuditStoreError.fileTooLarge
                    }
                    try handle.write(contentsOf: payload)
                    try handle.synchronize()
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
            } else {
                writeStarted = true
                try payload.write(to: fileURL, options: [.atomic])
            }
            try setFilePermissionsIfPresent()
            try persistClockAnchor(at: observedAt)
        } catch let error as ProcessActionAuditStoreError {
            if writeStarted {
                rollbackFileWrite(
                    existed: filePreviouslyExisted,
                    originalSize: originalSize
                )
            }
            throw error
        } catch {
            if writeStarted {
                rollbackFileWrite(
                    existed: filePreviouslyExisted,
                    originalSize: originalSize
                )
            }
            throw ProcessActionAuditStoreError.writeFailed
        }
    }

    private func persist(observedAt: Date? = nil) throws {
        let fileManager = FileManager.default
        let filePreviouslyExisted = fileManager.fileExists(atPath: fileURL.path)
        let previousData = filePreviouslyExisted
            ? try? readBoundedFile(at: fileURL, maximumBytes: Self.maximumFileBytes)
            : nil
        let previousClockData = try? readBoundedFile(
            at: clockURL,
            maximumBytes: Self.maximumClockFileBytes
        )
        let anchorDate = observedAt ?? lastObservedNow ?? events.first?.timestamp
        guard let anchorDate, isPersistableDate(anchorDate) else {
            throw ProcessActionAuditStoreError.invalidData
        }
        do {
            try prepareDirectory()
            let encoder = persistedJSONEncoder(sortedKeys: true)
            var payload = Data()
            for event in events {
                let encoded = try encoder.encode(event)
                guard encoded.count <= Self.maximumLineBytes,
                      payload.count <= Self.maximumFileBytes - encoded.count - 1 else {
                    throw ProcessActionAuditStoreError.fileTooLarge
                }
                payload.append(encoded)
                payload.append(0x0A)
            }
            try payload.write(to: fileURL, options: [.atomic])
            try setFilePermissionsIfPresent()
            try persistClockAnchor(at: anchorDate)
        } catch let error as ProcessActionAuditStoreError {
            // `Data.write(.atomic)` normally leaves the old file intact on
            // failure, but permission changes can fail after replacement. A
            // best-effort restore keeps a failed rewrite from exposing a
            // half-applied event set to the next load.
            if filePreviouslyExisted, let previousData {
                try? previousData.write(to: fileURL, options: [.atomic])
                try? setFilePermissionsIfPresent()
            } else if !filePreviouslyExisted {
                try? fileManager.removeItem(at: fileURL)
            }
            if let previousClockData {
                try? previousClockData.write(to: clockURL, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: clockURL.path
                )
            } else {
                try? fileManager.removeItem(at: clockURL)
            }
            throw error
        } catch {
            if filePreviouslyExisted, let previousData {
                try? previousData.write(to: fileURL, options: [.atomic])
                try? setFilePermissionsIfPresent()
            } else if !filePreviouslyExisted {
                try? fileManager.removeItem(at: fileURL)
            }
            if let previousClockData {
                try? previousClockData.write(to: clockURL, options: [.atomic])
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: clockURL.path
                )
            } else {
                try? fileManager.removeItem(at: clockURL)
            }
            throw ProcessActionAuditStoreError.writeFailed
        }
        dirty = false
    }

    private func rollbackFileWrite(existed: Bool, originalSize: UInt64) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        if !existed {
            try? fileManager.removeItem(at: fileURL)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        do {
            try handle.truncate(atOffset: originalSize)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    private func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    private func setFilePermissionsIfPresent() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    private static func pruned(
        _ source: [ProcessActionAuditEvent],
        now: Date,
        retentionInterval: TimeInterval,
        limit: Int
    ) -> [ProcessActionAuditEvent] {
        guard isPersistableDate(now), retentionInterval.isFinite else { return [] }
        let cutoff = now.timeIntervalSince1970
            - min(max(retentionInterval, 0), maximumRetentionInterval)
        guard cutoff.isFinite else { return [] }
        let retained = source
            .filter { event in
                let timestamp = event.timestamp.timeIntervalSince1970
                return timestamp.isFinite
                    && timestamp >= cutoff
                    && isWithinFutureSkew(
                        event.timestamp,
                        now: now,
                        allowance: maximumFutureSkew
                    )
            }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.id < $1.id
            }
        return Array(retained.prefix(limit))
    }

    private static func deduplicated(
        _ source: [ProcessActionAuditEvent]
    ) -> [ProcessActionAuditEvent] {
        var byID: [String: ProcessActionAuditEvent] = [:]
        for event in source {
            guard let existing = byID[event.id] else {
                byID[event.id] = event
                continue
            }
            if preferred(event, over: existing) {
                byID[event.id] = event
            }
        }
        return byID.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id < $1.id
        }
    }

    private static func preferred(
        _ candidate: ProcessActionAuditEvent,
        over existing: ProcessActionAuditEvent
    ) -> Bool {
        if candidate.timestamp != existing.timestamp {
            return candidate.timestamp > existing.timestamp
        }
        if candidate.outcome != existing.outcome {
            return candidate.outcome.rawValue < existing.outcome.rawValue
        }
        if candidate.action != existing.action {
            return candidate.action.rawValue < existing.action.rawValue
        }
        if candidate.processLabel != existing.processLabel {
            return candidate.processLabel < existing.processLabel
        }
        return candidate.detail < existing.detail
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
    let callError = Int32(Darwin.errno)
    guard result == 0 else {
        throw MemoryMonitorError.systemCall(name: "sysctl(\(name))", code: callError)
    }
    guard SystemMemorySampler.hasExpectedSysctlByteCount(
        actual: size,
        expected: MemoryLayout<UInt64>.size
    ) else {
        throw MemoryMonitorError.invalidData(
            description: "sysctl(\(name)) 返回的数据大小异常"
        )
    }
    return value
}
