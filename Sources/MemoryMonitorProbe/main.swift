import Foundation
import MemoryMonitorCore

let systemSampler = SystemMemorySampler()
let processSampler = ProcessSampler()

do {
    let system = try systemSampler.sample()
    let processes = try processSampler.sample()
        .sorted { $0.physicalFootprintBytes > $1.physicalFootprintBytes }

    let availablePercent = system.availableFraction * 100
    print("Memory Monitor Phase 0 Probe")
    print("============================")
    print("Total:       \(MemoryFormatter.bytes(system.totalBytes))")
    print("Available*:  \(MemoryFormatter.bytes(system.availableEstimateBytes)) (\(String(format: "%.1f", availablePercent))%)")
    print("Compressed:  \(MemoryFormatter.bytes(system.compressedBytes))")
    print("Wired:       \(MemoryFormatter.bytes(system.wiredBytes))")
    print("Swap:        \(MemoryFormatter.bytes(system.swapUsedBytes)) / \(MemoryFormatter.bytes(system.swapTotalBytes))")
    print("Throttled:   \(system.throttledPages) pages")
    print("Processes:   \(processes.count) enumerated")
    print("\nTop processes by physical footprint (best effort):")
    print("PID      Name                         Footprint    RSS          Parent")
    print("-----------------------------------------------------------------------")

    for process in processes.prefix(20) {
        let name = String(process.name.prefix(27))
        let pathName = process.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let displayName = pathName.flatMap { $0.isEmpty ? nil : $0 } ?? name
        let footprint = process.physicalFootprintIsEstimated
            ? "~" + MemoryFormatter.bytes(process.physicalFootprintBytes)
            : MemoryFormatter.bytes(process.physicalFootprintBytes)
        let columns = [
            padded(String(process.identity.pid), width: 8),
            padded(String(displayName.prefix(27)), width: 28),
            padded(footprint, width: 12),
            padded(MemoryFormatter.bytes(process.residentBytes), width: 12),
            padded(String(process.parentPID), width: 8)
        ]
        print(columns.joined(separator: " "))
    }
    print("\n* Available is an estimate based on free, inactive and purgeable pages; speculative pages are included in free.")
} catch {
    fputs("memory-monitor-probe: \(error)\n", stderr)
    exit(1)
}

private func padded(_ value: String, width: Int) -> String {
    let truncated = String(value.prefix(width))
    return truncated.padding(toLength: width, withPad: " ", startingAt: 0)
}
