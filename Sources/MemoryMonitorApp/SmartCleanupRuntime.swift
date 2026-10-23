import AppKit
import Darwin
import MemoryMonitorCore

protocol CleanupProcessScanning: Sendable {
    func sampleDetailed(
        at timestamp: Date,
        budget: ProcessScanBudget?
    ) throws -> ProcessSamplingResult
    func descendantProcessIDs(
        of rootPID: Int32,
        budget: ProcessScanBudget?
    ) throws -> Set<Int32>
}

extension ProcessSampler: CleanupProcessScanning {}

@MainActor
final class LiveSmartCleanupRuntime: NSObject, SmartCleanupRuntime {
    private struct ActivityInventory: Sendable {
        let scan: ProcessSamplingResult?
        let families: [Int32: Set<Int32>]
        let sampledAt: TimeInterval
        let generation: UInt64
        let metrics: CleanupInventoryMetrics
    }
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now
    private let timeProvider: (@MainActor () -> TimeInterval)?
    private let sampler: any CleanupProcessScanning
    private let policy = ProcessActionPolicy(currentUserID: UInt32(getuid()), monitorPID: Int32(getpid()))
    private var activity: [Int32: TimeInterval] = [:]
    private var cpuSamples: [ProcessIdentity: (time: TimeInterval, percent: Double?)] = [:]
    private var cpuActivity = CleanupCPUActivityTracker()
    private var handles: [ProcessIdentity: NSRunningApplication] = [:]
    private var worker: Task<ActivityInventory, Never>?
    private var workerToken: UUID?
    private var scanGeneration: UInt64 = 0
    private let scanBudgetMilliseconds = 1_500
    private let maximumScanMembers = 20_000

    var now: TimeInterval {
        if let timeProvider { return timeProvider() }
        let value = origin.duration(to: clock.now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    init(
        timeProvider: (@MainActor () -> TimeInterval)? = nil,
        sampler: any CleanupProcessScanning = ProcessSampler()
    ) {
        self.timeProvider = timeProvider
        self.sampler = sampler
        super.init()
        for app in NSWorkspace.shared.runningApplications { activity[app.processIdentifier] = now }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activated(_:)), name: name, object: nil)
        }
    }

    @objc private func activated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        activity[app.processIdentifier] = now
    }

    func inventory() async -> [CleanupObservation] {
        await inventoryReport().observations
    }

    func inventoryReport() async -> CleanupInventory {
        let running = NSWorkspace.shared.runningApplications
        let pids = Set(running.map(\.processIdentifier))
        activity = activity.filter { pids.contains($0.key) }
        handles = handles.filter { !$0.value.isTerminated }
        cpuSamples = cpuSamples.filter { pids.contains($0.key.pid) }
        cpuActivity.retain(Set(cpuSamples.keys))
        let bundles = Dictionary(running.compactMap { app -> (Int32, String)? in
            guard app.processIdentifier != getpid(), app.activationPolicy == .regular,
                  inventorySkipReason(app) == nil, let path = app.bundleURL?.path else { return nil }
            return (app.processIdentifier, Self.canonical(path))
        }, uniquingKeysWith: { first, _ in first })
        let scan = await processScan(bundles: bundles)
        guard scan.generation == scanGeneration else {
            return CleanupInventory(observations: [], skipped: [], metrics: scan.metrics)
        }
        let sampledAt = scan.sampledAt
        if !scan.metrics.complete {
            let skipped = running.compactMap { app -> CleanupSkip? in
                guard app.processIdentifier != getpid(),
                      app.activationPolicy == .regular else { return nil }
                return CleanupSkip(name: displayName(for: app), reason: .samplingFailed)
            }
            return CleanupInventory(
                observations: [],
                skipped: skipped,
                metrics: scan.metrics
            )
        }
        var observations: [CleanupObservation] = []
        var skipped: [CleanupSkip] = []
        for app in running {
            guard !Task.isCancelled else { break }
            if app.processIdentifier == getpid() {
                skipped.append(CleanupSkip(name: "Memory Monitor", reason: .protectedProcess))
                continue
            }
            guard app.activationPolicy == .regular else { continue }
            if let reason = inventorySkipReason(app) {
                skipped.append(CleanupSkip(name: displayName(for: app), reason: reason))
                continue
            }
            switch observeResult(app, scan: scan, sampledAt: sampledAt) {
            case .success(let observation):
                observations.append(observation)
            case .failure(let reason):
                skipped.append(CleanupSkip(name: displayName(for: app), reason: reason))
            }
        }
        observations.sort { ProcessSnapshot.memoryDescending($0.application.process, $1.application.process) }
        skipped.sort {
            if $0.reason.rawValue != $1.reason.rawValue {
                return $0.reason.rawValue < $1.reason.rawValue
            }
            return $0.name < $1.name
        }
        return CleanupInventory(
            observations: observations,
            skipped: skipped,
            metrics: scan.metrics
        )
    }

    private func inventorySkipReason(_ app: NSRunningApplication) -> CleanupSkipReason? {
        guard let identifier = app.bundleIdentifier, !identifier.isEmpty else {
            return .missingBundle
        }
        guard let bundle = app.bundleURL, bundle.isFileURL,
              let executable = app.executableURL, executable.isFileURL else {
            return .missingExecutable
        }
        let bundlePath = Self.canonical(bundle.path)
        let executablePath = Self.canonical(executable.path)
        if bundlePath.hasPrefix("/System/") { return .systemPath }
        guard executablePath.hasPrefix(bundlePath + "/") else { return .missingExecutable }
        guard app.isFinishedLaunching, !app.isTerminated else { return .notReady }
        return nil
    }

    private func displayName(for app: NSRunningApplication) -> String {
        let raw = app.localizedName ?? app.bundleIdentifier ?? "未知应用"
        return String(raw.prefix(80))
    }

    func inspect(_ application: CleanupApplication) async -> CleanupObservation? {
        guard let handle = handles[application.id], !handle.isTerminated,
              let observation = await observe(handle),
              policy.validate(expected: application.process, current: observation.application.process).allowed,
              observation.application.authorization == application.authorization else { return nil }
        return observation
    }

    private func observe(_ app: NSRunningApplication) async -> CleanupObservation? {
        guard let path = app.bundleURL?.path else { return nil }
        let scan = await processScan(bundles: [app.processIdentifier: Self.canonical(path)])
        guard scan.metrics.complete, scan.generation == scanGeneration else { return nil }
        if case .success(let observation) = observeResult(app, scan: scan, sampledAt: scan.sampledAt) {
            return observation
        }
        return nil
    }

    private func observeResult(
        _ app: NSRunningApplication, scan inventory: ActivityInventory, sampledAt: TimeInterval
    ) -> Result<CleanupObservation, CleanupSkipReason> {
        guard let key = authorization(app), app.isFinishedLaunching, !app.isTerminated else {
            return .failure(CleanupSkipReason.notReady)
        }
        let pid = app.processIdentifier
        guard let scan = inventory.scan, let process = scan.processes.first(where: { $0.identity.pid == pid }) else {
            return .failure(CleanupSkipReason.samplingFailed)
        }
        guard !Task.isCancelled, !app.isTerminated, authorization(app) == key,
              process.executablePath.map(Self.canonical) == key.executablePath else {
            return .failure(CleanupSkipReason.samplingFailed)
        }
        let validation = policy.validate(expected: process, current: process)
        guard validation.allowed else {
            let reason: CleanupSkipReason = validation.reason == .protectedProcess
                ? .protectedProcess
                : .samplingFailed
            return .failure(reason)
        }
        let instant = sampledAt
        if cpuSamples.keys.contains(where: { $0.pid == pid && $0 != process.identity }) {
            activity[pid] = instant
            cpuSamples = cpuSamples.filter { $0.key.pid != pid }
        }
        if activity[pid] == nil { activity[pid] = instant }
        let application = CleanupApplication(process: process, authorization: key)
        let cpu: Double?
        if let family = inventory.families[pid] {
            cpu = cpuActivity.update(application: application, scan: scan, at: instant, descendantPIDs: family)
        } else {
            cpuActivity.retain(Set(cpuSamples.keys).subtracting([process.identity]))
            cpu = nil
        }
        cpuSamples[process.identity] = (instant, cpu)
        handles[process.identity] = app
        return .success(CleanupObservation(
            application: .init(process: process, authorization: key),
            isFrontmost: app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            secondsSinceActivity: instant - (activity[pid] ?? instant),
            cpuPercent: cpu
        ))
    }

    func requestQuit(_ application: CleanupApplication) -> CleanupQuitRequest {
        // Use the retained NSRunningApplication, never rebind a termination to a PID.
        guard !Task.isCancelled, let app = handles[application.id], !app.isTerminated,
              app.isFinishedLaunching, app.activationPolicy == .regular,
              authorization(app) == application.authorization,
              !app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
              now - (activity[app.processIdentifier] ?? now) >= 120,
              let sample = cpuSamples[application.id], now >= sample.time, now - sample.time < 2,
              let cpu = sample.percent, cpu.isFinite, cpu >= 0,
              cpu < CleanupEligibilityPolicy.standard.busyCPUPercent else { return .changed }
        return app.terminate() ? .sent : .refused
    }

    func exitState(_ application: CleanupApplication) -> CleanupExitState {
        guard let app = handles[application.id], app.isTerminated else { return .running }
        if NSWorkspace.shared.runningApplications.contains(where: {
            !$0.isTerminated && $0 !== app && authorization($0) == application.authorization
        }) { return .relaunched }
        return .exited
    }

    private func authorization(_ app: NSRunningApplication) -> CleanupAuthorization? {
        guard app.activationPolicy == .regular, let identifier = app.bundleIdentifier,
              let bundle = app.bundleURL, let executable = app.executableURL,
              bundle.isFileURL, executable.isFileURL else { return nil }
        let bundlePath = Self.canonical(bundle.path)
        let executablePath = Self.canonical(executable.path)
        guard executablePath.hasPrefix(bundlePath + "/"), !bundlePath.hasPrefix("/System/"),
              let bundleInode = Self.inode(at: bundlePath),
              let executableInode = Self.inode(at: executablePath) else { return nil }
        return .init(
            bundleIdentifier: identifier,
            bundlePath: bundlePath,
            executablePath: executablePath,
            bundleInode: bundleInode,
            executableInode: executableInode
        )
    }

    private func processScan(bundles: [Int32: String]) async -> ActivityInventory {
        scanGeneration &+= 1
        let requestGeneration = scanGeneration
        if let worker {
            let token = workerToken
            worker.cancel()
            _ = await worker.value
            // A newer request may already have installed its own worker while
            // this caller was waiting. Only clear the handle we waited on.
            if workerToken == token {
                self.worker = nil
                self.workerToken = nil
            }
        }
        // Several callers can wait on the same old worker. Only the caller
        // that still owns the newest generation may create the next worker.
        guard scanGeneration == requestGeneration else {
            return supersededInventory(generation: requestGeneration, sampledAt: now)
        }

        let started = ContinuousClock.now
        let deadline = started.advanced(by: .milliseconds(scanBudgetMilliseconds))
        let budget = ProcessScanBudget(
            deadline: deadline,
            maximumMembers: maximumScanMembers
        )
        let sampler = self.sampler
        let sampledAt = now
        let cancellation = ScanCancellationBox()

        let task = Task.detached(priority: .utility) { () -> ActivityInventory in
            let scanStarted = ContinuousClock.now
            do {
                let scan = try sampler.sampleDetailed(at: Date(), budget: budget)
                var families: [Int32: Set<Int32>] = [:]
                var descendantCache: [Int32: Set<Int32>] = [:]
                var remainingMembers = max(budget.maximumMembers - scan.sampledProcessCount, 0)
                var complete = true
                var budgetExhausted = false

                for (pid, path) in bundles {
                    try Task.checkCancellation()
                    var roots: Set<Int32> = [pid]
                    for process in scan.processes where process.executablePath?.hasPrefix(path + "/") == true {
                        roots.insert(process.identity.pid)
                    }
                    for failure in scan.readFailures where failure.executablePath?.hasPrefix(path + "/") == true {
                        roots.insert(failure.pid)
                    }
                    var family = roots
                    for root in roots {
                        if let cached = descendantCache[root] {
                            family.formUnion(cached)
                            continue
                        }
                        guard remainingMembers > 0 else {
                            complete = false
                            budgetExhausted = true
                            break
                        }
                        do {
                            let descendants = try sampler.descendantProcessIDs(
                                of: root,
                                budget: ProcessScanBudget(
                                    deadline: deadline,
                                    maximumMembers: remainingMembers
                                )
                            )
                            descendantCache[root] = descendants
                            family.formUnion(descendants)
                            remainingMembers = max(remainingMembers - descendants.count, 0)
                        } catch {
                            complete = false
                            if error is ProcessScanBudgetError {
                                budgetExhausted = true
                            }
                            break
                        }
                    }
                    guard complete else { break }
                    families[pid] = family
                }

                let memberCount = scan.sampledProcessCount
                    + Set(families.values.flatMap { $0 }).count
                return ActivityInventory(
                    scan: scan,
                    families: families,
                    sampledAt: sampledAt,
                    generation: requestGeneration,
                    metrics: CleanupInventoryMetrics(
                        generation: requestGeneration,
                        scanCount: 1,
                        memberCount: memberCount,
                        complete: complete,
                        durationMilliseconds: Self.milliseconds(scanStarted.duration(to: ContinuousClock.now)),
                        cancellationLatencyMilliseconds: nil,
                        budgetExhausted: budgetExhausted
                    )
                )
            } catch {
                return ActivityInventory(
                    scan: nil,
                    families: [:],
                    sampledAt: sampledAt,
                    generation: requestGeneration,
                    metrics: CleanupInventoryMetrics(
                        generation: requestGeneration,
                        scanCount: 1,
                        memberCount: 0,
                        complete: false,
                        durationMilliseconds: Self.milliseconds(scanStarted.duration(to: ContinuousClock.now)),
                        cancellationLatencyMilliseconds: nil,
                        budgetExhausted: error is ProcessScanBudgetError
                    )
                )
            }
        }
        let token = UUID()
        self.worker = task
        self.workerToken = token

        let result = await withTaskCancellationHandler(operation: {
            await task.value
        }, onCancel: {
            task.cancel()
            cancellation.record(ContinuousClock.now)
        })
        if workerToken == token {
            self.worker = nil
            self.workerToken = nil
        }
        let completed = ContinuousClock.now
        let cancellationLatency = cancellation.instant.map {
            Self.milliseconds($0.duration(to: completed))
        }
        return ActivityInventory(
            scan: result.scan,
            families: result.families,
            sampledAt: result.sampledAt,
            generation: result.generation,
            metrics: CleanupInventoryMetrics(
                generation: result.metrics.generation,
                scanCount: result.metrics.scanCount,
                memberCount: result.metrics.memberCount,
                complete: result.metrics.complete,
                durationMilliseconds: result.metrics.durationMilliseconds,
                cancellationLatencyMilliseconds: cancellationLatency,
                budgetExhausted: result.metrics.budgetExhausted
            )
        )
    }

    private func supersededInventory(generation: UInt64, sampledAt: TimeInterval) -> ActivityInventory {
        ActivityInventory(
            scan: nil,
            families: [:],
            sampledAt: sampledAt,
            generation: generation,
            metrics: CleanupInventoryMetrics(
                generation: generation,
                scanCount: 0,
                memberCount: 0,
                complete: false,
                durationMilliseconds: 0,
                cancellationLatencyMilliseconds: nil,
                budgetExhausted: false
            )
        )
    }

    nonisolated private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return max(
            Double(components.seconds) * 1000
                + Double(components.attoseconds) / 1_000_000_000_000_000,
            0
        )
    }

    private static func inode(at path: String) -> UInt64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return UInt64(st.st_ino)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func sampleMemory() async -> SystemMemorySnapshot? {
        await Task.detached(priority: .utility) {
            guard let sample = try? SystemMemorySampler().sample(), sample.isStructurallyValid else { return nil }
            return sample
        }.value
    }

    func relieveOwnMemory() async {
        await Task.detached(priority: .utility) { _ = malloc_zone_pressure_relief(nil, 0) }.value
    }

    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
}


private final class ScanCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousClock.Instant?

    func record(_ instant: ContinuousClock.Instant) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil {
            value = instant
        }
    }

    var instant: ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
