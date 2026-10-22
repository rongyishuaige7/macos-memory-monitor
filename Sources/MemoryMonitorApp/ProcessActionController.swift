import Combine
@preconcurrency import Darwin
import Foundation
import MemoryMonitorCore

enum ProcessActionState: Equatable {
    case idle
    case requestingGraceful(ProcessIdentity)
    case waitingForGraceful(ProcessIdentity, Date)
    case timedOut(ProcessIdentity)
    case forceTerminating(ProcessIdentity)
    case verifyingForce(ProcessIdentity)
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
    case denied(ProcessActionBlockReason)
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
    private let policy: ProcessActionPolicy

    init(sampler: ProcessSampler = ProcessSampler(), policy: ProcessActionPolicy) {
        self.sampler = sampler
        self.policy = policy
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
        let sampler = sampler
        let policy = policy
        return await Task.detached(priority: .userInitiated) {
            Self.sendSignal(
                SIGTERM,
                to: process,
                sampler: sampler,
                policy: policy,
                allowsUnboundFallback: true
            )
        }.value
    }

    func sendForce(to process: ProcessSnapshot) async -> ProcessActionSignalResult {
        let sampler = sampler
        let policy = policy
        return await Task.detached(priority: .userInitiated) {
            Self.sendSignal(
                SIGKILL,
                to: process,
                sampler: sampler,
                policy: policy,
                allowsUnboundFallback: false
            )
        }.value
    }

    func wallClockNow() -> Date { Date() }

    nonisolated func monotonicNanoseconds() -> UInt64 {
        continuousNanoseconds()
    }

    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    private enum AuditTokenLookup {
        case found(audit_token_t)
        case unavailable
    }

    /// Acquires a PID-version-bearing token before the last policy check. If
    /// the PID is replaced at any point, either that check rejects the new
    /// process or the token-bound signal fails without reaching the reuse.
    nonisolated private static func sendSignal(
        _ signal: Int32,
        to expected: ProcessSnapshot,
        sampler: ProcessSampler,
        policy: ProcessActionPolicy,
        allowsUnboundFallback: Bool
    ) -> ProcessActionSignalResult {
        let pid = expected.identity.pid
        guard pid > 0 else { return .failed(EINVAL) }

        switch auditToken(for: pid) {
        case .found(var auditToken):
            guard let final = sampler.sample(pid: pid) else {
                return missingFinalSnapshotResult(pid: pid)
            }
            let validation = policy.validate(expected: expected, current: final)
            guard validation.allowed else {
                return .denied(validation.reason ?? .identityChanged)
            }
            return sendAuditBoundSignal(signal, token: &auditToken)

        case .unavailable:
            guard allowsUnboundFallback else {
                return processExistsSynchronously(pid)
                    ? .denied(.kernelIdentityUnavailable)
                    : .alreadyExited
            }
            guard let final = sampler.sample(pid: pid) else {
                return missingFinalSnapshotResult(pid: pid)
            }
            let validation = policy.validate(expected: expected, current: final)
            guard validation.allowed else {
                return .denied(validation.reason ?? .identityChanged)
            }
            return sendDarwinSignal(signal, to: pid)
        }
    }

    nonisolated private static func auditToken(for pid: Int32) -> AuditTokenLookup {
        var task = mach_port_name_t(MACH_PORT_NULL)
        let taskResult = task_name_for_pid(mach_task_self_, pid_t(pid), &task)
        guard taskResult == KERN_SUCCESS,
              task != mach_port_name_t(MACH_PORT_NULL) else {
            return .unavailable
        }
        defer { mach_port_deallocate(mach_task_self_, task) }

        var token = audit_token_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
        )
        let infoResult = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    task,
                    task_flavor_t(TASK_AUDIT_TOKEN),
                    $0,
                    &count
                )
            }
        }
        guard infoResult == KERN_SUCCESS,
              count == mach_msg_type_number_t(
                MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size
              ) else {
            return .unavailable
        }
        return .found(token)
    }

    nonisolated private static func sendAuditBoundSignal(
        _ signal: Int32,
        token: inout audit_token_t
    ) -> ProcessActionSignalResult {
        let result = proc_signal_with_audittoken(&token, signal)
        guard result != 0 else { return .sent }
        let code = Int32(result == -1 ? Darwin.errno : result)
        if code == ESRCH { return .alreadyExited }
        if code == EINVAL { return .denied(.kernelIdentityUnavailable) }
        return .failed(code)
    }

    nonisolated private static func sendDarwinSignal(
        _ signal: Int32,
        to pid: Int32
    ) -> ProcessActionSignalResult {
        guard Darwin.kill(pid_t(pid), signal) == 0 else {
            let code = Int32(Darwin.errno)
            return code == ESRCH ? .alreadyExited : .failed(code)
        }
        return .sent
    }

    nonisolated private static func missingFinalSnapshotResult(
        pid: Int32
    ) -> ProcessActionSignalResult {
        processExistsSynchronously(pid)
            ? .denied(.kernelIdentityUnavailable)
            : .alreadyExited
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
    /// The timeout is a product-level safety valve as well as a UI value. A
    /// caller supplying `Double.greatestFiniteMagnitude` must not make the
    /// controller wait effectively forever or overflow when formatting the
    /// confirmation text.
    private static let maximumGracefulTimeout: TimeInterval = 24 * 60 * 60
    private static let maximumForceVerificationTimeout: TimeInterval = 60 * 60

    @Published private(set) var state: ProcessActionState = .idle
    @Published private(set) var recentEvents: [ProcessActionAuditEvent] = []
    @Published private(set) var auditError: String?
    let operationGate = MonitorOperationGate()

    private let policy: ProcessActionPolicy
    private let runtime: any ProcessActionRuntime
    private let auditStore: ProcessActionAuditStore
    private let gracefulTimeout: TimeInterval
    private let forceVerificationTimeout: TimeInterval
    private let pollInterval: Duration = .milliseconds(250)
    private let timeoutReconciliationInterval: Duration = .seconds(1)

    private var targetProcess: ProcessSnapshot?
    /// Stable identifier shared by the intent, signal-sent, and terminal
    /// records for the currently tracked user operation.
    private var activeOperationID: String?
    private var actionTask: Task<Void, Never>?
    private var timeoutReconciliationTask: Task<Void, Never>?
    private var timeoutReconciliationToken: UUID?
    private var initialAuditLoadTask: Task<Void, Never>?
    private var backgroundAuditTasks: [UUID: Task<Void, Never>] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var shutdownCompleted = false
    private var isShuttingDown = false
    private var operationToken = UUID()
    /// Every audit request gets a publication generation. A slower append or
    /// initial load must never put an older result back over a newer list.
    private var auditPublicationGeneration: UInt64 = 0
    /// Events are created once and retained with their original IDs when a
    /// write fails. Replaying the same event is idempotent in the audit store.
    private var pendingAuditEvents: [String: ProcessActionAuditEvent] = [:]

    init(
        currentUserID: UInt32 = UInt32(getuid()),
        monitorPID: Int32 = Int32(getpid()),
        sampler: ProcessSampler = ProcessSampler(),
        runtime: (any ProcessActionRuntime)? = nil,
        auditStore: ProcessActionAuditStore = ProcessActionAuditStore(),
        gracefulTimeout: TimeInterval = 8,
        forceVerificationTimeout: TimeInterval = 2
    ) {
        let policy = ProcessActionPolicy(
            currentUserID: currentUserID,
            monitorPID: monitorPID
        )
        self.policy = policy
        self.runtime = runtime ?? LiveProcessActionRuntime(
            sampler: sampler,
            policy: policy
        )
        self.auditStore = auditStore
        self.gracefulTimeout = min(
            max(gracefulTimeout.isFinite ? gracefulTimeout : 8, 1),
            Self.maximumGracefulTimeout
        )
        self.forceVerificationTimeout = max(
            min(
                forceVerificationTimeout.isFinite ? forceVerificationTimeout : 2,
                Self.maximumForceVerificationTimeout
            ),
            0.5
        )

        initialAuditLoadTask = Task { [weak self] in
            await self?.loadAuditEvents()
        }
    }

    deinit {
        actionTask?.cancel()
        timeoutReconciliationTask?.cancel()
        initialAuditLoadTask?.cancel()
        shutdownTask?.cancel()
        for task in backgroundAuditTasks.values {
            task.cancel()
        }
    }

    var isBusy: Bool {
        switch state {
        case .requestingGraceful, .waitingForGraceful, .timedOut,
             .forceTerminating, .verifyingForce:
            return true
        case .idle, .completed, .denied, .failed, .cancelled:
            return false
        }
    }

    var gracefulTimeoutForDisplay: TimeInterval { gracefulTimeout }

    private var gracefulTimeoutDisplaySeconds: Int {
        // `maximumGracefulTimeout` keeps this conversion bounded, but retain a
        // defensive clamp in case the policy changes independently later.
        let bounded = min(max(gracefulTimeout.rounded(.up), 1), Double(Int.max))
        return Int(bounded)
    }

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
                message: "正在准备退出…",
                tone: .neutral
            )
        case .waitingForGraceful(let target, _ ) where target == identity:
            return ProcessActionStatus(
                message: "退出请求已发送，等待关闭（最多 \(gracefulTimeoutDisplaySeconds) 秒）…",
                tone: .neutral
            )
        case .timedOut(let target) where target == identity:
            return ProcessActionStatus(
                message: "进程没有响应。确认工作已保存后，可选择强制结束。",
                tone: .warning
            )
        case .forceTerminating(let target) where target == identity:
            return ProcessActionStatus(
                message: "正在强制结束…",
                tone: .warning
            )
        case .verifyingForce(let target) where target == identity:
            return ProcessActionStatus(
                message: "强制结束请求已发送，等待关闭…",
                tone: .warning
            )
        case .completed(let target, let action, let message) where target == identity:
            return ProcessActionStatus(
                message: "\(action == .gracefulExit ? "退出进程" : "强制结束")：\(message)",
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
        guard !isShuttingDown, !isBusy else { return }
        // Hold the shared gate for the whole manual operation. Checking
        // `owner == nil` without acquiring left a window where Smart Cleanup
        // could start after this check but before the action became busy.
        guard operationGate.acquire(.manualAction) else {
            state = .denied(process.identity, "请等待智能清理或内存测试结束。")
            return
        }
        cancelCurrentTask()

        let validation = eligibility(for: process)
        guard validation.allowed else {
            targetProcess = process
            state = .denied(process.identity, validation.message)
            operationGate.release(.manualAction)
            launchAudit(
                action: .gracefulExit,
                outcome: .denied,
                process: process,
                detail: validation.message
            )
            return
        }

        targetProcess = process
        let operationID = UUID().uuidString
        activeOperationID = operationID
        let token = UUID()
        operationToken = token
        state = .requestingGraceful(process.identity)
        actionTask = Task { [weak self] in
            await self?.performGracefulExit(
                expected: process,
                operationID: operationID,
                token: token
            )
        }
    }

    func requestForceTerminate(for process: ProcessSnapshot) {
        guard !isShuttingDown else { return }
        // Force termination is a continuation of the same manual operation.
        // The graceful request acquired the gate; it must still be ours.
        guard operationGate.owner == .manualAction else { return }
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
                operationGate.release(.manualAction)
            }
            launchAudit(
                action: .forceTerminate,
                outcome: .denied,
                process: process,
                detail: message
            )
            return
        }

        // Keep the original snapshot as the force-termination baseline. The
        // latest UI snapshot is only a preflight check; replacing the baseline
        // would allow a parent or executable-path change during the timeout.
        let preflight = policy.validate(expected: expected, current: process)
        guard preflight.allowed else {
            state = .denied(process.identity, preflight.message)
            operationGate.release(.manualAction)
            launchAudit(
                action: .forceTerminate,
                outcome: .denied,
                process: expected,
                detail: preflight.message
            )
            return
        }

        cancelCurrentTask()
        let token = UUID()
        let operationID = UUID().uuidString
        operationToken = token
        activeOperationID = operationID
        targetProcess = expected
        state = .forceTerminating(process.identity)
        actionTask = Task { [weak self] in
            await self?.performForceTerminate(
                expected: expected,
                operationID: operationID,
                token: token
            )
        }
    }

    func cancel(for identity: ProcessIdentity) {
        guard !isShuttingDown else { return }
        guard stateIdentity == identity,
              let action = cancellableAction else { return }
        let previousTarget = targetProcess
        let previousOperationID = activeOperationID
        let cancellationMessage = cancellationMessage(for: state)
        cancelCurrentTask()
        state = .cancelled(identity, cancellationMessage)
        operationGate.release(.manualAction)
        if let previousTarget {
            launchAudit(
                action: action,
                outcome: .cancelled,
                process: previousTarget,
                detail: cancellationMessage,
                operationID: previousOperationID
            )
        }
    }

    private var stateIdentity: ProcessIdentity? {
        switch state {
        case .requestingGraceful(let identity),
             .waitingForGraceful(let identity, _),
             .timedOut(let identity),
             .forceTerminating(let identity),
             .verifyingForce(let identity),
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
        case .requestingGraceful, .waitingForGraceful, .timedOut:
            return .gracefulExit
        case .forceTerminating, .verifyingForce:
            return .forceTerminate
        case .idle, .completed, .denied, .failed, .cancelled:
            return nil
        }
    }

    private func performGracefulExit(
        expected: ProcessSnapshot,
        operationID: String,
        token: UUID
    ) async {
        guard isCurrent(token) else { return }

        await retryPendingAudits()
        guard isCurrent(token), !Task.isCancelled else { return }

        guard await appendAuditIntent(
            action: .gracefulExit,
            process: expected,
            operationID: operationID
        ) else {
            guard isCurrent(token), !Task.isCancelled else { return }
            state = .failed(
                expected.identity,
                "无法记录用户确认意图，未发送优雅退出请求。"
            )
            operationGate.release(.manualAction)
            return
        }

        guard let current = await runtime.sample(pid: expected.identity.pid) else {
            if !(await runtime.processExists(pid: expected.identity.pid)) {
                await finish(
                    state: .completed(expected.identity, .gracefulExit, "进程已经退出"),
                    action: .gracefulExit,
                    outcome: .completed,
                    process: expected,
                    detail: "进程在请求前已经退出",
                    operationID: operationID,
                    token: token
                )
            } else {
                await finishDenied(
                    expected: expected,
                    action: .gracefulExit,
                    reason: .missingSnapshot,
                    operationID: operationID,
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
                operationID: operationID,
                token: token
            )
            return
        }
        guard isCurrent(token), !Task.isCancelled else { return }

        let gracefulResult = await runtime.sendGraceful(to: current)
        guard isCurrent(token), !Task.isCancelled else { return }

        switch gracefulResult {
        case .alreadyExited:
            await finish(
                state: .completed(expected.identity, .gracefulExit, "进程已经退出"),
                action: .gracefulExit,
                outcome: .completed,
                process: expected,
                detail: "进程在请求发送前已经退出",
                operationID: operationID,
                token: token
            )
        case .denied(let reason):
            await finishDenied(
                expected: expected,
                action: .gracefulExit,
                reason: reason,
                operationID: operationID,
                token: token
            )
        case .failed(let code):
            await finish(
                state: .failed(expected.identity, "优雅退出请求失败（系统错误码 \(code)）。"),
                action: .gracefulExit,
                outcome: .failed,
                process: expected,
                detail: "系统拒绝了优雅退出请求，错误码 \(code)",
                operationID: operationID,
                token: token
            )
        case .sent:
            let deadline = runtime.wallClockNow().addingTimeInterval(gracefulTimeout)
            let deadlineNanoseconds = timeoutDeadline(after: gracefulTimeout)
            state = .waitingForGraceful(expected.identity, deadline)
            _ = await appendAudit(
                action: .gracefulExit,
                outcome: .completed,
                process: expected,
                detail: "已发送优雅退出请求，正在等待进程结束。",
                operationID: operationID,
                phase: .signalSent
            )
            guard isCurrent(token), !Task.isCancelled else { return }
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
                    operationID: operationID,
                    token: token
                )
            case .stillRunning:
                await finish(
                    state: .timedOut(expected.identity),
                    action: .gracefulExit,
                    outcome: .timedOut,
                    process: expected,
                    detail: "优雅退出等待超时；未自动强制结束",
                    operationID: operationID,
                    token: token
                )
                // The audit append above is asynchronous. A second
                // confirmation may start while it is suspended, so only
                // launch reconciliation if this operation is still current.
                if isCurrent(token), state == .timedOut(expected.identity) {
                    startTimeoutReconciliation(
                        expected: expected,
                        operationID: operationID,
                        token: token
                    )
                }
            case .cancelled:
                return
            case .failed(let message):
                await finish(
                    state: .failed(expected.identity, "等待优雅退出状态失败：" + message),
                    action: .gracefulExit,
                    outcome: .failed,
                    process: expected,
                    detail: "等待优雅退出状态失败：" + message,
                    operationID: operationID,
                    token: token
                )
            }
        }
    }

    private func performForceTerminate(
        expected: ProcessSnapshot,
        operationID: String,
        token: UUID
    ) async {
        guard isCurrent(token), state == .forceTerminating(expected.identity) else {
            return
        }

        await retryPendingAudits()
        guard isCurrent(token), !Task.isCancelled else { return }

        guard await appendAuditIntent(
            action: .forceTerminate,
            process: expected,
            operationID: operationID
        ) else {
            guard isCurrent(token), !Task.isCancelled else { return }
            state = .failed(
                expected.identity,
                "无法记录用户确认意图，未发送强制结束请求。"
            )
            operationGate.release(.manualAction)
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
                    operationID: operationID,
                    token: token
                )
            } else {
                await finishDenied(
                    expected: expected,
                    action: .forceTerminate,
                    reason: .missingSnapshot,
                    operationID: operationID,
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
                operationID: operationID,
                token: token
            )
            return
        }
        guard isCurrent(token), !Task.isCancelled else { return }

        let forceResult = await runtime.sendForce(to: current)
        guard isCurrent(token), !Task.isCancelled else { return }

        switch forceResult {
        case .alreadyExited:
            await finish(
                state: .completed(expected.identity, .forceTerminate, "进程已经退出"),
                action: .forceTerminate,
                outcome: .completed,
                process: expected,
                detail: "进程在强制结束请求前已经退出",
                operationID: operationID,
                token: token
            )
        case .denied(let reason):
            await finishDenied(
                expected: expected,
                action: .forceTerminate,
                reason: reason,
                operationID: operationID,
                token: token
            )
        case .failed(let code):
            await finish(
                state: .failed(expected.identity, "强制结束请求失败（系统错误码 \(code)）。"),
                action: .forceTerminate,
                outcome: .failed,
                process: expected,
                detail: "系统拒绝了强制结束请求，错误码 \(code)",
                operationID: operationID,
                token: token
            )
        case .sent:
            state = .verifyingForce(expected.identity)
            _ = await appendAudit(
                action: .forceTerminate,
                outcome: .completed,
                process: expected,
                detail: "已发送强制结束请求，正在确认进程是否结束。",
                operationID: operationID,
                phase: .signalSent
            )
            guard isCurrent(token), !Task.isCancelled else { return }
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
                    operationID: operationID,
                    token: token
                )
            case .stillRunning:
                await finish(
                    state: .failed(expected.identity, "请求已发送，但进程仍然存在。"),
                    action: .forceTerminate,
                    outcome: .failed,
                    process: expected,
                    detail: "强制结束请求已发送，但进程仍存在",
                    operationID: operationID,
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
                    operationID: operationID,
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
        case .timedOut:
            return "已停止跟踪；优雅退出请求已发送，未发送强制结束。"
        case .forceTerminating:
            return "操作已取消；尚未确认是否发送强制结束请求。"
        case .verifyingForce:
            return "强制结束请求已发送；已停止等待结果，请重新采样确认进程状态。"
        default:
            return "操作已取消，未发送新的进程信号。"
        }
    }

    private func finishDenied(
        expected: ProcessSnapshot,
        action: ProcessActionKind,
        reason: ProcessActionBlockReason? = nil,
        message: String? = nil,
        operationID: String,
        token: UUID
    ) async {
        let detail = message ?? reason?.displayMessage ?? "进程操作被拒绝。"
        await finish(
            state: .denied(expected.identity, detail),
            action: action,
            outcome: .denied,
            process: expected,
            detail: detail,
            operationID: operationID,
            token: token
        )
    }

    private func finish(
        state newState: ProcessActionState,
        action: ProcessActionKind,
        outcome: ProcessActionOutcome,
        process: ProcessSnapshot,
        detail: String,
        operationID: String,
        token: UUID
    ) async {
        guard isCurrent(token) else { return }
        // Publish the terminal state before disk I/O so a slow or unavailable
        // audit store cannot leave the UI looking busy after the action ended.
        state = newState
        // A timeout is actionable: the user may still confirm force
        // termination for this same process. Keep the gate until that second
        // decision, cancellation, shutdown, or background reconciliation.
        if case .timedOut = newState {
            // Keep the manual gate held.
        } else {
            operationGate.release(.manualAction)
        }
        _ = await appendAudit(
            action: action,
            outcome: outcome,
            process: process,
            detail: detail,
            operationID: operationID
        )
    }

    func shutdown() async {
        if shutdownCompleted { return }
        if let shutdownTask {
            await shutdownTask.value
            return
        }

        isShuttingDown = true
        let interruptedAction = cancellableAction
        let interruptedProcess = targetProcess
        let interruptedOperationID = activeOperationID
        let interruptedMessage = cancellationMessage(for: state)
        if let identity = stateIdentity, interruptedAction != nil {
            state = .cancelled(identity, interruptedMessage)
        }
        cancelCurrentTask()
        operationGate.release(.manualAction)

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if let interruptedAction, let interruptedProcess {
                _ = await self.appendAudit(
                    action: interruptedAction,
                    outcome: .cancelled,
                    process: interruptedProcess,
                    detail: interruptedMessage,
                    operationID: interruptedOperationID
                )
            }
            if let initialAuditLoadTask = self.initialAuditLoadTask {
                await initialAuditLoadTask.value
                self.initialAuditLoadTask = nil
            }
            await self.drainBackgroundAuditTasks()
            await self.retryPendingAudits()

            do {
                let now = self.runtime.wallClockNow()
                try await self.auditStore.flush(now: now)
                self.recentEvents = try await self.auditStore.load(now: now)
                if self.pendingAuditEvents.isEmpty {
                    self.auditError = nil
                }
            } catch {
                self.auditError = error.localizedDescription
            }
        }
        shutdownTask = task
        await task.value
        shutdownCompleted = true
        shutdownTask = nil
    }

    private func launchAudit(
        action: ProcessActionKind,
        outcome: ProcessActionOutcome,
        process: ProcessSnapshot,
        detail: String,
        operationID: String? = nil
    ) {
        guard !isShuttingDown else { return }
        let id = UUID()
        backgroundAuditTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.retryPendingAudits()
            _ = await self.appendAudit(
                action: action,
                outcome: outcome,
                process: process,
                detail: detail,
                operationID: operationID
            )
            self.backgroundAuditTasks[id] = nil
        }
    }

    private func drainBackgroundAuditTasks() async {
        while !backgroundAuditTasks.isEmpty {
            let tasks = Array(backgroundAuditTasks.values)
            for task in tasks {
                await task.value
            }
        }
    }

    private func appendAudit(
        action: ProcessActionKind,
        outcome: ProcessActionOutcome,
        process: ProcessSnapshot,
        detail: String,
        operationID: String? = nil,
        phase: ProcessActionAuditPhase = .terminal
    ) async -> Bool {
        let event = ProcessActionAuditEvent(
            operationID: operationID,
            action: action,
            phase: phase,
            outcome: outcome,
            processLabel: process.applicationName ?? process.name,
            applicationName: process.applicationName,
            detail: detail
        )
        let result = await appendAuditEvent(event, queueOnFailure: true)
        return result.appended
    }

    private func appendAuditEvent(
        _ event: ProcessActionAuditEvent,
        queueOnFailure: Bool
    ) async -> (appended: Bool, published: Bool) {
        auditPublicationGeneration &+= 1
        let generation = auditPublicationGeneration
        do {
            // A durable append is the execution gate. A later UI reload may
            // fail without invalidating the fact that the intent was stored.
            _ = try await auditStore.append(event)
        } catch {
            if queueOnFailure {
                pendingAuditEvents[event.id] = event
            }
            guard generation == auditPublicationGeneration else {
                return (false, false)
            }
            auditError = error.localizedDescription
            return (false, false)
        }

        do {
            // Reload after the append so this publication includes any older
            // append that completed while this request was suspended. The
            // generation check below prevents a stale reload from replacing a
            // newer publication.
            let latestEvents = try await auditStore.load()
            guard generation == auditPublicationGeneration else {
                return (true, false)
            }
            recentEvents = latestEvents
            if pendingAuditEvents.isEmpty {
                auditError = nil
            }
        } catch {
            guard generation == auditPublicationGeneration else {
                return (true, false)
            }
            auditError = error.localizedDescription
            return (true, false)
        }
        return (true, true)
    }

    /// Retries failed audit writes without manufacturing a new event ID. The
    /// store's idempotent append handles a write that actually succeeded just
    /// before its caller observed an error.
    private func retryPendingAudits() async {
        guard !pendingAuditEvents.isEmpty else { return }
        let events = pendingAuditEvents.values.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
        for event in events {
            guard pendingAuditEvents[event.id] != nil else { continue }
            let result = await appendAuditEvent(event, queueOnFailure: false)
            if result.appended {
                pendingAuditEvents.removeValue(forKey: event.id)
                if pendingAuditEvents.isEmpty, result.published {
                    auditError = nil
                }
            }
        }
    }

    /// The intent is a durable prerequisite for any sampling or signal
    /// delivery. A successful append is enough to proceed even if the
    /// best-effort reload used for UI publication fails.
    private func appendAuditIntent(
        action: ProcessActionKind,
        process: ProcessSnapshot,
        operationID: String
    ) async -> Bool {
        await appendAudit(
            action: action,
            outcome: .completed,
            process: process,
            detail: "用户已确认操作；尚未采样或发送新的进程信号。",
            operationID: operationID,
            phase: .intent
        )
    }

    /// Explicit recovery path for the settings/audit UI. A transient load
    /// failure must not leave the audit panel stuck until the next process
    /// action or application restart.
    func refreshAudit() async {
        // The initial load starts during init. Await it before starting an
        // explicit refresh; otherwise the later initial task can increment the
        // publication generation and discard the refresh result, leaving the
        // caller with an empty/stale list even though the store is readable.
        if let initialAuditLoadTask {
            await initialAuditLoadTask.value
        }
        await loadAuditEvents()
    }

    private func loadAuditEvents() async {
        auditPublicationGeneration &+= 1
        let generation = auditPublicationGeneration
        do {
            let loadedEvents = try await auditStore.load()
            guard generation == auditPublicationGeneration else { return }
            recentEvents = loadedEvents
            if pendingAuditEvents.isEmpty {
                auditError = nil
            }
        } catch {
            guard generation == auditPublicationGeneration else { return }
            auditError = error.localizedDescription
        }
        await retryPendingAudits()
    }

    private func isCurrent(_ token: UUID) -> Bool {
        operationToken == token
    }

    private func cancelCurrentTask() {
        operationToken = UUID()
        actionTask?.cancel()
        actionTask = nil
        timeoutReconciliationTask?.cancel()
        timeoutReconciliationTask = nil
        timeoutReconciliationToken = nil
    }

    /// A process can exit in the small interval between the final timeout
    /// check and the user's second confirmation. Keep the timeout actionable
    /// while the original identity exists, but reconcile it in the background
    /// so a naturally exiting target does not leave the controller busy
    /// forever. The closure avoids retaining `self` while sleeping.
    private func startTimeoutReconciliation(
        expected: ProcessSnapshot,
        operationID: String,
        token: UUID
    ) {
        timeoutReconciliationTask?.cancel()
        timeoutReconciliationToken = token
        let runtime = self.runtime
        let interval = timeoutReconciliationInterval
        timeoutReconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await runtime.sleep(for: interval)
                } catch {
                    self?.clearTimeoutReconciliation(for: token)
                    return
                }
                guard let self,
                      self.isCurrent(token),
                      self.state == .timedOut(expected.identity) else {
                    self?.clearTimeoutReconciliation(for: token)
                    return
                }
                if !(await self.originalProcessIsAlive(expected)) {
                    await self.finish(
                        state: .completed(expected.identity, .gracefulExit, "进程已退出"),
                        action: .gracefulExit,
                        outcome: .completed,
                        process: expected,
                        detail: "优雅退出超时后确认原进程已退出",
                        operationID: operationID,
                        token: token
                    )
                    self.clearTimeoutReconciliation(for: token)
                    return
                }
            }
            self?.clearTimeoutReconciliation(for: token)
        }
    }

    /// Clears only the reconciliation task created for `token`. An older task
    /// can resume after a newer operation has installed its own task handle;
    /// comparing the token prevents that stale task from erasing the handle.
    private func clearTimeoutReconciliation(for token: UUID) {
        guard timeoutReconciliationToken == token else { return }
        timeoutReconciliationTask = nil
        timeoutReconciliationToken = nil
    }
}
