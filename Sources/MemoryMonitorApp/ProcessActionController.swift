import AppKit
import Combine
import Darwin
import Foundation
import MemoryMonitorCore

enum ProcessActionState: Equatable {
    case idle
    case requestingGraceful(ProcessIdentity)
    case waitingForGraceful(ProcessIdentity, Date)
    case timedOut(ProcessIdentity)
    case forceTerminating(ProcessIdentity)
    case completed(ProcessIdentity, ProcessActionKind, String)
    case denied(ProcessIdentity?, String)
    case failed(ProcessIdentity?, String)
    case cancelled(ProcessIdentity?, String)
}

enum ProcessActionStatusTone {
    case neutral
    case success
    case warning
    case failure

    var iconName: String {
        switch self {
        case .neutral: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark.octagon"
        }
    }
}

struct ProcessActionStatus {
    let message: String
    let tone: ProcessActionStatusTone
}

/// The result of one signal-delivery attempt. Keeping this separate from the
/// controller makes the safety policy and state machine testable without ever
/// sending a signal to a real process.
enum ProcessActionSignalResult: Equatable, Sendable {
    case sent
    case alreadyExited
    case failed(Int32)
}

/// Runtime boundary for process actions. The controller is deliberately
/// unaware of libproc, Darwin signals, AppKit application termination, and
/// timekeeping. Production uses `LiveProcessActionRuntime`; tests can
/// provide a deterministic fake implementation.
@MainActor
protocol ProcessActionRuntime: AnyObject {
    func sample(pid: Int32) async -> ProcessSnapshot?
    func processExists(pid: Int32) async -> Bool
    func sendGraceful(to process: ProcessSnapshot) async -> ProcessActionSignalResult
    func sendForce(to process: ProcessSnapshot) async -> ProcessActionSignalResult
    /// Wall-clock time is used only for the human-readable deadline shown in
    /// the UI. It must not be used to decide whether an action timed out.
    func wallClockNow() -> Date
    /// A monotonic continuous clock is used for all timeout decisions and is
    /// immune to manual/NTP wall-clock adjustments and system sleep.
    func monotonicNanoseconds() -> UInt64
    func sleep(for duration: Duration) async throws
}

/// Real macOS implementation of the runtime boundary. Potentially expensive
/// libproc reads run on a utility task so the menu bar popover remains
/// responsive while an action is being prepared or verified.
@MainActor
final class LiveProcessActionRuntime: ProcessActionRuntime {
    private let sampler: ProcessSampler

    init(sampler: ProcessSampler = ProcessSampler()) {
        self.sampler = sampler
    }

    func sample(pid: Int32) async -> ProcessSnapshot? {
        let sampler = sampler
        return await Task.detached(priority: .utility) {
            sampler.sample(pid: pid)
        }.value
    }

    func processExists(pid: Int32) async -> Bool {
        await Task.detached(priority: .utility) {
            Self.processExistsSynchronously(pid)
        }.value
    }

    func sendGraceful(to process: ProcessSnapshot) async -> ProcessActionSignalResult {
        if let application = guiApplication(for: process) {
            if application.terminate() {
                return .sent
            }
            return Self.processExistsSynchronously(process.identity.pid)
                ? .failed(EIO)
                : .alreadyExited
        }
        return sendDarwinSignal(SIGTERM, to: process.identity.pid)
    }

    func sendForce(to process: ProcessSnapshot) async -> ProcessActionSignalResult {
        if let application = guiApplication(for: process) {
            if application.forceTerminate() {
                return .sent
            }
            return Self.processExistsSynchronously(process.identity.pid)
                ? .failed(EIO)
                : .alreadyExited
        }
        return sendDarwinSignal(SIGKILL, to: process.identity.pid)
    }

    func wallClockNow() -> Date { Date() }

    nonisolated func monotonicNanoseconds() -> UInt64 {
        continuousNanoseconds()
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    private func guiApplication(for process: ProcessSnapshot) -> NSRunningApplication? {
        guard process.identity.pid > 0,
              let application = NSRunningApplication(
                processIdentifier: pid_t(process.identity.pid)
              ),
              application.bundleIdentifier != nil,
              application.activationPolicy != .prohibited else {
            return nil
        }
        return application
    }

    private func sendDarwinSignal(_ signal: Int32, to pid: Int32) -> ProcessActionSignalResult {
        guard pid > 0 else { return .failed(EINVAL) }
        guard Darwin.kill(pid_t(pid), signal) == 0 else {
            let code = Int32(Darwin.errno)
            return code == ESRCH ? .alreadyExited : .failed(code)
        }
        return .sent
    }

    nonisolated private static func processExistsSynchronously(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        return Int32(Darwin.errno) != ESRCH
    }
}

/// Returns a nanosecond clock that continues across system sleep. The
/// timebase conversion is cheap compared with a process identity read and is
/// intentionally kept outside the main-actor runtime object.
private func continuousNanoseconds() -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    guard mach_timebase_info(&timebase) == KERN_SUCCESS,
          timebase.denom > 0 else {
        return DispatchTime.now().uptimeNanoseconds
    }

    let ticks = mach_continuous_time()
    let (scaled, overflow) = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer))
    guard !overflow else { return UInt64.max }
    return scaled / UInt64(timebase.denom)
}

/// Serializes user-confirmed process actions and keeps all signal delivery
/// behind the same identity/safety checks. The app never performs a force
/// termination unless a graceful request for the same process timed out and
/// the user confirms a second time.
@MainActor
final class ProcessActionController: ObservableObject {
    @Published private(set) var state: ProcessActionState = .idle
    @Published private(set) var recentEvents: [ProcessActionAuditEvent] = []
    @Published private(set) var auditError: String?

    private let policy: ProcessActionPolicy
    private let runtime: any ProcessActionRuntime
    private let auditStore: ProcessActionAuditStore
    private let gracefulTimeout: TimeInterval
    private let forceVerificationTimeout: TimeInterval
    private let pollInterval: Duration = .milliseconds(250)

    private var targetProcess: ProcessSnapshot?
    private var actionTask: Task<Void, Never>?
    private var operationToken = UUID()

    init(
        currentUserID: UInt32 = UInt32(getuid()),
        monitorPID: Int32 = Int32(getpid()),
        sampler: ProcessSampler = ProcessSampler(),
        runtime: (any ProcessActionRuntime)? = nil,
        auditStore: ProcessActionAuditStore = ProcessActionAuditStore(),
        gracefulTimeout: TimeInterval = 8,
        forceVerificationTimeout: TimeInterval = 2
    ) {
        self.policy = ProcessActionPolicy(
            currentUserID: currentUserID,
            monitorPID: monitorPID
        )
        self.runtime = runtime ?? LiveProcessActionRuntime(sampler: sampler)
        self.auditStore = auditStore
        self.gracefulTimeout = max(gracefulTimeout.isFinite ? gracefulTimeout : 8, 1)
        self.forceVerificationTimeout = max(
            forceVerificationTimeout.isFinite ? forceVerificationTimeout : 2,
            0.5
        )

        Task { [weak self] in
            await self?.loadAuditEvents()
        }
    }

    deinit {
        actionTask?.cancel()
    }

    var isBusy: Bool {
        switch state {
        case .requestingGraceful, .waitingForGraceful, .forceTerminating:
            return true
        case .idle, .timedOut, .completed, .denied, .failed, .cancelled:
            return false
        }
    }

    var gracefulTimeoutForDisplay: TimeInterval { gracefulTimeout }

    func eligibility(for process: ProcessSnapshot) -> ProcessActionValidation {
        policy.validate(expected: process, current: process)
    }

    func isBusy(for identity: ProcessIdentity) -> Bool {
        guard isBusy else { return false }
        return stateIdentity == identity
    }

    func canForceTerminate(for identity: ProcessIdentity) -> Bool {
        guard case .timedOut(let timedOutIdentity) = state else { return false }
        return timedOutIdentity == identity && targetProcess?.identity == identity
    }

    func canCancel(for identity: ProcessIdentity) -> Bool {
        stateIdentity == identity && cancellableAction != nil
    }

    func status(for identity: ProcessIdentity) -> ProcessActionStatus? {
        switch state {
        case .requestingGraceful(let target) where target == identity:
            return ProcessActionStatus(
                message: "正在重新验证进程身份…",
                tone: .neutral
            )
        case .waitingForGraceful(let target, _ ) where target == identity:
            return ProcessActionStatus(
                message: "已请求优雅退出，等待进程结束（最长 \(Int(gracefulTimeout)) 秒）…",
                tone: .neutral
            )
        case .timedOut(let target) where target == identity:
            return ProcessActionStatus(
                message: "优雅退出等待超时；只有确认没有未保存工作时才应强制结束。",
                tone: .warning
            )
        case .forceTerminating(let target) where target == identity:
            return ProcessActionStatus(
                message: "正在重新验证并发送强制结束请求…",
                tone: .warning
            )
        case .completed(let target, let action, let message) where target == identity:
            return ProcessActionStatus(
                message: "\(action.displayName)：\(message)",
                tone: .success
            )
        case .denied(let target, let message) where target == nil || target == identity:
            return ProcessActionStatus(message: message, tone: .failure)
        case .failed(let target, let message) where target == nil || target == identity:
            return ProcessActionStatus(message: message, tone: .failure)
        case .cancelled(let target, let message) where target == nil || target == identity:
            return ProcessActionStatus(message: message, tone: .neutral)
        default:
            return nil
        }
    }

    func requestGracefulExit(for process: ProcessSnapshot) {
        guard !isBusy else { return }
        cancelCurrentTask()

        let validation = eligibility(for: process)
        guard validation.allowed else {
            targetProcess = process
            state = .denied(process.identity, validation.message)
            Task { [weak self] in
                await self?.appendAudit(
                    action: .gracefulExit,
                    outcome: .denied,
                    process: process,
                    detail: validation.message
                )
            }
            return
        }

        targetProcess = process
        let token = UUID()
        operationToken = token
        state = .requestingGraceful(process.identity)
        actionTask = Task { [weak self] in
            await self?.performGracefulExit(expected: process, token: token)
        }
    }

    func requestForceTerminate(for process: ProcessSnapshot) {
        guard canForceTerminate(for: process.identity),
              let expected = targetProcess,
              expected.identity == process.identity else {
            let message = "强制结束仅在同一进程的优雅退出请求超时后可用。"
            // Do not erase another process's timed-out state when a stale UI
            // row invokes this method with the wrong identity.
            if case .timedOut(let timedOutIdentity) = state,
               timedOutIdentity != process.identity {
                // Keep the actionable timeout visible for its original target.
            } else {
                state = .denied(process.identity, message)
            }
            Task { [weak self] in
                await self?.appendAudit(
                    action: .forceTerminate,
                    outcome: .denied,
                    process: process,
                    detail: message
                )
            }
            return
        }

        // Keep the original snapshot as the force-termination baseline. The
        // latest UI snapshot is only a preflight check; replacing the baseline
        // would allow a parent or executable-path change during the timeout.
        let preflight = policy.validate(expected: expected, current: process)
        guard preflight.allowed else {
            state = .denied(process.identity, preflight.message)
            Task { [weak self] in
                await self?.appendAudit(
                    action: .forceTerminate,
                    outcome: .denied,
                    process: expected,
                    detail: preflight.message
                )
            }
            return
        }

        cancelCurrentTask()
        let token = UUID()
        operationToken = token
        targetProcess = expected
        state = .forceTerminating(process.identity)
        actionTask = Task { [weak self] in
            await self?.performForceTerminate(expected: expected, token: token)
        }
    }

    func cancel(for identity: ProcessIdentity) {
        guard stateIdentity == identity,
              let action = cancellableAction else { return }
        let previousTarget = targetProcess
        let cancellationMessage = cancellationMessage(for: state)
        cancelCurrentTask()
        state = .cancelled(identity, cancellationMessage)
        if let previousTarget {
            Task { [weak self] in
                await self?.appendAudit(
                    action: action,
                    outcome: .cancelled,
                    process: previousTarget,
                    detail: cancellationMessage
                )
            }
        }
    }

    private var stateIdentity: ProcessIdentity? {
        switch state {
        case .requestingGraceful(let identity),
             .waitingForGraceful(let identity, _),
             .timedOut(let identity),
             .forceTerminating(let identity),
             .completed(let identity, _, _):
            return identity
        case .denied(let identity, _), .failed(let identity, _), .cancelled(let identity, _):
            return identity
        case .idle:
            return nil
        }
    }

    private var cancellableAction: ProcessActionKind? {
        switch state {
        case .requestingGraceful, .waitingForGraceful:
            return .gracefulExit
        case .forceTerminating:
            return .forceTerminate
        case .idle, .timedOut, .completed, .denied, .failed, .cancelled:
            return nil
        }
    }

    private func performGracefulExit(
        expected: ProcessSnapshot,
        token: UUID
    ) async {
        guard isCurrent(token) else { return }

        guard let current = await runtime.sample(pid: expected.identity.pid) else {
            if !(await runtime.processExists(pid: expected.identity.pid)) {
                await finish(
                    state: .completed(expected.identity, .gracefulExit, "进程已经退出"),
                    action: .gracefulExit,
                    outcome: .completed,
                    process: expected,
                    detail: "进程在请求前已经退出",
                    token: token
                )
            } else {
                await finishDenied(
                    expected: expected,
                    action: .gracefulExit,
                    reason: .missingSnapshot,
                    token: token
                )
            }
            return
        }

        let validation = policy.validate(expected: expected, current: current)
        guard validation.allowed else {
            await finishDenied(
                expected: expected,
                action: .gracefulExit,
                message: validation.message,
                token: token
            )
            return
        }
        guard isCurrent(token), !Task.isCancelled else { return }

        switch await runtime.sendGraceful(to: current) {
        case .alreadyExited:
            await finish(
                state: .completed(expected.identity, .gracefulExit, "进程已经退出"),
                action: .gracefulExit,
                outcome: .completed,
                process: expected,
                detail: "进程在请求发送前已经退出",
                token: token
            )
        case .failed(let code):
            await finish(
                state: .failed(expected.identity, "优雅退出请求失败（系统错误码 \(code)）。"),
                action: .gracefulExit,
                outcome: .failed,
                process: expected,
                detail: "系统拒绝了优雅退出请求，错误码 \(code)",
                token: token
            )
        case .sent:
            let deadline = runtime.wallClockNow().addingTimeInterval(gracefulTimeout)
            let deadlineNanoseconds = timeoutDeadline(after: gracefulTimeout)
            state = .waitingForGraceful(expected.identity, deadline)
            switch await waitForOriginalExit(
                expected: expected,
                deadlineNanoseconds: deadlineNanoseconds,
                token: token
            ) {
            case .exited:
                await finish(
                    state: .completed(expected.identity, .gracefulExit, "进程已退出"),
                    action: .gracefulExit,
                    outcome: .completed,
                    process: expected,
                    detail: "优雅退出完成",
                    token: token
                )
            case .stillRunning:
                await finish(
                    state: .timedOut(expected.identity),
                    action: .gracefulExit,
                    outcome: .timedOut,
                    process: expected,
                    detail: "优雅退出等待超时；未自动强制结束",
                    token: token
                )
            case .cancelled:
                return
            case .failed(let message):
                await finish(
                    state: .failed(expected.identity, "等待优雅退出状态失败：" + message),
                    action: .gracefulExit,
                    outcome: .failed,
                    process: expected,
                    detail: "等待优雅退出状态失败：" + message,
                    token: token
                )
            }
        }
    }

    private func performForceTerminate(
        expected: ProcessSnapshot,
        token: UUID
    ) async {
        guard isCurrent(token), state == .forceTerminating(expected.identity) else {
            return
        }

        guard let current = await runtime.sample(pid: expected.identity.pid) else {
            if !(await runtime.processExists(pid: expected.identity.pid)) {
                await finish(
                    state: .completed(expected.identity, .forceTerminate, "进程已经退出"),
                    action: .forceTerminate,
                    outcome: .completed,
                    process: expected,
                    detail: "进程在强制结束前已经退出",
                    token: token
                )
            } else {
                await finishDenied(
                    expected: expected,
                    action: .forceTerminate,
                    reason: .missingSnapshot,
                    token: token
                )
            }
            return
        }

        let validation = policy.validate(expected: expected, current: current)
        guard validation.allowed else {
            await finishDenied(
                expected: expected,
                action: .forceTerminate,
                message: validation.message,
                token: token
            )
            return
        }
        guard isCurrent(token), !Task.isCancelled else { return }

        switch await runtime.sendForce(to: current) {
        case .alreadyExited:
            await finish(
                state: .completed(expected.identity, .forceTerminate, "进程已经退出"),
                action: .forceTerminate,
                outcome: .completed,
                process: expected,
                detail: "进程在强制结束请求前已经退出",
                token: token
            )
        case .failed(let code):
            await finish(
                state: .failed(expected.identity, "强制结束请求失败（系统错误码 \(code)）。"),
                action: .forceTerminate,
                outcome: .failed,
                process: expected,
                detail: "系统拒绝了强制结束请求，错误码 \(code)",
                token: token
            )
        case .sent:
            let deadlineNanoseconds = timeoutDeadline(after: forceVerificationTimeout)
            switch await waitForOriginalExit(
                expected: expected,
                deadlineNanoseconds: deadlineNanoseconds,
                token: token
            ) {
            case .exited:
                await finish(
                    state: .completed(expected.identity, .forceTerminate, "进程已结束"),
                    action: .forceTerminate,
                    outcome: .completed,
                    process: expected,
                    detail: "强制结束完成",
                    token: token
                )
            case .stillRunning:
                await finish(
                    state: .failed(expected.identity, "请求已发送，但进程仍然存在。"),
                    action: .forceTerminate,
                    outcome: .failed,
                    process: expected,
                    detail: "强制结束请求已发送，但进程仍存在",
                    token: token
                )
            case .cancelled:
                return
            case .failed(let message):
                await finish(
                    state: .failed(expected.identity, "等待强制结束状态失败：" + message),
                    action: .forceTerminate,
                    outcome: .failed,
                    process: expected,
                    detail: "等待强制结束状态失败：" + message,
                    token: token
                )
            }
        }
    }

    private enum ExitWaitResult {
        case exited
        case stillRunning
        case cancelled
        case failed(String)
    }

    private func waitForOriginalExit(
        expected: ProcessSnapshot,
        deadlineNanoseconds: UInt64,
        token: UUID
    ) async -> ExitWaitResult {
        while runtime.monotonicNanoseconds() < deadlineNanoseconds {
            guard isCurrent(token), !Task.isCancelled else { return .cancelled }
            if !(await originalProcessIsAlive(expected)) { return .exited }
            do {
                try await runtime.sleep(for: pollInterval)
            } catch {
                return Task.isCancelled
                    ? .cancelled
                    : .failed("计时器不可用")
            }
        }
        guard isCurrent(token), !Task.isCancelled else { return .cancelled }
        return await originalProcessIsAlive(expected) ? .stillRunning : .exited
    }

    private func timeoutDeadline(after interval: TimeInterval) -> UInt64 {
        guard interval.isFinite, interval > 0 else {
            return runtime.monotonicNanoseconds()
        }

        let nanoseconds = interval * 1_000_000_000
        guard nanoseconds < Double(UInt64.max) else { return UInt64.max }
        let offset = UInt64(max(nanoseconds.rounded(.up), 1))
        let (deadline, overflow) = runtime.monotonicNanoseconds().addingReportingOverflow(offset)
        return overflow ? UInt64.max : deadline
    }

    /// A different start time means the original process is gone even if the
    /// kernel has already reused its PID for another process.
    private func originalProcessIsAlive(_ expected: ProcessSnapshot) async -> Bool {
        if let current = await runtime.sample(pid: expected.identity.pid) {
            return current.identity == expected.identity
        }
        // A missing proc_pidinfo result is conservative: EPERM/EACCES still
        // counts as present, while ESRCH means the PID no longer exists.
        return await runtime.processExists(pid: expected.identity.pid)
    }

    private func cancellationMessage(for state: ProcessActionState) -> String {
        switch state {
        case .requestingGraceful:
            return "操作已取消；尚未确认是否发送优雅退出请求。"
        case .waitingForGraceful:
            return "等待已取消；优雅退出请求已发送，未发送强制结束。"
        case .forceTerminating:
            return "操作已取消；请重新采样确认进程状态。"
        default:
            return "操作已取消，未发送新的进程信号。"
        }
    }

    private func finishDenied(
        expected: ProcessSnapshot,
        action: ProcessActionKind,
        reason: ProcessActionBlockReason? = nil,
        message: String? = nil,
        token: UUID
    ) async {
        let detail = message ?? reason?.displayMessage ?? "进程操作被拒绝。"
        await finish(
            state: .denied(expected.identity, detail),
            action: action,
            outcome: .denied,
            process: expected,
            detail: detail,
            token: token
        )
    }

    private func finish(
        state newState: ProcessActionState,
        action: ProcessActionKind,
        outcome: ProcessActionOutcome,
        process: ProcessSnapshot,
        detail: String,
        token: UUID
    ) async {
        guard isCurrent(token) else { return }
        // Publish the terminal state before disk I/O so a slow or unavailable
        // audit store cannot leave the UI looking busy after the action ended.
        state = newState
        await appendAudit(
            action: action,
            outcome: outcome,
            process: process,
            detail: detail
        )
    }

    private func appendAudit(
        action: ProcessActionKind,
        outcome: ProcessActionOutcome,
        process: ProcessSnapshot,
        detail: String
    ) async {
        let event = ProcessActionAuditEvent(
            action: action,
            outcome: outcome,
            processLabel: process.applicationName ?? process.name,
            applicationName: process.applicationName,
            detail: detail
        )
        do {
            recentEvents = try await auditStore.append(event)
            auditError = nil
        } catch {
            auditError = error.localizedDescription
        }
    }

    private func loadAuditEvents() async {
        do {
            recentEvents = try await auditStore.load()
            auditError = nil
        } catch {
            auditError = error.localizedDescription
        }
    }

    private func isCurrent(_ token: UUID) -> Bool {
        operationToken == token
    }

    private func cancelCurrentTask() {
        operationToken = UUID()
        actionTask?.cancel()
        actionTask = nil
    }
}
