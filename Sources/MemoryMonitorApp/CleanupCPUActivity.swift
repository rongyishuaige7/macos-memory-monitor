import Foundation
import MemoryMonitorCore

/// Conservative activity estimate for the observable application family.
/// Keep per-member counters: adding totals would hide a busy newly spawned
/// helper behind the CPU time of another helper that just exited.
struct CleanupCPUActivityTracker {
    private struct Baseline {
        let time: TimeInterval
        let counters: [ProcessIdentity: UInt64]
    }
    private var baselines: [ProcessIdentity: Baseline] = [:]

    mutating func retain(_ identities: Set<ProcessIdentity>) {
        baselines = baselines.filter { identities.contains($0.key) }
    }

    mutating func update(application: CleanupApplication, scan: ProcessSamplingResult,
                         at time: TimeInterval, descendantPIDs: Set<Int32>? = nil) -> Double? {
        let id = application.id
        guard time.isFinite, scan.status.quality.isUsable, scan.status.hasFiniteSampleTimestamp,
              scan.processes.contains(where: { $0.identity == id }),
              scan.listedProcessCount == scan.processes.count + scan.readFailures.count else {
            baselines.removeValue(forKey: id)
            return nil
        }
        let bundlePrefix = application.authorization.bundlePath + "/"
        var members: Set<Int32> = (descendantPIDs ?? []).union([id.pid])
        var parents: [Int32: Int32] = [:]
        for process in scan.processes {
            parents[process.identity.pid] = process.parentPID
            if process.executablePath?.hasPrefix(bundlePrefix) == true { members.insert(process.identity.pid) }
        }
        for failure in scan.readFailures {
            if let parent = failure.parentPID { parents[failure.pid] = parent }
            if failure.executablePath?.hasPrefix(bundlePrefix) == true { members.insert(failure.pid) }
        }
        var changed = true
        while changed {
            changed = false
            for (pid, parent) in parents where members.contains(parent) {
                if members.insert(pid).inserted { changed = true }
            }
        }
        for failure in scan.readFailures {
            let uncertainOwner = failure.userID == nil && failure.executablePath == nil
                && failure.reason != .disappeared
            let uncertainRelationship = (descendantPIDs == nil && failure.parentPID == nil)
                || (failure.userID == application.process.userID && failure.executablePath == nil)
            if members.contains(failure.pid) || uncertainOwner || uncertainRelationship {
                baselines.removeValue(forKey: id)
                return nil
            }
        }
        var counters: [ProcessIdentity: UInt64] = [:]
        for process in scan.processes where members.contains(process.identity.pid) {
            // Saturation loses the ability to detect future counter growth.
            guard process.cpuTimeNanos < UInt64.max else {
                baselines.removeValue(forKey: id)
                return nil
            }
            counters[process.identity] = process.cpuTimeNanos
        }
        guard Set(counters.keys.map(\.pid)) == members else {
            baselines.removeValue(forKey: id)
            return nil
        }
        let previous = baselines.updateValue(Baseline(time: time, counters: counters), forKey: id)
        guard let previous, time - previous.time >= 0.25, time - previous.time <= 15,
              Set(previous.counters.keys) == Set(counters.keys) else { return nil }
        var delta: Double = 0
        for (member, value) in counters {
            guard let old = previous.counters[member], value >= old else { return nil }
            delta += Double(value - old)
        }
        let percent = delta / 1e9 / (time - previous.time) * 100
        return percent.isFinite && percent >= 0 ? percent : nil
    }
}
