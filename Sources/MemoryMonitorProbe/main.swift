import Foundation
import MemoryMonitorCore

private enum ProbeOutputMode {
    case humanReadable
    case compatibilityJSON
    case help
}

private enum ProbeArgumentError: Error, CustomStringConvertible {
    case unsupported([String])

    var description: String {
        switch self {
        case .unsupported(let arguments):
            return "unsupported arguments: " + arguments.joined(separator: " ")
        }
    }
}

private let outputMode: ProbeOutputMode
do {
    outputMode = try parseOutputMode(Array(CommandLine.arguments.dropFirst()))
} catch {
    fputs("memory-monitor-probe: \(error)\n", stderr)
    fputs("Use --help to list supported arguments.\n", stderr)
    exit(2)
}

if outputMode == .help {
    printUsage()
    exit(0)
}

let snapshot = MonitorSampler().sample()

do {
    switch outputMode {
    case .humanReadable:
        try printHumanReadable(snapshot)
    case .compatibilityJSON:
        try printCompatibilityJSON(snapshot)
    case .help:
        break
    }
} catch {
    fputs("memory-monitor-probe: \(error)\n", stderr)
    exit(1)
}

private func parseOutputMode(_ arguments: [String]) throws -> ProbeOutputMode {
    switch arguments {
    case []:
        return .humanReadable
    case ["--compatibility-json"]:
        return .compatibilityJSON
    case ["--help"], ["-h"]:
        return .help
    default:
        throw ProbeArgumentError.unsupported(arguments)
    }
}

private func printUsage() {
    print("Usage: memory-monitor-probe [--compatibility-json]")
    print("")
    print("  no arguments          Print the detailed human-readable probe.")
    print("  --compatibility-json  Print a redacted compatibility report as JSON.")
}

private func printCompatibilityJSON(_ snapshot: MonitorSnapshot) throws {
    let environment = ProcessInfo.processInfo.environment
    let checkoutState = CompatibilityCheckoutState(
        rawValue: environment["MEMORY_MONITOR_CHECKOUT_STATE"] ?? ""
    ) ?? .unknown
    let report = CompatibilityProbeReport.current(
        snapshot: snapshot,
        productVersion: environment["MEMORY_MONITOR_PRODUCT_VERSION"],
        buildNumber: environment["MEMORY_MONITOR_BUILD_NUMBER"],
        sourceRevision: environment["MEMORY_MONITOR_SOURCE_REVISION"],
        checkoutState: checkoutState
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(report)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func printHumanReadable(_ snapshot: MonitorSnapshot) throws {
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
}

private func padded(_ value: String, width: Int) -> String {
    let truncated = String(value.prefix(width))
    return truncated.padding(toLength: width, withPad: " ", startingAt: 0)
}
