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
    private let sampler: ProcessSampler
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
        auditStore: ProcessActionAuditStore = ProcessActionAuditStore(),
        gracefulTimeout: TimeInterval = 8,
        forceVerificationTimeout: TimeInterval = 2
    ) {
        self.policy = ProcessActionPolicy(
            currentUserID: currentUserID,
            monitorPID: monitorPID
        )
        self.sampler = sampler
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
            state = .denied(process.identity, message)
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
        cancelCurrentTask()
        state = .cancelled(identity, "操作已取消，未发送新的进程信号。")
        if let previousTarget {
            Task { [weak self] in
                await self?.appendAudit(
                    action: action,
                    outcome: .cancelled,
                    process: previousTarget,
                    detail: "操作已取消"
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

        guard let current = sampler.sample(pid: expected.identity.pid) else {
            if !processExists(expected.identity.pid) {
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

        switch sendGracefulSignal(to: current) {
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
            let deadline = Date().addingTimeInterval(gracefulTimeout)
            state = .waitingForGraceful(expected.identity, deadline)
            switch await waitForOriginalExit(expected: expected, deadline: deadline, token: token) {
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

        guard let current = sampler.sample(pid: expected.identity.pid) else {
            if !processExists(expected.identity.pid) {
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

        switch sendForceSignal(to: current) {
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
            let deadline = Date().addingTimeInterval(forceVerificationTimeout)
            switch await waitForOriginalExit(expected: expected, deadline: deadline, token: token) {
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
            }
        }
    }

    private enum SignalResult {
        case sent
        case alreadyExited
        case failed(Int32)
    }

    private func sendGracefulSignal(to process: ProcessSnapshot) -> SignalResult {
        if let application = guiApplication(for: process) {
            if application.terminate() {
                return .sent
            }
            return processExists(process.identity.pid)
                ? .failed(EIO)
                : .alreadyExited
        }
        return sendDarwinSignal(SIGTERM, to: process.identity.pid)
    }

    private func sendForceSignal(to process: ProcessSnapshot) -> SignalResult {
        if let application = guiApplication(for: process) {
            if application.forceTerminate() {
                return .sent
            }
            return processExists(process.identity.pid)
                ? .failed(EIO)
                : .alreadyExited
        }
        return sendDarwinSignal(SIGKILL, to: process.identity.pid)
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

    private func sendDarwinSignal(_ signal: Int32, to pid: Int32) -> SignalResult {
        guard pid > 0 else { return .failed(EINVAL) }
        guard Darwin.kill(pid_t(pid), signal) == 0 else {
            let code = Int32(Darwin.errno)
            return code == ESRCH ? .alreadyExited : .failed(code)
        }
        return .sent
    }

    private func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid_t(pid), 0) == 0 { return true }
        return Int32(Darwin.errno) != ESRCH
    }

    private enum ExitWaitResult {
        case exited
        case stillRunning
        case cancelled
    }

    private func waitForOriginalExit(
        expected: ProcessSnapshot,
        deadline: Date,
        token: UUID
    ) async -> ExitWaitResult {
        while Date() < deadline {
            guard isCurrent(token), !Task.isCancelled else { return .cancelled }
            if !originalProcessIsAlive(expected) { return .exited }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return .cancelled
            }
        }
        guard isCurrent(token), !Task.isCancelled else { return .cancelled }
        return originalProcessIsAlive(expected) ? .stillRunning : .exited
    }

    /// A different start time means the original process is gone even if the
    /// kernel has already reused its PID for another process.
    private func originalProcessIsAlive(_ expected: ProcessSnapshot) -> Bool {
        if let current = sampler.sample(pid: expected.identity.pid) {
            return current.identity == expected.identity
        }
        // A missing proc_pidinfo result is conservative: EPERM/EACCES still
        // counts as present, while ESRCH means the PID no longer exists.
        return processExists(expected.identity.pid)
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
        await appendAudit(
            action: action,
            outcome: outcome,
            process: process,
            detail: detail
        )
        guard isCurrent(token) else { return }
        state = newState
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
