import Foundation
import MemoryMonitorCore

let snapshot = MonitorSampler().sample()

do {
    guard let system = snapshot.validatedSystemSample else {
        throw MemoryMonitorError.invalidData(
            description: "系统指标不可用：\(snapshot.systemStatus.shortDescription)"
        )
    }
    let processes = snapshot.processes

    let availablePercent = system.availableFraction * 100
    print("Memory Monitor Probe")
    print("============================")
    print("Sampling:    \(snapshot.samplingMode.displayName)")
    print("Duration:    \(String(format: "%.1f", snapshot.diagnostics.totalDurationMilliseconds)) ms")
    if let processDuration = snapshot.diagnostics.processDurationMilliseconds {
        print("Process scan: \(String(format: "%.1f", processDuration)) ms")
    } else {
        print("Process scan: skipped")
    }
    print("Total:       \(MemoryFormatter.bytes(system.totalBytes))")
    print("Memory used: \(String(format: "%.1f", system.usedFraction * 100))% (estimated)")
    print("Available*:  \(MemoryFormatter.bytes(system.availableEstimateBytes)) (\(String(format: "%.1f", availablePercent))%)")
    print("Compressed:  \(MemoryFormatter.bytes(system.compressedBytes))")
    print("Wired:       \(MemoryFormatter.bytes(system.wiredBytes))")
    print("Swap:        \(MemoryFormatter.bytes(system.swapUsedBytes)) / \(MemoryFormatter.bytes(system.swapTotalBytes))")
    print("Throttled:   \(system.throttledPages) pages")
    print("CPU:         \(snapshot.cpuStatus.shortDescription)")
    if let gpu = snapshot.gpuUsageFraction {
        print("GPU:         \(String(format: "%.1f", gpu * 100))% (\(snapshot.gpuStatus.quality.displayName))")
    } else {
        print("GPU:         -- (\(snapshot.gpuStatus.shortDescription))")
    }
    print("Processes:   \(snapshot.sampledProcessCount)/\(snapshot.listedProcessCount) enumerated (\(snapshot.processStatus.quality.displayName))")
    print("\nTop processes by physical footprint (best effort):")
    print("PID      Name                         Footprint    RSS          Parent")
    print("-----------------------------------------------------------------------")

    for process in processes.prefix(20) {
        let name = String(process.name.prefix(27))
        let pathName = process.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
        let displayName = pathName
            .flatMap { WorkingDirectoryLabelSanitizer.label(fromComponent: $0) }
            ?? name
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
    print("\nTop workload groups by attribution footprint:")
    print("Group                         Footprint    Processes  Evidence")
    print("----------------------------------------------------------------")
    for group in snapshot.groups.prefix(10) {
        let evidence = String(group.attributionReason.displayName.prefix(28))
        let columns = [
            padded(String(group.title.prefix(29)), width: 30),
            padded(MemoryFormatter.bytes(group.attributedFootprintBytes), width: 12),
            padded(String(group.processCount), width: 10),
            evidence
        ]
        print(columns.joined(separator: " "))
    }

    if let recommendation = RecommendationEngine().evaluate(
        RecommendationContext(current: snapshot)
    ).first {
        print("\nRead-only recommendation:")
        print("  [\(recommendation.severity.displayName)] \(recommendation.title)")
        print("  \(recommendation.detail)")
        if !recommendation.evidence.isEmpty {
            let evidence = recommendation.evidence
                .prefix(3)
                .map { "\($0.label)=\($0.value)" }
                .joined(separator: " · ")
            print("  Evidence: \(evidence)")
        }
        print("  Confidence: \(recommendation.confidencePercent)%")
    } else {
        print("\nRead-only recommendation: none")
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
