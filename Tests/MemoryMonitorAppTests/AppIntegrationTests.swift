import Foundation
import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

@MainActor
final class AppIntegrationTests: XCTestCase {
    func testLoginCoordinatorRegistersAndUnregistersWithInjectedRuntime() async {
        let runtime = FakeLoginLaunchRuntime()
        let coordinator = LoginLaunchCoordinator(runtime: runtime)

        XCTAssertEqual(coordinator.status, .notRegistered)
        XCTAssertFalse(coordinator.toggleValue)

        coordinator.setEnabled(true)
        await waitUntil { !coordinator.isUpdating }

        XCTAssertEqual(runtime.registerCount, 1)
        XCTAssertEqual(coordinator.status, .enabled)
        XCTAssertTrue(coordinator.toggleValue)
        XCTAssertNil(coordinator.lastError)

        coordinator.setEnabled(false)
        await waitUntil { !coordinator.isUpdating }

        XCTAssertEqual(runtime.unregisterCount, 1)
        XCTAssertEqual(coordinator.status, .notRegistered)
        XCTAssertFalse(coordinator.toggleValue)
    }

    func testLoginCoordinatorSurfacesRegistrationFailure() async {
        let runtime = FakeLoginLaunchRuntime()
        runtime.registerError = FakeLoginLaunchRuntimeError.registrationDenied
        let coordinator = LoginLaunchCoordinator(runtime: runtime)

        coordinator.setEnabled(true)
        await waitUntil { !coordinator.isUpdating }

        XCTAssertEqual(coordinator.status, .notRegistered)
        XCTAssertFalse(coordinator.toggleValue)
        XCTAssertEqual(runtime.registerCount, 1)
        XCTAssertTrue(coordinator.lastError?.contains("注册被拒绝") == true)
    }

    func testLoginCoordinatorTreatsApprovalAsRegisteredToggle() async {
        let runtime = FakeLoginLaunchRuntime()
        runtime.statusValue = .requiresApproval
        let coordinator = LoginLaunchCoordinator(runtime: runtime)

        XCTAssertTrue(coordinator.toggleValue)
        XCTAssertEqual(coordinator.status.title, "等待系统批准")

        coordinator.setEnabled(false)
        await waitUntil { !coordinator.isUpdating }
        XCTAssertEqual(runtime.unregisterCount, 1)
        XCTAssertEqual(coordinator.status, .notRegistered)
    }

    func testHealthEvaluatorMarksPartialSourcesAsDegraded() {
        let input = makeHealthInput(
            gpuStatus: .unavailable(message: "系统未提供 GPU 利用率"),
            processStatus: .estimated(
                at: Date(timeIntervalSince1970: 100),
                message: "部分条目受权限限制"
            ),
            observedProcessCount: 515,
            listedProcessCount: 795,
            auditError: "无法写入进程操作记录"
        )

        let snapshot = MonitorHealthEvaluator.evaluate(input)

        XCTAssertEqual(snapshot.overall, MonitorHealthLevel.degraded)
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "processes" })?.level,
            MonitorHealthLevel.degraded
        )
        XCTAssertTrue(snapshot.items.first(where: { $0.id == "processes" })?.detail.contains("515/795") == true)
        XCTAssertEqual(snapshot.items.first(where: { $0.id == "audit" })?.status, "记录受限")
        XCTAssertEqual(snapshot.items.first(where: { $0.id == "login" })?.level, .healthy)
    }

    func testHealthEvaluatorEscalatesUnavailableRequiredSources() {
        let input = makeHealthInput(
            systemStatus: .error("系统内存读取失败"),
            processStatus: .unavailable(message: "等待首次进程采样"),
            observedProcessCount: 0,
            listedProcessCount: 0,
            loginStatus: .requiresApproval
        )

        let snapshot = MonitorHealthEvaluator.evaluate(input)

        XCTAssertEqual(snapshot.overall, MonitorHealthLevel.attention)
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "system" })?.level,
            MonitorHealthLevel.attention
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "processes" })?.level,
            MonitorHealthLevel.attention
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "login" })?.level,
            MonitorHealthLevel.degraded
        )
    }

    func testHealthEvaluatorFlagsSlowSampling() {
        let input = makeHealthInput(
            samplingDurationMilliseconds: 2_100,
            processDurationMilliseconds: 1_900
        )

        let snapshot = MonitorHealthEvaluator.evaluate(input)

        XCTAssertEqual(snapshot.overall, MonitorHealthLevel.attention)
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "sampling" })?.status,
            "较慢"
        )
    }

    func testAuditFilteringSearchesSanitizedFieldsAndSortsNewestFirst() {
        let now = Date(timeIntervalSince1970: 2_000)
        let completed = ProcessActionAuditEvent(
            id: "completed",
            timestamp: now.addingTimeInterval(-30),
            action: .gracefulExit,
            outcome: .completed,
            processLabel: "Node Worker",
            detail: "进程已退出"
        )
        let failed = ProcessActionAuditEvent(
            id: "failed",
            timestamp: now,
            action: .forceTerminate,
            outcome: .failed,
            processLabel: "Chrome Helper",
            detail: "系统拒绝了请求"
        )

        let attention = AuditEventFiltering.apply(
            events: [completed, failed],
            filter: .attention,
            query: "chrome"
        )
        XCTAssertEqual(attention.map(\.id), ["failed"])

        let all = AuditEventFiltering.apply(
            events: [completed, failed],
            filter: .all,
            query: ""
        )
        XCTAssertEqual(all.map(\.id), ["failed", "completed"])
    }

    private func makeHealthInput(
        systemStatus: SampleStatus = .estimated(
            at: Date(timeIntervalSince1970: 100),
            message: "内存使用率按可回收内存估算"
        ),
        cpuStatus: SampleStatus = .available(at: Date(timeIntervalSince1970: 100)),
        gpuStatus: SampleStatus = .available(at: Date(timeIntervalSince1970: 100)),
        processStatus: SampleStatus = .available(at: Date(timeIntervalSince1970: 100)),
        observedProcessCount: Int = 800,
        listedProcessCount: Int = 800,
        historyRecordCount: Int = 12,
        historyError: String? = nil,
        auditError: String? = nil,
        loginStatus: LoginLaunchStatus = .notRegistered,
        samplingDurationMilliseconds: Double = 90,
        processDurationMilliseconds: Double? = 80
    ) -> MonitorHealthInput {
        MonitorHealthInput(
            systemStatus: systemStatus,
            cpuStatus: cpuStatus,
            gpuStatus: gpuStatus,
            processStatus: processStatus,
            observedProcessCount: observedProcessCount,
            listedProcessCount: listedProcessCount,
            samplingDiagnostics: SamplingDiagnostics(
                mode: .panel,
                totalDurationMilliseconds: samplingDurationMilliseconds,
                processDurationMilliseconds: processDurationMilliseconds,
                processSamplingPerformed: true,
                processCount: observedProcessCount,
                listedProcessCount: listedProcessCount
            ),
            historyRecordCount: historyRecordCount,
            historyError: historyError,
            historyDiagnostics: HistoryStoreDiagnostics(
                snapshotBytes: 100,
                journalBytes: 50,
                pendingRecordCount: 0,
                journalRecordCount: 1,
                compactionCount: 1,
                lastCompactionAt: Date(timeIntervalSince1970: 90)
            ),
            auditError: auditError,
            loginStatus: loginStatus,
            loginError: nil,
            checkedAt: Date(timeIntervalSince1970: 100)
        )
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
}

@MainActor
private final class FakeLoginLaunchRuntime: LoginLaunchRuntime {
    var statusValue: LoginLaunchStatus = .notRegistered
    var registerError: Error?
    var unregisterError: Error?
    var registerCount = 0
    var unregisterCount = 0

    func status() -> LoginLaunchStatus { statusValue }

    func register() async throws {
        registerCount += 1
        if let registerError { throw registerError }
        statusValue = .enabled
        await Task.yield()
    }

    func unregister() async throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        statusValue = .notRegistered
        await Task.yield()
    }

    func openSystemSettings() {}
}

private enum FakeLoginLaunchRuntimeError: Error, LocalizedError {
    case registrationDenied

    var errorDescription: String? {
        switch self {
        case .registrationDenied: return "注册被拒绝"
        }
    }
}
