import Darwin
import Foundation
import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

@MainActor
final class ProcessActionControllerTests: XCTestCase {
    func testGracefulExitCompletesWithInjectedRuntime() async throws {
        let process = makeProcess(pid: 4101, name: "worker")
        let runtime = FakeProcessActionRuntime()
        runtime.setSamples([process, nil], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let store = ProcessActionAuditStore(fileURL: paths.file)
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: store,
            gracefulTimeout: 1,
            forceVerificationTimeout: 0.5
        )

        controller.requestGracefulExit(for: process)
        await waitUntil { !controller.isBusy }

        guard case .completed(let identity, let action, _) = controller.state else {
            return XCTFail("expected graceful completion, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertEqual(action, .gracefulExit)
        XCTAssertEqual(runtime.sentActions, [.gracefulExit])

        await waitUntil {
            controller.recentEvents.contains {
                $0.action == .gracefulExit && $0.outcome == .completed
            }
        }
        XCTAssertNil(controller.auditError)

        let events = try await store.load(now: runtime.wallClockNow())
        let operationIDs = Set(events.map(\.operationID))
        XCTAssertEqual(operationIDs.count, 1)
        XCTAssertEqual(events.filter { $0.phase == .intent }.count, 1)
        XCTAssertEqual(events.filter { $0.phase == .signalSent }.count, 1)
        XCTAssertEqual(events.filter { $0.phase == .terminal }.count, 1)
        XCTAssertEqual(events.first(where: { $0.phase == .intent })?.statusDisplayName, "已确认")
        XCTAssertEqual(events.first(where: { $0.phase == .signalSent })?.statusDisplayName, "已发送")
    }

    func testGracefulTimeoutEnablesForceOnlyForOriginalIdentity() async throws {
        let process = makeProcess(pid: 4102, name: "worker")
        let replacement = makeProcess(
            pid: process.identity.pid,
            name: "replacement",
            startTimeSeconds: process.identity.startTimeSeconds + 1
        )
        let runtime = FakeProcessActionRuntime()
        runtime.advancePerSleep = 0.25
        runtime.setSamples([process], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1,
            forceVerificationTimeout: 0.5
        )

        controller.requestGracefulExit(for: process)
        await waitUntil {
            if case .timedOut = controller.state { return true }
            return false
        }
        XCTAssertTrue(controller.isBusy)
        XCTAssertTrue(controller.isBusy(for: process.identity))
        XCTAssertTrue(controller.canForceTerminate(for: process.identity))

        // A stale row for a PID-reused process must not erase the original
        // timeout or make the replacement eligible for force termination.
        controller.requestForceTerminate(for: replacement)
        controller.requestGracefulExit(for: replacement)
        XCTAssertEqual(controller.state, .timedOut(process.identity))
        XCTAssertTrue(controller.canForceTerminate(for: process.identity))
        XCTAssertFalse(runtime.sentActions.contains(.forceTerminate))

        runtime.setSamples([process, nil], for: process.identity.pid)
        controller.requestForceTerminate(for: process)
        await waitUntil { !controller.isBusy }

        guard case .completed(let identity, let action, _) = controller.state else {
            return XCTFail("expected force completion, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertEqual(action, .forceTerminate)
        XCTAssertEqual(runtime.sentActions, [.gracefulExit, .forceTerminate])
    }

    func testIdentityChangeBeforeGracefulSignalIsDenied() async throws {
        let process = makeProcess(pid: 4103, name: "worker")
        let changed = makeProcess(
            pid: process.identity.pid,
            name: "worker",
            startTimeSeconds: process.identity.startTimeSeconds + 1
        )
        let runtime = FakeProcessActionRuntime()
        runtime.setSamples([changed], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file)
        )

        controller.requestGracefulExit(for: process)
        await waitUntil { !controller.isBusy }

        guard case .denied(let identity, let message) = controller.state else {
            return XCTFail("expected identity denial, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertTrue(message.contains("启动身份"))
        XCTAssertTrue(runtime.sentActions.isEmpty)
    }

    func testIdentityChangeAtGracefulSignalBoundaryIsDenied() async throws {
        let process = makeProcess(pid: 4120, name: "boundary-worker")
        let runtime = FakeProcessActionRuntime()
        runtime.setSamples([process], for: process.identity.pid)
        runtime.gracefulResult = .denied(.identityChanged)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file)
        )

        controller.requestGracefulExit(for: process)
        await waitUntil { !controller.isBusy }

        guard case .denied(let identity, let message) = controller.state else {
            return XCTFail("expected boundary identity denial, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertTrue(message.contains("启动身份"))
        await waitUntil {
            controller.recentEvents.contains {
                $0.action == .gracefulExit && $0.outcome == .denied
            }
        }
    }

    func testForceVerificationRejectsChangedParentAndPath() async throws {
        let process = makeProcess(pid: 4107, name: "worker")
        let changed = ProcessSnapshot(
            identity: process.identity,
            parentPID: process.parentPID + 1,
            userID: process.userID,
            isSystem: false,
            name: process.name,
            executablePath: "/Users/test/bin/other-worker",
            residentBytes: process.residentBytes,
            physicalFootprintBytes: process.physicalFootprintBytes,
            virtualBytes: process.virtualBytes,
            userTimeNanos: process.userTimeNanos,
            systemTimeNanos: process.systemTimeNanos,
            threadCount: process.threadCount
        )
        let runtime = FakeProcessActionRuntime()
        runtime.advancePerSleep = 0.25
        runtime.setSamples([process], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: process)
        await waitUntil {
            if case .timedOut = controller.state { return true }
            return false
        }
        runtime.setSamples([changed], for: process.identity.pid)
        controller.requestForceTerminate(for: process)
        await waitUntil { !controller.isBusy }

        guard case .denied(_, let message) = controller.state else {
            return XCTFail("expected force preflight denial, got \(controller.state)")
        }
        XCTAssertTrue(message.contains("父进程") || message.contains("可执行路径"))
        XCTAssertFalse(runtime.sentActions.contains(.forceTerminate))
    }

    func testSignalFailureIsTerminalAndAudited() async throws {
        let process = makeProcess(pid: 4104, name: "worker")
        let runtime = FakeProcessActionRuntime()
        runtime.setSamples([process], for: process.identity.pid)
        runtime.gracefulResult = .failed(EPERM)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file)
        )

        controller.requestGracefulExit(for: process)
        await waitUntil { !controller.isBusy }

        guard case .failed(let identity, let message) = controller.state else {
            return XCTFail("expected signal failure, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertTrue(message.contains("错误码"))
        XCTAssertEqual(runtime.sentActions, [.gracefulExit])
        await waitUntil {
            controller.recentEvents.contains { $0.outcome == .failed }
        }
    }

    func testForceSignalFailureIsTerminal() async throws {
        let process = makeProcess(pid: 4108, name: "worker")
        let runtime = FakeProcessActionRuntime()
        runtime.advancePerSleep = 0.25
        runtime.setSamples([process], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: process)
        await waitUntil {
            if case .timedOut = controller.state { return true }
            return false
        }
        runtime.setSamples([process], for: process.identity.pid)
        runtime.forceResult = .failed(EPERM)
        controller.requestForceTerminate(for: process)
        await waitUntil { !controller.isBusy }

        guard case .failed(let identity, let message) = controller.state else {
            return XCTFail("expected force failure, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertTrue(message.contains("错误码"))
        XCTAssertEqual(runtime.sentActions, [.gracefulExit, .forceTerminate])
    }

    func testForceTerminationRejectsUnavailableKernelIdentityBinding() async throws {
        let process = makeProcess(pid: 4121, name: "force-boundary-worker")
        let runtime = FakeProcessActionRuntime()
        runtime.advancePerSleep = 0.25
        runtime.setSamples([process], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: process)
        await waitUntil {
            if case .timedOut = controller.state { return true }
            return false
        }

        runtime.forceResult = .denied(.kernelIdentityUnavailable)
        controller.requestForceTerminate(for: process)
        await waitUntil { !controller.isBusy }

        guard case .denied(let identity, let message) = controller.state else {
            return XCTFail("expected kernel binding denial, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertTrue(message.contains("内核绑定"))
        XCTAssertEqual(runtime.sentActions, [.gracefulExit, .forceTerminate])
    }

    func testCancelledGracefulSendDoesNotOverwriteFollowupRequest() async throws {
        let first = makeProcess(pid: 4111, name: "worker-a")
        let second = makeProcess(pid: 4112, name: "worker-b")
        let runtime = FakeProcessActionRuntime()
        runtime.holdGracefulSend(for: first.identity.pid)
        runtime.setSamples([first], for: first.identity.pid)
        runtime.setSamples([second, nil], for: second.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: first.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1,
            forceVerificationTimeout: 0.5
        )

        controller.requestGracefulExit(for: first)
        await waitUntil {
            runtime.isGracefulSendWaiting(for: first.identity.pid)
        }
        XCTAssertTrue(controller.canCancel(for: first.identity))

        controller.cancel(for: first.identity)
        guard case .cancelled(let identity, let message) = controller.state else {
            return XCTFail("expected cancellation, got \(controller.state)")
        }
        XCTAssertEqual(identity, first.identity)
        XCTAssertTrue(message.contains("尚未确认是否发送优雅退出请求"))

        controller.requestGracefulExit(for: second)
        await waitUntil {
            if case .completed(let identity, let action, _) = controller.state,
               identity == second.identity,
               action == .gracefulExit {
                return true
            }
            return false
        }

        runtime.releaseGracefulSend(for: first.identity.pid)
        await waitUntil {
            runtime.didFinishGracefulSend(for: first.identity.pid)
        }

        guard case .completed(let identity, let action, _) = controller.state else {
            return XCTFail("expected follow-up completion, got \(controller.state)")
        }
        XCTAssertEqual(identity, second.identity)
        XCTAssertEqual(action, .gracefulExit)
        XCTAssertEqual(runtime.sentActions, [.gracefulExit, .gracefulExit])
    }

    func testTimeoutUsesMonotonicClockWhenWallClockMovesBackwards() async throws {
        let process = makeProcess(pid: 4109, name: "worker")
        let runtime = FakeProcessActionRuntime()
        runtime.advancePerSleep = 0.25
        runtime.wallClockAdvancePerSleep = -3_600
        runtime.setSamples([process], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: process)
        await waitUntil {
            if case .timedOut = controller.state { return true }
            return false
        }
        XCTAssertEqual(runtime.sentActions, [.gracefulExit])
    }

    func testUnexpectedTimerFailureDoesNotLeaveControllerBusy() async throws {
        let process = makeProcess(pid: 4110, name: "worker")
        let runtime = FakeProcessActionRuntime()
        runtime.setSamples([process], for: process.identity.pid)
        runtime.failSleep = true
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: process)
        await waitUntil { !controller.isBusy }

        guard case .failed(let identity, let message) = controller.state else {
            return XCTFail("expected timer failure, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertTrue(message.contains("等待优雅退出状态失败"))
        await waitUntil {
            controller.recentEvents.contains { $0.outcome == .failed }
        }
    }

    func testCancellingGracefulWaitStopsTaskWithoutForceSignal() async throws {
        let process = makeProcess(pid: 4105, name: "worker")
        let runtime = FakeProcessActionRuntime()
        runtime.advancePerSleep = 0
        runtime.setSamples([process], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: process)
        await waitUntil {
            if case .waitingForGraceful = controller.state { return true }
            return false
        }
        XCTAssertTrue(controller.canCancel(for: process.identity))
        controller.cancel(for: process.identity)

        guard case .cancelled(let identity, let message) = controller.state else {
            return XCTFail("expected cancellation, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertTrue(message.contains("优雅退出请求已发送"))
        XCTAssertEqual(runtime.sentActions, [.gracefulExit])
        XCTAssertFalse(controller.canForceTerminate(for: process.identity))
        await waitUntil {
            controller.recentEvents.contains { $0.outcome == .cancelled }
        }
    }

    func testIntentAuditFailureStopsActionBeforeSignal() async throws {
        let process = makeProcess(pid: 4106, name: "worker")
        let paths = makeActionPaths()
        try FileManager.default.createDirectory(at: paths.file, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let runtime = FakeProcessActionRuntime()
        runtime.setSamples([process, nil], for: process.identity.pid)
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: process)
        await waitUntil { !controller.isBusy }
        guard case .failed(let identity, let message) = controller.state else {
            return XCTFail("expected intent audit failure, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertTrue(message.contains("未发送优雅退出请求"))
        XCTAssertFalse(controller.isBusy)
        await waitUntil { controller.auditError != nil }
        XCTAssertTrue(runtime.sentActions.isEmpty)
    }

    func testFailedAuditEventRetriesBeforeLaterOperationWithSameEventID() async throws {
        let first = makeProcess(pid: 4117, name: "first-audit")
        let second = makeProcess(pid: 4118, name: "second-audit")
        let runtime = FakeProcessActionRuntime()
        runtime.setSamples([second, nil], for: second.identity.pid)
        let paths = makeActionPaths()
        try FileManager.default.createDirectory(at: paths.file, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let store = ProcessActionAuditStore(fileURL: paths.file)
        let controller = ProcessActionController(
            currentUserID: first.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: store,
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: first)
        await waitUntil { !controller.isBusy }
        XCTAssertTrue(runtime.sentActions.isEmpty)
        XCTAssertNotNil(controller.auditError)

        try FileManager.default.removeItem(at: paths.file)
        controller.requestGracefulExit(for: second)
        await waitUntil {
            if case .completed(let identity, let action, _) = controller.state {
                return identity == second.identity && action == .gracefulExit
            }
            return false
        }

        let events = try await store.load(now: runtime.wallClockNow())
        XCTAssertEqual(events.filter { $0.phase == .intent }.count, 2)
        XCTAssertEqual(events.filter { $0.phase == .signalSent }.count, 1)
        XCTAssertEqual(events.filter { $0.phase == .terminal }.count, 1)
        XCTAssertEqual(Set(events.map(\.operationID)).count, 2)
        XCTAssertEqual(runtime.sentActions, [.gracefulExit])
        XCTAssertNil(controller.auditError)
    }

    func testShutdownRetriesFailedAuditEvent() async throws {
        let process = makeProcess(pid: 4119, name: "shutdown-audit")
        let runtime = FakeProcessActionRuntime()
        let paths = makeActionPaths()
        try FileManager.default.createDirectory(at: paths.file, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let store = ProcessActionAuditStore(fileURL: paths.file)
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: store
        )

        controller.requestGracefulExit(for: process)
        await waitUntil { !controller.isBusy }
        XCTAssertTrue(runtime.sentActions.isEmpty)

        try FileManager.default.removeItem(at: paths.file)
        await controller.shutdown()

        let events = try await store.load(now: runtime.wallClockNow())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].phase, .intent)
        XCTAssertNil(controller.auditError)
    }

    func testGracefulTimeoutDisplayClampsExtremeFiniteInput() {
        let runtime = FakeProcessActionRuntime()
        let controller = ProcessActionController(
            currentUserID: 501,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: makeActionPaths().file),
            gracefulTimeout: Double.greatestFiniteMagnitude
        )

        XCTAssertLessThanOrEqual(controller.gracefulTimeoutForDisplay, 24 * 60 * 60)
        let process = makeProcess(pid: 4112, name: "display")
        let status = controller.status(for: process.identity)
        XCTAssertNil(status)
    }

    func testTimeoutReconciliationClearsBusyWhenOriginalProcessExits() async throws {
        let process = makeProcess(pid: 4113, name: "reconcile")
        let runtime = FakeProcessActionRuntime()
        runtime.advancePerSleep = 0.25
        runtime.setSamples([process], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: process)
        await waitUntil {
            if case .timedOut = controller.state { return true }
            return false
        }
        XCTAssertTrue(controller.isBusy)

        // The target exits after the timeout's final identity check. The
        // reconciliation poll must release the controller without a force
        // signal.
        runtime.setSamples([nil], for: process.identity.pid)
        await waitUntil { !controller.isBusy }
        guard case .completed(let identity, let action, _) = controller.state else {
            return XCTFail("expected reconciliation completion, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertEqual(action, .gracefulExit)
        XCTAssertFalse(runtime.sentActions.contains(.forceTerminate))
    }

    func testTimedOutActionCanBeAbandonedBeforeStartingAnotherAction() async throws {
        let first = makeProcess(pid: 4114, name: "timed-out")
        let second = makeProcess(pid: 4115, name: "follow-up")
        let runtime = FakeProcessActionRuntime()
        runtime.advancePerSleep = 0.25
        runtime.setSamples([first], for: first.identity.pid)
        runtime.setSamples([second, nil], for: second.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: first.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1
        )

        controller.requestGracefulExit(for: first)
        await waitUntil {
            if case .timedOut = controller.state { return true }
            return false
        }
        XCTAssertTrue(controller.canCancel(for: first.identity))

        controller.cancel(for: first.identity)
        XCTAssertFalse(controller.isBusy)
        XCTAssertFalse(controller.canForceTerminate(for: first.identity))
        guard case .cancelled(let identity, let message) = controller.state else {
            return XCTFail("expected abandoned timeout, got \(controller.state)")
        }
        XCTAssertEqual(identity, first.identity)
        XCTAssertTrue(message.contains("已停止跟踪"))
        XCTAssertTrue(message.contains("未发送强制结束"))

        controller.requestGracefulExit(for: second)
        await waitUntil {
            if case .completed(let identity, let action, _) = controller.state {
                return identity == second.identity && action == .gracefulExit
            }
            return false
        }
        XCTAssertEqual(runtime.sentActions, [.gracefulExit, .gracefulExit])
    }

    func testCancellingForceVerificationPreservesSentSignalFact() async throws {
        let process = makeProcess(pid: 4116, name: "force-verification")
        let runtime = FakeProcessActionRuntime()
        runtime.advancePerSleep = 0.25
        runtime.setSamples([process], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 1,
            forceVerificationTimeout: 1
        )

        controller.requestGracefulExit(for: process)
        await waitUntil {
            if case .timedOut = controller.state { return true }
            return false
        }

        runtime.advancePerSleep = 0
        controller.requestForceTerminate(for: process)
        await waitUntil {
            if case .verifyingForce = controller.state { return true }
            return false
        }
        XCTAssertEqual(runtime.sentActions, [.gracefulExit, .forceTerminate])
        XCTAssertTrue(controller.canCancel(for: process.identity))
        XCTAssertTrue(controller.status(for: process.identity)?.message.contains("已发送") == true)

        controller.cancel(for: process.identity)
        guard case .cancelled(let identity, let message) = controller.state else {
            return XCTFail("expected verification cancellation, got \(controller.state)")
        }
        XCTAssertEqual(identity, process.identity)
        XCTAssertTrue(message.contains("强制结束请求已发送"))
        XCTAssertTrue(message.contains("停止等待"))
        await waitUntil {
            controller.recentEvents.contains {
                $0.action == .forceTerminate
                    && $0.outcome == .cancelled
                    && $0.detail.contains("请求已发送")
            }
        }
    }

    func testShutdownDrainsBackgroundAuditAndIsIdempotent() async throws {
        let process = makeProcess(pid: 4199, name: "self-target")
        let runtime = FakeProcessActionRuntime()
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let store = ProcessActionAuditStore(fileURL: paths.file)
        let controller = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: process.identity.pid,
            runtime: runtime,
            auditStore: store
        )

        controller.requestGracefulExit(for: process)
        await controller.shutdown()
        await controller.shutdown()

        let events = try await store.load(now: runtime.wallClockNow())
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].action, .gracefulExit)
        XCTAssertEqual(events[0].outcome, .denied)
        XCTAssertNil(controller.auditError)

        controller.requestGracefulExit(for: process)
        let reloadedEvents = try await store.load(now: runtime.wallClockNow())
        XCTAssertEqual(reloadedEvents.count, 1)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("condition was not reached", file: file, line: line)
    }

    private func makeProcess(
        pid: Int32,
        name: String,
        parentPID: Int32 = 1,
        userID: UInt32 = 501,
        startTimeSeconds: UInt64 = 1
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            identity: ProcessIdentity(
                pid: pid,
                startTimeSeconds: startTimeSeconds,
                startTimeMicroseconds: UInt64(pid)
            ),
            parentPID: parentPID,
            userID: userID,
            isSystem: false,
            name: name,
            executablePath: "/Users/test/bin/\(name)",
            residentBytes: 100,
            physicalFootprintBytes: 200,
            virtualBytes: 300,
            userTimeNanos: 0,
            systemTimeNanos: 0,
            threadCount: 1
        )
    }

    func testRefreshAuditLoadsPersistedEvents() async throws {
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let now = Date().addingTimeInterval(-1)
        let store = ProcessActionAuditStore(fileURL: paths.file)
        let event = ProcessActionAuditEvent(
            id: "refresh-audit",
            timestamp: now,
            action: .gracefulExit,
            outcome: .completed,
            processLabel: "worker",
            detail: "done"
        )
        _ = try await store.append(event, now: now)

        let controller = ProcessActionController(
            currentUserID: 501,
            monitorPID: 9999,
            auditStore: store
        )
        await controller.refreshAudit()

        XCTAssertTrue(controller.recentEvents.contains { $0.id == "refresh-audit" })
        XCTAssertNil(controller.auditError)
        await controller.shutdown()
    }

    func testExternalAuditIsPersistedAndPublished() async throws {
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let controller = ProcessActionController(
            auditStore: ProcessActionAuditStore(fileURL: paths.file)
        )
        let event = ProcessActionAuditEvent(
            id: "external-audit",
            operationID: "cleanup-operation",
            action: .gracefulExit,
            phase: .intent,
            outcome: .completed,
            processLabel: "worker",
            detail: "智能清理：准备请求正常退出"
        )

        let recorded = await controller.recordExternalAudit(event)
        XCTAssertTrue(recorded)
        XCTAssertTrue(controller.recentEvents.contains { $0.id == "external-audit" })
        await controller.shutdown()
    }

    func testManualActionHoldsSharedGateAndBlocksSmartCleanup() async throws {
        let process = makeProcess(pid: 4201, name: "worker")
        let runtime = FakeProcessActionRuntime()
        runtime.setSamples([process], for: process.identity.pid)
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }

        let actions = ProcessActionController(
            currentUserID: process.userID,
            monitorPID: 9999,
            runtime: runtime,
            auditStore: ProcessActionAuditStore(fileURL: paths.file),
            gracefulTimeout: 5,
            forceVerificationTimeout: 0.5
        )

        let suite = "cleanup-gate-" + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let defaults = UserDefaults(suiteName: suite)!
        let cleanupRuntime = FakeCleanupRuntime()
        let app = cleanupApp(1)
        cleanupRuntime.observations = [observation(app)]
        let cleanup = SmartCleanupController(
            runtime: cleanupRuntime,
            defaults: defaults,
            operationGate: actions.operationGate
        )
        cleanup.setAuthorized(app, true)

        actions.requestGracefulExit(for: process)
        XCTAssertEqual(actions.operationGate.owner, .manualAction)

        cleanup.start(confirmedApplications: [app])
        XCTAssertFalse(cleanup.isBusy, "Smart Cleanup must not start while a manual action holds the gate")
        XCTAssertTrue(cleanupRuntime.requests.isEmpty)

        actions.cancel(for: process.identity)
        XCTAssertNil(actions.operationGate.owner)
        await actions.shutdown()
    }

    func testExternalAuditRetriesSentFactsButNeverRetriesFailedIntent() async throws {
        let paths = makeActionPaths()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        try FileManager.default.createDirectory(at: paths.file, withIntermediateDirectories: true)
        let store = ProcessActionAuditStore(fileURL: paths.file)
        let actions = ProcessActionController(auditStore: store)
        await actions.refreshAudit()
        var retainedIDs = Set<String>()
        for phase in [ProcessActionAuditPhase.intent, .signalSent, .terminal] {
            let event = ProcessActionAuditEvent(operationID: "external-retry", action: .gracefulExit,
                phase: phase, outcome: .completed, processLabel: "fixture", detail: "fixture event")
            let appended = await actions.recordExternalAudit(event)
            XCTAssertFalse(appended)
            if phase != .intent { retainedIDs.insert(event.id) }
        }
        try FileManager.default.removeItem(at: paths.file)
        await actions.shutdown()
        let events = try await store.load()
        XCTAssertEqual(Set(events.map(\.id)), retainedIDs)
        XCTAssertEqual(Set(events.map(\.phase)), Set([.signalSent, .terminal]))
        XCTAssertNil(actions.auditError)
    }

    private func makeActionPaths() -> (file: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMonitorActionController-" + UUID().uuidString, isDirectory: true)
        return (directory.appendingPathComponent("actions.jsonl"), directory)
    }
}

@MainActor
private final class FakeProcessActionRuntime: ProcessActionRuntime {
    private var sampleQueues: [Int32: [ProcessSnapshot?]] = [:]
    private var fallbackSnapshots: [Int32: ProcessSnapshot] = [:]
    private var existence: [Int32: Bool] = [:]
    private var gracefulSendHoldPIDs = Set<Int32>()
    private var gracefulSendWaiters: [Int32: CheckedContinuation<Void, Never>] = [:]
    private var gracefulSendWaitingPIDs = Set<Int32>()
    private var gracefulSendCompletedPIDs = Set<Int32>()

    var gracefulResult: ProcessActionSignalResult = .sent
    var forceResult: ProcessActionSignalResult = .sent
    var sentActions: [ProcessActionKind] = []
    var advancePerSleep: TimeInterval = 0.25
    var wallClockAdvancePerSleep: TimeInterval = 0.25
    var failSleep = false
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var monotonicClock: UInt64 = 1_000_000_000

    func setSamples(_ samples: [ProcessSnapshot?], for pid: Int32) {
        sampleQueues[pid] = samples
        if let first = samples.compactMap({ $0 }).first {
            fallbackSnapshots[pid] = first
            existence[pid] = true
        }
    }

    func holdGracefulSend(for pid: Int32) {
        gracefulSendHoldPIDs.insert(pid)
    }

    func releaseGracefulSend(for pid: Int32) {
        gracefulSendHoldPIDs.remove(pid)
        gracefulSendWaiters.removeValue(forKey: pid)?.resume()
    }

    func isGracefulSendWaiting(for pid: Int32) -> Bool {
        gracefulSendWaitingPIDs.contains(pid)
    }

    func didFinishGracefulSend(for pid: Int32) -> Bool {
        gracefulSendCompletedPIDs.contains(pid)
    }

    func sample(pid: Int32) async -> ProcessSnapshot? {
        if var queue = sampleQueues[pid], !queue.isEmpty {
            let result = queue.removeFirst()
            sampleQueues[pid] = queue
            if let result {
                fallbackSnapshots[pid] = result
                existence[pid] = true
            } else {
                existence[pid] = false
            }
            await Task.yield()
            return result
        }
        await Task.yield()
        return fallbackSnapshots[pid]
    }

    func processExists(pid: Int32) async -> Bool {
        await Task.yield()
        return existence[pid] ?? (fallbackSnapshots[pid] != nil)
    }

    func sendGraceful(to process: ProcessSnapshot) async -> ProcessActionSignalResult {
        sentActions.append(.gracefulExit)
        if gracefulSendHoldPIDs.contains(process.identity.pid) {
            gracefulSendWaitingPIDs.insert(process.identity.pid)
            await withCheckedContinuation { continuation in
                gracefulSendWaiters[process.identity.pid] = continuation
            }
            gracefulSendWaitingPIDs.remove(process.identity.pid)
        }
        gracefulSendCompletedPIDs.insert(process.identity.pid)
        await Task.yield()
        return gracefulResult
    }

    func sendForce(to process: ProcessSnapshot) async -> ProcessActionSignalResult {
        sentActions.append(.forceTerminate)
        await Task.yield()
        return forceResult
    }

    func wallClockNow() -> Date { clock }

    func monotonicNanoseconds() -> UInt64 { monotonicClock }

    func sleep(for duration: Duration) async throws {
        clock = clock.addingTimeInterval(wallClockAdvancePerSleep)
        let advance = UInt64(max(advancePerSleep, 0) * 1_000_000_000)
        monotonicClock = monotonicClock.addingReportingOverflow(advance).partialValue
        await Task.yield()
        if Task.isCancelled { throw CancellationError() }
        if failSleep { throw FakeRuntimeError.timerUnavailable }
    }

    private enum FakeRuntimeError: Error {
        case timerUnavailable
    }
}
