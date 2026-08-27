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
        XCTAssertTrue(controller.canForceTerminate(for: process.identity))

        // A stale row for a PID-reused process must not erase the original
        // timeout or make the replacement eligible for force termination.
        controller.requestForceTerminate(for: replacement)
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

    func testAuditFailureDoesNotLeaveActionBusy() async throws {
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
        await waitUntil {
            if case .completed = controller.state { return true }
            return false
        }
        XCTAssertFalse(controller.isBusy)
        await waitUntil { controller.auditError != nil }
        XCTAssertTrue(runtime.sentActions.contains(.gracefulExit))
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
