import AppKit
import Darwin
import MemoryMonitorCore

@MainActor
final class LiveSmartCleanupRuntime: NSObject, SmartCleanupRuntime {
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now
    private let sampler = ProcessSampler()
    private let policy = ProcessActionPolicy(currentUserID: UInt32(getuid()), monitorPID: Int32(getpid()))
    private var activity: [Int32: TimeInterval] = [:]
    private var cpuSamples: [ProcessIdentity: (time: TimeInterval, nanos: UInt64)] = [:]
    private var handles: [ProcessIdentity: NSRunningApplication] = [:]

    var now: TimeInterval {
        let value = origin.duration(to: clock.now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }

    override init() {
        super.init()
        for app in NSWorkspace.shared.runningApplications { activity[app.processIdentifier] = now }
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(activated(_:)), name: name, object: nil)
        }
    }

    @objc private func activated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        activity[app.processIdentifier] = now
    }

    func inventory() async -> [CleanupObservation] {
        let running = NSWorkspace.shared.runningApplications
        let pids = Set(running.map(\.processIdentifier))
        activity = activity.filter { pids.contains($0.key) }
        handles = handles.filter { !$0.value.isTerminated }
        cpuSamples = cpuSamples.filter { pids.contains($0.key.pid) }
        var observations: [CleanupObservation] = []
        for app in running where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            guard !Task.isCancelled else { break }
            if let observation = await observe(app) { observations.append(observation) }
        }
        return observations.sorted { ProcessSnapshot.memoryDescending($0.application.process, $1.application.process) }
    }

    func inspect(_ application: CleanupApplication) async -> CleanupObservation? {
        guard let handle = handles[application.id], !handle.isTerminated,
              let observation = await observe(handle),
              policy.validate(expected: application.process, current: observation.application.process).allowed,
              observation.application.authorization == application.authorization else { return nil }
        return observation
    }

    private func observe(_ app: NSRunningApplication) async -> CleanupObservation? {
        guard let key = authorization(app), app.isFinishedLaunching, !app.isTerminated else { return nil }
        let pid = app.processIdentifier
        let sampler = sampler
        guard let process = await Task.detached(priority: .utility, operation: { sampler.sample(pid: pid) }).value,
              !Task.isCancelled, !app.isTerminated, authorization(app) == key,
              process.executablePath.map(Self.canonical) == key.executablePath,
              policy.validate(expected: process, current: process).allowed else { return nil }
        let instant = now
        if activity[pid] == nil { activity[pid] = instant }
        var cpu: Double?
        if let previous = cpuSamples[process.identity], instant - previous.time >= 0.25,
           instant - previous.time <= 15, process.cpuTimeNanos >= previous.nanos {
            cpu = Double(process.cpuTimeNanos - previous.nanos) / 1e9 / (instant - previous.time) * 100
        }
        cpuSamples[process.identity] = (instant, process.cpuTimeNanos)
        handles[process.identity] = app
        return CleanupObservation(application: .init(process: process, authorization: key),
            isFrontmost: app.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
            secondsSinceActivity: instant - (activity[pid] ?? instant), cpuPercent: cpu)
    }

    func requestQuit(_ application: CleanupApplication) -> CleanupQuitRequest {
        // Use the retained NSRunningApplication, never rebind a termination to a PID.
        guard !Task.isCancelled, let app = handles[application.id], !app.isTerminated,
              app.isFinishedLaunching, app.activationPolicy == .regular,
              authorization(app) == application.authorization,
              !app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier,
              now - (activity[app.processIdentifier] ?? now) >= 120,
              let sample = cpuSamples[application.id], now - sample.time < 2 else { return .changed }
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
        guard executablePath.hasPrefix(bundlePath + "/"), !bundlePath.hasPrefix("/System/") else { return nil }
        return .init(bundleIdentifier: identifier, bundlePath: bundlePath, executablePath: executablePath)
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
