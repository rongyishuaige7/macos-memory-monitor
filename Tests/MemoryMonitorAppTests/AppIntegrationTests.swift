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

        coordinator.refreshStatus()
        XCTAssertTrue(coordinator.lastError?.contains("注册被拒绝") == true)
    }

    func testLoginCoordinatorClearsFailureAfterExternalStatusRecovery() async {
        let runtime = FakeLoginLaunchRuntime()
        runtime.registerError = FakeLoginLaunchRuntimeError.registrationDenied
        let coordinator = LoginLaunchCoordinator(runtime: runtime)

        coordinator.setEnabled(true)
        await waitUntil { !coordinator.isUpdating }
        XCTAssertNotNil(coordinator.lastError)

        runtime.registerError = nil
        runtime.statusValue = .enabled
        coordinator.refreshStatus()

        XCTAssertEqual(coordinator.status, .enabled)
        XCTAssertNil(coordinator.lastError)
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

    func testLoginCoordinatorCancelsInFlightUpdateAndClearsBusyState() async {
        let runtime = BlockingLoginLaunchRuntime()
        let coordinator = LoginLaunchCoordinator(runtime: runtime)

        coordinator.setEnabled(true)
        await waitUntil { runtime.registerStarted }
        XCTAssertTrue(coordinator.isUpdating)

        coordinator.cancelUpdate()

        XCTAssertFalse(coordinator.isUpdating)
        XCTAssertEqual(coordinator.status, .notRegistered)
        XCTAssertNil(coordinator.lastError)
        await Task.yield()
        XCTAssertFalse(coordinator.isUpdating)
    }

    func testLoginCoordinatorRefreshesStatusAfterCancelledOperationCompletesLate() async {
        let runtime = LateCompletingLoginLaunchRuntime()
        let coordinator = LoginLaunchCoordinator(runtime: runtime)

        coordinator.setEnabled(true)
        await waitUntil { runtime.registerStarted }
        coordinator.cancelUpdate()
        XCTAssertFalse(coordinator.isUpdating)
        XCTAssertEqual(coordinator.status, .notRegistered)

        // The underlying service completes despite cancellation. Its result
        // must become visible, but must not be able to resurrect the busy flag.
        runtime.completeRegister()
        await waitUntil { coordinator.status == .enabled }
        XCTAssertFalse(coordinator.isUpdating)
        XCTAssertNil(coordinator.lastError)
    }

    func testLoginCoordinatorCanBeReleasedWhileRuntimeIsSuspended() async {
        let runtime = BlockingLoginLaunchRuntime()
        weak var weakCoordinator: LoginLaunchCoordinator?
        var coordinator: LoginLaunchCoordinator? = LoginLaunchCoordinator(runtime: runtime)
        weakCoordinator = coordinator

        coordinator?.setEnabled(true)
        await waitUntil { runtime.registerStarted }
        coordinator = nil

        for _ in 0..<2_000 {
            if weakCoordinator == nil { break }
            await Task.yield()
        }
        XCTAssertNil(weakCoordinator)
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

    func testHealthEvaluatorReportsSupportedRuntimeEnvironment() {
        let input = makeHealthInput(
            runtimeEnvironment: RuntimeEnvironmentStatus(
                osMajor: 14,
                osMinor: 5,
                osPatch: 1,
                architecture: "arm64"
            )
        )

        let snapshot = MonitorHealthEvaluator.evaluate(input)
        let environment = snapshot.items.first { $0.id == "environment" }

        XCTAssertEqual(environment?.status, "支持")
        XCTAssertEqual(environment?.level, .healthy)
        XCTAssertTrue(environment?.detail.contains("14.5.1") == true)
        XCTAssertTrue(environment?.detail.contains("arm64") == true)
    }

    func testHealthEvaluatorFlagsUnsupportedRuntimeOS() {
        let input = makeHealthInput(
            runtimeEnvironment: RuntimeEnvironmentStatus(
                osMajor: 13,
                osMinor: 6,
                architecture: "arm64"
            )
        )

        let snapshot = MonitorHealthEvaluator.evaluate(input)
        let environment = snapshot.items.first { $0.id == "environment" }

        XCTAssertEqual(environment?.status, "不支持")
        XCTAssertEqual(environment?.level, .attention)
        XCTAssertTrue(environment?.detail.contains("最低要求 macOS 14.0") == true)
    }

    func testHealthEvaluatorMarksNonReleaseArchitectureAsLimited() {
        let input = makeHealthInput(
            runtimeEnvironment: RuntimeEnvironmentStatus(
                osMajor: 14,
                architecture: "x86_64"
            )
        )

        let snapshot = MonitorHealthEvaluator.evaluate(input)
        let environment = snapshot.items.first { $0.id == "environment" }

        XCTAssertEqual(environment?.status, "非当前发布目标")
        XCTAssertEqual(environment?.level, .degraded)
        XCTAssertTrue(environment?.detail.contains("x86_64") == true)
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

    func testHealthEvaluatorFlagsStaleRequiredSamples() {
        let input = makeHealthInput(
            now: Date(timeIntervalSince1970: 1_000)
        )

        let snapshot = MonitorHealthEvaluator.evaluate(input)

        XCTAssertEqual(snapshot.overall, .attention)
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "system" })?.status,
            "已过期"
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "processes" })?.level,
            .attention
        )
        XCTAssertTrue(
            snapshot.items.first(where: { $0.id == "processes" })?.detail.contains("距采样") == true
        )
        XCTAssertEqual(
            snapshot.items.first(where: { $0.id == "cpu" })?.level,
            .degraded
        )
    }

    func testHealthEvaluatorRejectsFutureSampleTimestamp() {
        let future = Date(timeIntervalSince1970: 200)
        let input = makeHealthInput(
            systemStatus: .available(at: future),
            now: Date(timeIntervalSince1970: 100)
        )

        let snapshot = MonitorHealthEvaluator.evaluate(input)
        let system = snapshot.items.first(where: { $0.id == "system" })

        XCTAssertEqual(system?.status, "时间异常")
        XCTAssertEqual(system?.level, .attention)
        XCTAssertTrue(system?.detail.contains("晚于诊断时间") == true)
    }

    func testHealthEvaluatorRejectsUsableStatusWithoutSampleTimestamp() {
        let input = makeHealthInput(
            systemStatus: SampleStatus(quality: .available),
            now: Date(timeIntervalSince1970: 100)
        )

        let snapshot = MonitorHealthEvaluator.evaluate(input)
        let system = snapshot.items.first(where: { $0.id == "system" })

        XCTAssertEqual(system?.status, "时间异常")
        XCTAssertEqual(system?.level, .attention)
    }

    func testMonitorViewModelRetainsLastUsableProcessSnapshot() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let firstProcess = makeProcess(pid: 9001, name: "first")
        let secondProcess = makeProcess(pid: 9002, name: "second")
        let firstGroup = makeGroup(id: "first", title: "First", process: firstProcess)
        let secondGroup = makeGroup(id: "second", title: "Second", process: secondProcess)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [firstProcess],
                groups: [firstGroup],
                status: .available(at: timestamp),
                listedCount: 1
            ),
            makeMonitorSnapshot(
                timestamp: timestamp.addingTimeInterval(3),
                processes: [],
                groups: [],
                status: .error("provider denied"),
                listedCount: 0
            ),
            makeMonitorSnapshot(
                timestamp: timestamp.addingTimeInterval(6),
                processes: [secondProcess],
                groups: [secondGroup],
                status: .estimated(at: timestamp.addingTimeInterval(6)),
                listedCount: 10
            ),
            makeMonitorSnapshot(
                timestamp: timestamp.addingTimeInterval(9),
                processes: [secondProcess],
                groups: [secondGroup],
                status: .estimated(at: timestamp.addingTimeInterval(9)),
                listedCount: 2
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: timestamp)
        XCTAssertEqual(model.processes, [firstProcess])
        XCTAssertEqual(model.groups, [firstGroup])

        await model.refreshOnce(at: timestamp.addingTimeInterval(3))
        XCTAssertEqual(model.processes, [firstProcess])
        XCTAssertEqual(model.groups, [firstGroup])
        XCTAssertEqual(model.processStatus.quality, .error)

        await model.refreshOnce(at: timestamp.addingTimeInterval(6))
        XCTAssertEqual(model.processes, [firstProcess])
        XCTAssertEqual(model.groups, [firstGroup])

        await model.refreshOnce(at: timestamp.addingTimeInterval(9))
        XCTAssertEqual(model.processes, [secondProcess])
        XCTAssertEqual(model.groups, [secondGroup])
        XCTAssertEqual(source.requestedModes, [.panel, .panel, .panel, .panel])
    }

    func testMonitorViewModelPublishesLowCoverageCountsWithoutReplacingRows() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let process = makeProcess(pid: 9060, name: "partial")
        let group = makeGroup(id: "partial", title: "Partial", process: process)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [process],
                groups: [group],
                status: .available(at: timestamp),
                listedCount: 1
            ),
            makeMonitorSnapshot(
                timestamp: timestamp.addingTimeInterval(3),
                processes: [process],
                groups: [group],
                status: .estimated(
                    at: timestamp.addingTimeInterval(3),
                    message: "多数条目在扫描期间退出"
                ),
                listedCount: 10
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: timestamp)
        await model.refreshOnce(at: timestamp.addingTimeInterval(3))

        XCTAssertEqual(model.processes, [process])
        XCTAssertEqual(model.groups, [group])
        XCTAssertEqual(model.observedProcessCount, 1)
        XCTAssertEqual(model.listedProcessCount, 10)
        XCTAssertTrue(model.healthSnapshot.items
            .first(where: { $0.id == "processes" })?.detail.contains("1/10") == true)
    }

    func testMonitorViewModelPublishesZeroCoverageWithoutReplacingRows() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let process = makeProcess(pid: 9061, name: "retained")
        let group = makeGroup(id: "retained", title: "Retained", process: process)
        let unavailableMessage = "已枚举 10 个进程，但没有获得可用快照"
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [process],
                groups: [group],
                status: .available(at: timestamp),
                listedCount: 1
            ),
            makeMonitorSnapshot(
                timestamp: timestamp.addingTimeInterval(3),
                processes: [],
                groups: [],
                status: .unavailable(message: unavailableMessage),
                listedCount: 10
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: timestamp)
        await model.refreshOnce(at: timestamp.addingTimeInterval(3))

        XCTAssertEqual(model.processes, [process])
        XCTAssertEqual(model.groups, [group])
        XCTAssertEqual(model.observedProcessCount, 0)
        XCTAssertEqual(model.listedProcessCount, 10)
        XCTAssertEqual(model.processStatus.quality, .unavailable)
        let processHealth = model.healthSnapshot.items.first { $0.id == "processes" }
        XCTAssertEqual(processHealth?.status, "暂无新数据")
        XCTAssertEqual(processHealth?.detail, unavailableMessage)
    }

    func testMonitorViewModelMergesFallbackHistoryAfterStoreRecovery() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [],
                groups: [],
                status: .unavailable(message: "测试无进程数据"),
                listedCount: 0
            ),
            makeMonitorSnapshot(
                timestamp: timestamp.addingTimeInterval(60),
                processes: [],
                groups: [],
                status: .unavailable(message: "测试无进程数据"),
                listedCount: 0
            ),
            makeMonitorSnapshot(
                timestamp: timestamp.addingTimeInterval(120),
                processes: [],
                groups: [],
                status: .unavailable(message: "测试无进程数据"),
                listedCount: 0
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Make the initial read fail. Samples must remain visible in the
        // ViewModel and be merged once the path becomes writable again.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )

        await model.refreshOnce(at: timestamp)
        await model.refreshOnce(at: timestamp.addingTimeInterval(60))
        XCTAssertEqual(model.history.count, 2)

        try FileManager.default.removeItem(at: url)
        await model.refreshOnce(at: timestamp.addingTimeInterval(120))

        XCTAssertEqual(model.history.count, 3)
        let persisted = try await HistoryStore(fileURL: url).load(
            now: timestamp.addingTimeInterval(120)
        )
        XCTAssertEqual(persisted.count, 3)
    }

    func testMonitorViewModelShutdownFlushesNewestSameMinuteSample() async throws {
        let minute = Date(timeIntervalSince1970: 1_699_999_980)
        let firstAt = minute.addingTimeInterval(10)
        let newestAt = minute.addingTimeInterval(40)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: firstAt,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                systemOverride: makeSystemSnapshot(timestamp: firstAt, swapUsedBytes: 1),
                didSampleProcesses: false
            ),
            makeMonitorSnapshot(
                timestamp: newestAt,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                systemOverride: makeSystemSnapshot(timestamp: newestAt, swapUsedBytes: 9),
                didSampleProcesses: false
            )
        ])
        let historyPaths = makeTemporaryHistoryURL()
        let auditPaths = makeTemporaryActionURL()
        defer {
            try? FileManager.default.removeItem(at: historyPaths.directory)
            try? FileManager.default.removeItem(at: auditPaths.directory)
        }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: historyPaths.url),
            processActions: ProcessActionController(
                auditStore: ProcessActionAuditStore(fileURL: auditPaths.url)
            ),
            dateProvider: { newestAt },
            startRefreshTask: false
        )

        await model.refreshOnce(at: firstAt)
        await model.refreshOnce(at: newestAt)
        await model.shutdown()
        await model.shutdown()

        let persisted = try await HistoryStore(fileURL: historyPaths.url).load(now: newestAt)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].sourceSampledAt, newestAt)
        XCTAssertEqual(persisted[0].swapUsedBytes, 9)
        XCTAssertNil(model.historyError)
    }

    func testMonitorViewModelShutdownMergesFallbackAfterStoreRecovery() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_010_000)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                didSampleProcesses: false
            )
        ])
        let historyPaths = makeTemporaryHistoryURL()
        let auditPaths = makeTemporaryActionURL()
        defer {
            try? FileManager.default.removeItem(at: historyPaths.directory)
            try? FileManager.default.removeItem(at: auditPaths.directory)
        }
        try FileManager.default.createDirectory(
            at: historyPaths.url,
            withIntermediateDirectories: true
        )
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: historyPaths.url),
            processActions: ProcessActionController(
                auditStore: ProcessActionAuditStore(fileURL: auditPaths.url)
            ),
            dateProvider: { timestamp },
            startRefreshTask: false
        )

        await model.refreshOnce(at: timestamp)
        XCTAssertNotNil(model.historyError)
        try FileManager.default.removeItem(at: historyPaths.url)

        await model.shutdown()

        let persisted = try await HistoryStore(fileURL: historyPaths.url).load(now: timestamp)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted[0].sourceSampledAt, timestamp)
        XCTAssertNil(model.historyError)
    }

    func testMonitorViewModelShutdownSurfacesFlushFailureWithoutHanging() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_020_000)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                didSampleProcesses: false
            )
        ])
        let historyPaths = makeTemporaryHistoryURL()
        let auditPaths = makeTemporaryActionURL()
        defer {
            try? FileManager.default.removeItem(at: historyPaths.directory)
            try? FileManager.default.removeItem(at: auditPaths.directory)
        }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: historyPaths.url),
            processActions: ProcessActionController(
                auditStore: ProcessActionAuditStore(fileURL: auditPaths.url)
            ),
            dateProvider: { timestamp },
            startRefreshTask: false
        )
        await model.refreshOnce(at: timestamp)
        try FileManager.default.removeItem(at: historyPaths.url)
        try FileManager.default.createDirectory(
            at: historyPaths.url,
            withIntermediateDirectories: false
        )

        await model.shutdown()

        XCTAssertNotNil(model.historyError)
    }

    func testTerminationCoordinatorTimesOutAndRepliesOnlyOnce() async throws {
        let coordinator = ApplicationTerminationCoordinator(timeoutSeconds: 0.01)
        var suspendedShutdown: CheckedContinuation<Void, Never>?
        var replies: [Bool] = []

        coordinator.begin(
            shutdown: {
                await withCheckedContinuation { continuation in
                    suspendedShutdown = continuation
                }
            },
            reply: { replies.append($0) }
        )
        coordinator.begin(
            shutdown: {},
            reply: { replies.append($0) }
        )
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(replies, [true])
        XCTAssertTrue(coordinator.hasReplied)

        suspendedShutdown?.resume()
        suspendedShutdown = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(replies, [true])
    }

    func testMonitorViewModelRefreshTaskDoesNotRetainModelWhileWaiting() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let process = makeProcess(pid: 9050, name: "lifecycle")
        let group = makeGroup(id: "lifecycle", title: "Lifecycle", process: process)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [process],
                groups: [group],
                status: .available(at: timestamp),
                listedCount: 1
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        weak var weakModel: MonitorViewModel?
        var model: MonitorViewModel? = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: true
        )
        weakModel = model

        // Ensure the task has entered a real refresh pass before releasing the
        // only external strong reference. This makes the test catch a task
        // that retains the model while sleeping between samples.
        await waitUntil { source.requestedModes.count == 1 }
        model = nil

        for _ in 0..<2_000 {
            if weakModel == nil { break }
            await Task.yield()
        }
        XCTAssertNil(weakModel)
    }

    func testFailedProcessScanDoesNotDelayNextBackgroundRetry() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let process = makeProcess(pid: 9010, name: "worker")
        let group = makeGroup(id: "worker", title: "Worker", process: process)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [process],
                groups: [group],
                status: .available(at: timestamp),
                listedCount: 1
            ),
            makeMonitorSnapshot(
                timestamp: timestamp.addingTimeInterval(20),
                processes: [],
                groups: [],
                status: .error("provider denied"),
                listedCount: 0
            ),
            makeMonitorSnapshot(
                timestamp: timestamp.addingTimeInterval(60),
                processes: [process],
                groups: [group],
                status: .available(at: timestamp.addingTimeInterval(60)),
                listedCount: 1
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )

        await model.refreshOnce(at: timestamp)
        await model.refreshOnce(at: timestamp.addingTimeInterval(20))
        await model.refreshOnce(at: timestamp.addingTimeInterval(60))

        XCTAssertEqual(source.requestedModes, [.backgroundProcess, .background, .backgroundProcess])
    }

    func testMonitorViewModelUsesValidatedProcessTimestampForCadenceAndHistory() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let firstSampleAt = timestamp.addingTimeInterval(-30)
        let secondTimestamp = timestamp.addingTimeInterval(40)
        let secondSampleAt = secondTimestamp.addingTimeInterval(-2)
        let process = makeProcess(pid: 9011, name: "timestamped-worker")
        let group = makeGroup(id: "timestamped-worker", title: "Timestamped Worker", process: process)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [process],
                groups: [group],
                status: .available(at: firstSampleAt),
                listedCount: 1
            ),
            makeMonitorSnapshot(
                timestamp: secondTimestamp,
                processes: [process],
                groups: [group],
                status: .available(at: secondSampleAt),
                listedCount: 1
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )

        await model.refreshOnce(at: timestamp)
        await model.refreshOnce(at: secondTimestamp)

        // The first process sample is already 30 seconds old. At the next
        // pass (40 seconds later), the actual marker makes the 60-second
        // background process interval due; using the enclosing pass timestamp
        // would incorrectly skip this scan.
        XCTAssertEqual(source.requestedModes, [.backgroundProcess, .backgroundProcess])
        XCTAssertTrue(model.history.contains { $0.workloadsSampledAt == firstSampleAt })
        XCTAssertTrue(model.history.contains { $0.workloadsSampledAt == secondSampleAt })
        XCTAssertTrue(model.history.contains {
            $0.workloadsSampledAt == firstSampleAt
                && $0.workloadInventoryIsComplete == true
        })
        XCTAssertTrue(model.history.contains {
            $0.workloadsSampledAt == secondSampleAt
                && $0.workloadInventoryIsComplete == true
        })
    }

    func testMonitorViewModelPersistsSampleAfterEightHourClockJump() async throws {
        let base = Date(timeIntervalSince1970: 1_700_050_000)
        let jumped = base.addingTimeInterval(8 * 60 * 60)
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                didSampleProcesses: false
            ),
            makeMonitorSnapshot(
                timestamp: jumped,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                didSampleProcesses: false
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )

        await model.refreshOnce(at: base)
        await model.refreshOnce(at: jumped)

        XCTAssertNil(model.historyError)
        XCTAssertTrue(model.history.contains { $0.sourceSampledAt == base })
        XCTAssertTrue(model.history.contains { $0.sourceSampledAt == jumped })
    }

    func testMonitorViewModelImmediatelyPersistsSamplesAfterLargeClockRollbacks() async throws {
        let rollbackIntervals: [TimeInterval] = [
            25 * 60 * 60,
            7 * 24 * 60 * 60
        ]

        for (index, rollbackInterval) in rollbackIntervals.enumerated() {
            let base = Date(timeIntervalSince1970: 1_700_060_000 + Double(index) * 1_000)
            let rolledBack = base.addingTimeInterval(-rollbackInterval)
            let source = FakeMonitorSamplingSource(snapshots: [
                makeMonitorSnapshot(
                    timestamp: base,
                    processes: [],
                    groups: [],
                    status: .unavailable(),
                    listedCount: 0,
                    didSampleProcesses: false
                ),
                makeMonitorSnapshot(
                    timestamp: rolledBack,
                    processes: [],
                    groups: [],
                    status: .unavailable(),
                    listedCount: 0,
                    didSampleProcesses: false
                )
            ])
            let (url, directory) = makeTemporaryHistoryURL()
            defer { try? FileManager.default.removeItem(at: directory) }
            let model = MonitorViewModel(
                sampler: source,
                historyStore: HistoryStore(fileURL: url),
                startRefreshTask: false
            )

            await model.refreshOnce(at: base)
            await model.refreshOnce(at: rolledBack)

            XCTAssertNil(model.historyError)
            XCTAssertTrue(
                model.history.contains { $0.sourceSampledAt == rolledBack },
                "rollback interval: \(rollbackInterval)"
            )
        }
    }

    func testMonitorViewModelCoalescesConcurrentRefreshesToLatestRequest() async throws {
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let firstProcess = makeProcess(pid: 9020, name: "first")
        let latestProcess = makeProcess(pid: 9021, name: "latest")
        let first = makeMonitorSnapshot(
            timestamp: base,
            processes: [firstProcess],
            groups: [makeGroup(id: "first", title: "First", process: firstProcess)],
            status: .available(at: base),
            listedCount: 1
        )
        let latestTimestamp = base.addingTimeInterval(120)
        let latest = makeMonitorSnapshot(
            timestamp: latestTimestamp,
            processes: [latestProcess],
            groups: [makeGroup(id: "latest", title: "Latest", process: latestProcess)],
            status: .available(at: latestTimestamp),
            listedCount: 1
        )
        let source = BlockingMonitorSamplingSource(snapshots: [first, latest])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        let firstTask = Task { await model.refreshOnce(at: base) }
        await waitUntil { source.requestedTimestamps.count == 1 }

        // Both requests arrive while the first provider call is suspended.
        // The middle timestamp is intentionally superseded by the latest one.
        let middleTask = Task {
            await model.refreshOnce(at: base.addingTimeInterval(60))
        }
        let latestTask = Task { await model.refreshOnce(at: latestTimestamp) }
        for _ in 0..<20 { await Task.yield() }
        source.releaseFirst()

        await firstTask.value
        await middleTask.value
        await latestTask.value

        XCTAssertEqual(source.requestedTimestamps, [base, latestTimestamp])
        XCTAssertEqual(model.processes, [latestProcess])
        XCTAssertEqual(model.updatedAt, latestTimestamp)
    }

    func testMonitorViewModelQueuedLiveRefreshReadsClockAgainBeforeSampling() async throws {
        let base = Date(timeIntervalSince1970: 1_700_105_000)
        let delayed = base.addingTimeInterval(301)
        let clock = MutableDateProvider(now: base)
        let source = BlockingMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                didSampleProcesses: false
            ),
            makeMonitorSnapshot(
                timestamp: delayed,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                didSampleProcesses: false
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            dateProvider: { clock.now },
            startRefreshTask: false
        )

        let firstTask = Task { await model.refreshOnce() }
        await waitUntil { source.requestedTimestamps.count == 1 }
        let queuedTask = Task { await model.refreshOnce() }
        for _ in 0..<20 { await Task.yield() }
        clock.now = delayed
        source.releaseFirst()

        await firstTask.value
        await queuedTask.value

        XCTAssertEqual(source.requestedTimestamps, [base, delayed])
        XCTAssertEqual(model.updatedAt, delayed)
    }

    func testMonitorViewModelRejectsLateSnapshotWithoutCorruptingBaselines() async throws {
        let firstTimestamp = Date(timeIntervalSince1970: 1_700_110_000)
        // This result is older than the pass already accepted, even though it
        // is returned for a newer request. A provider may legitimately return
        // a slightly cached value, so the rejection contract is based on the
        // accepted snapshot timeline rather than the request wall clock.
        let lateTimestamp = firstTimestamp.addingTimeInterval(-30)
        let secondTimestamp = firstTimestamp.addingTimeInterval(60)
        let firstProcess = makeProcess(pid: 9030, name: "first")
        let lateProcess = makeProcess(pid: 9031, name: "late")
        let secondProcess = makeProcess(pid: 9032, name: "second")

        let first = makeMonitorSnapshot(
            timestamp: firstTimestamp,
            processes: [firstProcess],
            groups: [makeGroup(id: "first", title: "First", process: firstProcess)],
            status: .available(at: firstTimestamp),
            listedCount: 1,
            cpuTime: CPUTimeSnapshot(userTicks: 100, systemTicks: 0, idleTicks: 100, niceTicks: 0)
        )
        let late = makeMonitorSnapshot(
            timestamp: lateTimestamp,
            processes: [lateProcess],
            groups: [makeGroup(id: "late", title: "Late", process: lateProcess)],
            status: .available(at: lateTimestamp),
            listedCount: 1,
            cpuTime: CPUTimeSnapshot(userTicks: 10_000, systemTicks: 0, idleTicks: 0, niceTicks: 0)
        )
        let finalTimestamp = firstTimestamp.addingTimeInterval(120)
        let second = makeMonitorSnapshot(
            timestamp: finalTimestamp,
            processes: [secondProcess],
            groups: [makeGroup(id: "second", title: "Second", process: secondProcess)],
            status: .available(at: secondTimestamp),
            listedCount: 1,
            cpuTime: CPUTimeSnapshot(userTicks: 200, systemTicks: 0, idleTicks: 200, niceTicks: 0)
        )
        let source = TimestampedMonitorSamplingSource(snapshots: [
            firstTimestamp: first,
            secondTimestamp: late,
            firstTimestamp.addingTimeInterval(120): second
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: firstTimestamp)
        // The provider deliberately returns a pass older than the one already
        // accepted for this newer request. It must not replace visible rows or
        // the CPU baseline.
        await model.refreshOnce(at: secondTimestamp)
        XCTAssertEqual(model.updatedAt, firstTimestamp)
        XCTAssertEqual(model.processes, [firstProcess])

        await model.refreshOnce(at: finalTimestamp)
        XCTAssertEqual(model.updatedAt, finalTimestamp)
        XCTAssertEqual(model.processes, [secondProcess])
        XCTAssertEqual(try XCTUnwrap(model.cpuUsageFraction), 0.5, accuracy: 0.000_1)
    }

    func testMonitorViewModelChoosesNewestTimestampWhenQueuedRequestsArriveOutOfOrder() async throws {
        let base = Date(timeIntervalSince1970: 1_700_120_000)
        let newerTimestamp = base.addingTimeInterval(120)
        let olderTimestamp = base.addingTimeInterval(60)
        let firstProcess = makeProcess(pid: 9040, name: "first")
        let newestProcess = makeProcess(pid: 9041, name: "newest")
        let source = BlockingMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [firstProcess],
                groups: [makeGroup(id: "first", title: "First", process: firstProcess)],
                status: .available(at: base),
                listedCount: 1
            ),
            makeMonitorSnapshot(
                timestamp: newerTimestamp,
                processes: [newestProcess],
                groups: [makeGroup(id: "newest", title: "Newest", process: newestProcess)],
                status: .available(at: newerTimestamp),
                listedCount: 1
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        let firstTask = Task { await model.refreshOnce(at: base) }
        await waitUntil { source.requestedTimestamps.count == 1 }
        // Deliberately submit the newer point first, then an older point.
        let newerTask = Task { await model.refreshOnce(at: newerTimestamp) }
        let olderTask = Task { await model.refreshOnce(at: olderTimestamp) }
        source.releaseFirst()

        await firstTask.value
        await newerTask.value
        await olderTask.value

        XCTAssertEqual(source.requestedTimestamps, [base, newerTimestamp])
        XCTAssertEqual(model.updatedAt, newerTimestamp)
        XCTAssertEqual(model.processes, [newestProcess])
    }

    func testMonitorViewModelHealthCheckTimestampWaitsForSampling() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_700_200_000)
        let process = makeProcess(pid: 9022, name: "health")
        let source = BlockingMonitorSamplingSource(
            snapshots: [makeMonitorSnapshot(
                timestamp: timestamp,
                processes: [process],
                groups: [makeGroup(id: "health", title: "Health", process: process)],
                status: .available(at: timestamp),
                listedCount: 1
            )]
        )
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        let before = model.healthCheckedAt

        model.refreshHealth()
        await waitUntil { source.requestedTimestamps.count == 1 }
        XCTAssertEqual(model.healthCheckedAt, before)

        source.releaseFirst()
        await waitUntil { model.healthCheckedAt > before }
    }

    func testMonitorViewModelKeepsRecommendationAndPairedBaselineWhenSystemSampleFails() async throws {
        let base = Date(timeIntervalSince1970: 1_700_300_000)
        let process = makeProcess(pid: 9023, name: "memory-worker", footprint: 200_000_000)
        let group = makeGroup(
            id: "memory-worker",
            title: "Memory Worker",
            process: process,
            footprint: 200_000_000
        )
        let criticalSystem = SystemMemorySnapshot(
            timestamp: base,
            totalBytes: 1_000_000_000,
            pageSize: 1,
            freeBytes: 1,
            activeBytes: 700_000_000,
            inactiveBytes: 0,
            speculativeBytes: 0,
            wiredBytes: 200_000_000,
            purgeableBytes: 10_000_000,
            compressedBytes: 100,
            throttledPages: 0,
            swapTotalBytes: 2_000_000_000,
            swapUsedBytes: 0,
            swapFreeBytes: 2_000_000_000
        )
        let valid = MonitorSnapshot(
            timestamp: base,
            system: criticalSystem,
            systemStatus: .available(at: base),
            cpuTime: nil,
            cpuStatus: .unavailable(),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(),
            processes: [process],
            processStatus: .available(at: base),
            listedProcessCount: 1,
            sampledProcessCount: 1,
            groups: [group],
            samplingMode: .panel,
            diagnostics: SamplingDiagnostics(
                mode: .panel,
                totalDurationMilliseconds: 1,
                processDurationMilliseconds: 1,
                processSamplingPerformed: true,
                processCount: 1,
                listedProcessCount: 1
            )
        )
        let invalidSystem = MonitorSnapshot(
            timestamp: base.addingTimeInterval(3),
            // The non-positive total makes this system value unusable while
            // the process result remains a valid, fresh sample.
            system: SystemMemorySnapshot(
                timestamp: base.addingTimeInterval(3),
                totalBytes: 0,
                pageSize: 1,
                freeBytes: 0,
                activeBytes: 0,
                inactiveBytes: 0,
                speculativeBytes: 0,
                wiredBytes: 0,
                purgeableBytes: 0,
                compressedBytes: 0,
                throttledPages: 0,
                swapTotalBytes: 0,
                swapUsedBytes: 0,
                swapFreeBytes: 0
            ),
            systemStatus: .available(at: base.addingTimeInterval(3)),
            cpuTime: nil,
            cpuStatus: .unavailable(),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(),
            processes: [process],
            processStatus: .available(at: base.addingTimeInterval(3)),
            listedProcessCount: 1,
            sampledProcessCount: 1,
            groups: [group],
            samplingMode: .panel,
            diagnostics: valid.diagnostics
        )
        let source = FakeMonitorSamplingSource(snapshots: [valid, invalidSystem])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: base)
        let recommendationBefore = try XCTUnwrap(model.recommendation)
        await model.refreshOnce(at: base.addingTimeInterval(3))

        XCTAssertEqual(model.recommendation, recommendationBefore)
        XCTAssertFalse(model.systemDataIsUsable)
        XCTAssertEqual(model.processes, [process])
    }

    func testMonitorViewModelStartsNewClockEpochAndRejectsOlderInFlightPass() async throws {
        let base = Date(timeIntervalSince1970: 1_700_400_000)
        let preRollback = base.addingTimeInterval(60)
        let afterRollback = base.addingTimeInterval(-3_600)
        let initialProcess = makeProcess(pid: 9050, name: "initial")
        let staleProcess = makeProcess(pid: 9051, name: "stale")
        let recoveredProcess = makeProcess(pid: 9052, name: "recovered")
        let source = SecondPassBlockingMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [initialProcess],
                groups: [makeGroup(id: "initial", title: "Initial", process: initialProcess)],
                status: .available(at: base),
                listedCount: 1,
                cpuTime: CPUTimeSnapshot(userTicks: 100, systemTicks: 0, idleTicks: 100, niceTicks: 0)
            ),
            makeMonitorSnapshot(
                timestamp: preRollback,
                processes: [staleProcess],
                groups: [makeGroup(id: "stale", title: "Stale", process: staleProcess)],
                status: .available(at: preRollback),
                listedCount: 1,
                cpuTime: CPUTimeSnapshot(userTicks: 200, systemTicks: 0, idleTicks: 200, niceTicks: 0)
            ),
            makeMonitorSnapshot(
                timestamp: afterRollback,
                processes: [recoveredProcess],
                groups: [makeGroup(id: "recovered", title: "Recovered", process: recoveredProcess)],
                status: .available(at: afterRollback),
                listedCount: 1,
                cpuTime: CPUTimeSnapshot(userTicks: 300, systemTicks: 0, idleTicks: 300, niceTicks: 0)
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: base)
        let staleTask = Task { await model.refreshOnce(at: preRollback) }
        await waitUntil { source.requestedTimestamps.count == 2 }
        let recoveredTask = Task { await model.refreshOnce(at: afterRollback) }
        for _ in 0..<20 { await Task.yield() }
        source.releaseSecond()

        await staleTask.value
        await recoveredTask.value

        XCTAssertEqual(source.requestedTimestamps, [base, preRollback, afterRollback])
        XCTAssertEqual(model.updatedAt, afterRollback)
        XCTAssertEqual(model.processes, [recoveredProcess])
        XCTAssertNil(model.cpuUsageFraction)
    }

    func testMonitorViewModelUpdatesSameIDRecommendationWhenEvidenceEscalates() async throws {
        let base = Date(timeIntervalSince1970: 1_700_500_000)
        let secondTimestamp = base.addingTimeInterval(60)
        let thirdTimestamp = base.addingTimeInterval(120)
        let firstProcess = makeProcess(pid: 9060, name: "node", footprint: 100 * 1024 * 1024)
        let secondProcess = makeProcess(pid: 9060, name: "node", footprint: 200 * 1024 * 1024)
        let thirdProcess = makeProcess(pid: 9060, name: "node", footprint: 300 * 1024 * 1024)
        let snapshots = [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [firstProcess],
                groups: [makeGroup(id: "runtime-node-api", title: "Node · api", process: firstProcess)],
                status: .available(at: base),
                listedCount: 1
            ),
            makeMonitorSnapshot(
                timestamp: secondTimestamp,
                processes: [secondProcess],
                groups: [makeGroup(id: "runtime-node-api", title: "Node · api", process: secondProcess)],
                status: .available(at: secondTimestamp),
                listedCount: 1
            ),
            makeMonitorSnapshot(
                timestamp: thirdTimestamp,
                processes: [thirdProcess],
                groups: [makeGroup(id: "runtime-node-api", title: "Node · api", process: thirdProcess)],
                status: .available(at: thirdTimestamp),
                listedCount: 1,
                systemOverride: makeSystemSnapshot(
                    timestamp: thirdTimestamp,
                    swapUsedBytes: 128 * 1024 * 1024
                )
            )
        ]
        let source = FakeMonitorSamplingSource(snapshots: snapshots)
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: base)
        await model.refreshOnce(at: secondTimestamp)
        XCTAssertEqual(model.recommendation?.severity, .info)
        let previousGeneratedAt = model.recommendation?.generatedAt

        await model.refreshOnce(at: thirdTimestamp)

        XCTAssertEqual(model.recommendation?.id, "growth-runtime-node-api")
        XCTAssertEqual(model.recommendation?.severity, .attention)
        XCTAssertEqual(model.recommendation?.generatedAt, thirdTimestamp)
        XCTAssertNotEqual(model.recommendation?.generatedAt, previousGeneratedAt)
        XCTAssertTrue(model.recommendation?.evidence.contains {
            $0.label == "Swap 增量"
        } == true)
    }

    func testMonitorViewModelRefreshesRecommendationConfirmationWithoutRepublishing() async throws {
        let base = Date(timeIntervalSince1970: 1_700_510_000)
        let publishedAt = base.addingTimeInterval(60)
        let confirmedAt = base.addingTimeInterval(120)
        let process = makeProcess(
            pid: 9061,
            name: "critical-worker",
            footprint: 4 * 1024 * 1024 * 1024
        )
        let group = makeGroup(
            id: "critical-worker",
            title: "Critical Worker",
            process: process,
            footprint: process.physicalFootprintBytes
        )
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [process],
                groups: [group],
                status: .available(at: base),
                listedCount: 1,
                systemOverride: makePressureSystemSnapshot(
                    timestamp: base,
                    availableFraction: 0.05,
                    swapUsedBytes: 0
                )
            ),
            makeMonitorSnapshot(
                timestamp: publishedAt,
                processes: [process],
                groups: [group],
                status: .available(at: publishedAt),
                listedCount: 1,
                systemOverride: makePressureSystemSnapshot(
                    timestamp: publishedAt,
                    availableFraction: 0.05,
                    swapUsedBytes: 0
                )
            ),
            makeMonitorSnapshot(
                timestamp: confirmedAt,
                processes: [process],
                groups: [group],
                status: .available(at: confirmedAt),
                listedCount: 1,
                systemOverride: makePressureSystemSnapshot(
                    timestamp: confirmedAt,
                    availableFraction: 0.05,
                    swapUsedBytes: 0
                )
            )
        ])
        let paths = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: paths.url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: base)
        await model.refreshOnce(at: publishedAt)
        let first = try XCTUnwrap(model.recommendation)
        await model.refreshOnce(at: confirmedAt)
        let refreshed = try XCTUnwrap(model.recommendation)

        XCTAssertEqual(first.requiredSources, [.system, .processes])
        XCTAssertEqual(refreshed.generatedAt, first.generatedAt)
        XCTAssertEqual(refreshed.lastConfirmedAt, confirmedAt)
    }

    func testMonitorViewModelExpiresRecommendationWhenRequiredSourcesStayUnavailable() async throws {
        let base = Date(timeIntervalSince1970: 1_700_520_000)
        let withinTTL = base.addingTimeInterval(20)
        let expired = base.addingTimeInterval(31)
        let process = makeProcess(
            pid: 9062,
            name: "critical-worker",
            footprint: 4 * 1024 * 1024 * 1024
        )
        let group = makeGroup(
            id: "critical-worker",
            title: "Critical Worker",
            process: process,
            footprint: process.physicalFootprintBytes
        )
        func unavailableSnapshot(at timestamp: Date) -> MonitorSnapshot {
            MonitorSnapshot(
                timestamp: timestamp,
                system: nil,
                systemStatus: .error("system unavailable"),
                cpuTime: nil,
                cpuStatus: .unavailable(),
                gpuUsageFraction: nil,
                gpuStatus: .unavailable(),
                processes: [],
                processStatus: .error("processes unavailable"),
                listedProcessCount: 0,
                sampledProcessCount: 0,
                groups: [],
                samplingMode: .panel
            )
        }
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [process],
                groups: [group],
                status: .available(at: base),
                listedCount: 1,
                systemOverride: makePressureSystemSnapshot(
                    timestamp: base,
                    availableFraction: 0.05,
                    swapUsedBytes: 0
                )
            ),
            unavailableSnapshot(at: withinTTL),
            unavailableSnapshot(at: expired)
        ])
        let paths = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: paths.url),
            recommendationTTL: 30,
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: base)
        XCTAssertNotNil(model.recommendation)
        await model.refreshOnce(at: withinTTL)
        XCTAssertNotNil(model.recommendation)
        await model.refreshOnce(at: expired)
        XCTAssertNil(model.recommendation)
    }

    func testMonitorViewModelDoesNotConfirmRecommendationFromRolledBackProcessSource() async throws {
        let base = Date(timeIntervalSince1970: 1_700_530_000)
        let rolledBackPass = base.addingTimeInterval(60)
        let process = makeProcess(
            pid: 9063,
            name: "critical-worker",
            footprint: 4 * 1024 * 1024 * 1024
        )
        let group = makeGroup(
            id: "critical-worker",
            title: "Critical Worker",
            process: process,
            footprint: process.physicalFootprintBytes
        )
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [process],
                groups: [group],
                status: .available(at: base),
                listedCount: 1,
                systemOverride: makePressureSystemSnapshot(
                    timestamp: base,
                    availableFraction: 0.05,
                    swapUsedBytes: 0
                )
            ),
            makeMonitorSnapshot(
                timestamp: rolledBackPass,
                processes: [process],
                groups: [group],
                status: .available(at: base.addingTimeInterval(-1)),
                listedCount: 1,
                systemOverride: makePressureSystemSnapshot(
                    timestamp: rolledBackPass,
                    availableFraction: 0.05,
                    swapUsedBytes: 0
                )
            )
        ])
        let paths = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: paths.url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: base)
        let first = try XCTUnwrap(model.recommendation)
        await model.refreshOnce(at: rolledBackPass)
        let retained = try XCTUnwrap(model.recommendation)

        XCTAssertEqual(retained.generatedAt, first.generatedAt)
        XCTAssertEqual(retained.lastConfirmedAt, first.lastConfirmedAt)
    }

    func testMonitorViewModelAdvancesProcessBaselineWhenSystemSampleFails() async throws {
        let base = Date(timeIntervalSince1970: 1_700_600_000)
        let secondTimestamp = base.addingTimeInterval(60)
        let thirdTimestamp = base.addingTimeInterval(120)
        let firstProcess = makeProcess(pid: 9070, name: "worker", footprint: 100 * 1024 * 1024)
        let secondProcess = makeProcess(pid: 9070, name: "worker", footprint: 200 * 1024 * 1024)
        let thirdProcess = makeProcess(pid: 9070, name: "worker", footprint: 205 * 1024 * 1024)
        let invalidSystem = SystemMemorySnapshot(
            timestamp: secondTimestamp,
            totalBytes: 0,
            pageSize: 1,
            freeBytes: 0,
            activeBytes: 0,
            inactiveBytes: 0,
            speculativeBytes: 0,
            wiredBytes: 0,
            purgeableBytes: 0,
            compressedBytes: 0,
            throttledPages: 0,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            swapFreeBytes: 0
        )
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [firstProcess],
                groups: [makeGroup(id: "worker", title: "Worker", process: firstProcess)],
                status: .available(at: base),
                listedCount: 1
            ),
            makeMonitorSnapshot(
                timestamp: secondTimestamp,
                processes: [secondProcess],
                groups: [makeGroup(id: "worker", title: "Worker", process: secondProcess)],
                status: .available(at: secondTimestamp),
                listedCount: 1,
                systemOverride: invalidSystem
            ),
            makeMonitorSnapshot(
                timestamp: thirdTimestamp,
                processes: [thirdProcess],
                groups: [makeGroup(id: "worker", title: "Worker", process: thirdProcess)],
                status: .available(at: thirdTimestamp),
                listedCount: 1
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )
        model.setPanelPresented(true)

        await model.refreshOnce(at: base)
        await model.refreshOnce(at: secondTimestamp)
        XCTAssertEqual(model.recommendation?.id, "growth-worker")

        await model.refreshOnce(at: thirdTimestamp)

        XCTAssertNil(model.recommendation)
        XCTAssertEqual(model.processes, [thirdProcess])
    }

    func testMonitorViewModelRecoveryUsesSystemPairedWithStablePressure() async throws {
        let base = Date(timeIntervalSince1970: 1_700_700_000)
        let pendingTimestamp = base.addingTimeInterval(10)
        let recoveredTimestamp = base.addingTimeInterval(40)
        let critical = makePressureSystemSnapshot(
            timestamp: base,
            availableFraction: 0.05,
            swapUsedBytes: 5 * 1024 * 1024 * 1024
        )
        let pending = makePressureSystemSnapshot(
            timestamp: pendingTimestamp,
            availableFraction: 0.30,
            swapUsedBytes: 4 * 1024 * 1024 * 1024
        )
        let recovered = makePressureSystemSnapshot(
            timestamp: recoveredTimestamp,
            availableFraction: 0.30,
            swapUsedBytes: 4 * 1024 * 1024 * 1024
        )
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                systemOverride: critical,
                didSampleProcesses: false
            ),
            makeMonitorSnapshot(
                timestamp: pendingTimestamp,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                systemOverride: pending,
                didSampleProcesses: false
            ),
            makeMonitorSnapshot(
                timestamp: recoveredTimestamp,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                systemOverride: recovered,
                didSampleProcesses: false
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )

        await model.refreshOnce(at: base)
        XCTAssertEqual(model.pressureLevel, .critical)
        await model.refreshOnce(at: pendingTimestamp)
        XCTAssertEqual(model.pressureLevel, .critical)
        await model.refreshOnce(at: recoveredTimestamp)

        XCTAssertEqual(model.pressureLevel, .normal)
        XCTAssertEqual(model.recommendation?.id, "recovery-swap")
    }

    func testMonitorViewModelSystemFailureInterruptsPendingPressureTransition() async throws {
        let base = Date(timeIntervalSince1970: 1_700_710_000)
        let pendingAt = base.addingTimeInterval(20)
        let failedAt = base.addingTimeInterval(40)
        let retriedAt = base.addingTimeInterval(50)
        let critical = makePressureSystemSnapshot(
            timestamp: base,
            availableFraction: 0.05,
            swapUsedBytes: 5 * 1024 * 1024 * 1024
        )
        let normalPending = makePressureSystemSnapshot(
            timestamp: pendingAt,
            availableFraction: 0.30,
            swapUsedBytes: 0
        )
        let normalRetry = makePressureSystemSnapshot(
            timestamp: retriedAt,
            availableFraction: 0.30,
            swapUsedBytes: 0
        )
        let source = FakeMonitorSamplingSource(snapshots: [
            makeMonitorSnapshot(
                timestamp: base,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                systemOverride: critical,
                didSampleProcesses: false
            ),
            makeMonitorSnapshot(
                timestamp: pendingAt,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                systemOverride: normalPending,
                didSampleProcesses: false
            ),
            MonitorSnapshot(
                timestamp: failedAt,
                system: nil,
                systemStatus: .error("provider failed"),
                cpuTime: nil,
                cpuStatus: .unavailable(),
                gpuUsageFraction: nil,
                gpuStatus: .unavailable(),
                processes: [],
                processStatus: .unavailable(),
                listedProcessCount: 0,
                sampledProcessCount: 0,
                groups: [],
                samplingMode: .background
            ),
            makeMonitorSnapshot(
                timestamp: retriedAt,
                processes: [],
                groups: [],
                status: .unavailable(),
                listedCount: 0,
                systemOverride: normalRetry,
                didSampleProcesses: false
            )
        ])
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MonitorViewModel(
            sampler: source,
            historyStore: HistoryStore(fileURL: url),
            startRefreshTask: false
        )

        await model.refreshOnce(at: base)
        await model.refreshOnce(at: pendingAt)
        XCTAssertEqual(model.pressureLevel, .critical)
        await model.refreshOnce(at: failedAt)
        await model.refreshOnce(at: retriedAt)

        XCTAssertEqual(model.pressureLevel, .critical)
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
        let intent = ProcessActionAuditEvent(
            id: "intent",
            operationID: "operation-1",
            timestamp: now.addingTimeInterval(-20),
            action: .gracefulExit,
            phase: .intent,
            outcome: .completed,
            processLabel: "Node Worker",
            detail: "用户已确认操作"
        )
        let sent = ProcessActionAuditEvent(
            id: "sent",
            operationID: "operation-1",
            timestamp: now.addingTimeInterval(-10),
            action: .gracefulExit,
            phase: .signalSent,
            outcome: .completed,
            processLabel: "Node Worker",
            detail: "已发送优雅退出请求"
        )

        let attention = AuditEventFiltering.apply(
            events: [completed, failed],
            filter: .attention,
            query: "chrome"
        )
        XCTAssertEqual(attention.map(\.id), ["failed"])

        let inFlight = AuditEventFiltering.apply(
            events: [completed, intent, sent],
            filter: .completed,
            query: ""
        )
        XCTAssertEqual(inFlight.map(\.id), ["completed"])

        let allStages = AuditEventFiltering.apply(
            events: [completed, intent, sent],
            filter: .all,
            query: ""
        )
        XCTAssertEqual(allStages.map(\.statusDisplayName), ["已发送", "已确认", "已完成"])

        let attentionStages = AuditEventFiltering.apply(
            events: [completed, intent, sent],
            filter: .attention,
            query: ""
        )
        XCTAssertTrue(attentionStages.isEmpty)

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
        runtimeEnvironment: RuntimeEnvironmentStatus? = nil,
        samplingDurationMilliseconds: Double = 90,
        processDurationMilliseconds: Double? = 80,
        now: Date? = nil
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
            runtimeEnvironment: runtimeEnvironment,
            checkedAt: Date(timeIntervalSince1970: 100),
            now: now
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

    private func makeTemporaryHistoryURL() -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMonitorViewModel-" + UUID().uuidString, isDirectory: true)
        return (directory.appendingPathComponent("history.json"), directory)
    }

    private func makeTemporaryActionURL() -> (url: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMonitorShutdownAudit-" + UUID().uuidString, isDirectory: true)
        return (directory.appendingPathComponent("actions.jsonl"), directory)
    }

    private func makeSystemSnapshot(
        timestamp: Date,
        swapUsedBytes: UInt64 = 0
    ) -> SystemMemorySnapshot {
        let swapTotalBytes: UInt64 = 2_000_000_000
        return SystemMemorySnapshot(
            timestamp: timestamp,
            totalBytes: 1_000,
            pageSize: 1,
            freeBytes: 300,
            activeBytes: 400,
            inactiveBytes: 100,
            speculativeBytes: 0,
            wiredBytes: 100,
            purgeableBytes: 100,
            compressedBytes: 0,
            throttledPages: 0,
            swapTotalBytes: swapTotalBytes,
            swapUsedBytes: min(swapUsedBytes, swapTotalBytes),
            swapFreeBytes: swapTotalBytes - min(swapUsedBytes, swapTotalBytes)
        )
    }

    private func makePressureSystemSnapshot(
        timestamp: Date,
        availableFraction: Double,
        swapUsedBytes: UInt64
    ) -> SystemMemorySnapshot {
        let totalBytes: UInt64 = 16 * 1024 * 1024 * 1024
        let swapTotalBytes: UInt64 = 8 * 1024 * 1024 * 1024
        let freeBytes = UInt64(Double(totalBytes) * availableFraction)
        let normalizedSwapUsed = min(swapUsedBytes, swapTotalBytes)
        return SystemMemorySnapshot(
            timestamp: timestamp,
            totalBytes: totalBytes,
            pageSize: 4096,
            freeBytes: freeBytes,
            activeBytes: totalBytes - freeBytes,
            inactiveBytes: 0,
            speculativeBytes: 0,
            wiredBytes: 0,
            purgeableBytes: 0,
            compressedBytes: 0,
            throttledPages: 0,
            swapTotalBytes: swapTotalBytes,
            swapUsedBytes: normalizedSwapUsed,
            swapFreeBytes: swapTotalBytes - normalizedSwapUsed
        )
    }

    private func makeProcess(
        pid: Int32,
        name: String,
        footprint: UInt64 = 200
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 1, startTimeMicroseconds: UInt64(pid)),
            parentPID: 1,
            userID: 501,
            isSystem: false,
            name: name,
            executablePath: "/Users/test/bin/" + name,
            residentBytes: min(footprint, 100),
            physicalFootprintBytes: footprint,
            virtualBytes: 300,
            userTimeNanos: 0,
            systemTimeNanos: 0,
            threadCount: 1
        )
    }

    private func makeGroup(
        id: String,
        title: String,
        process: ProcessSnapshot,
        footprint: UInt64? = nil
    ) -> WorkloadGroupSnapshot {
        WorkloadGroupSnapshot(
            id: id,
            title: title,
            processCount: 1,
            physicalFootprintBytes: footprint ?? process.physicalFootprintBytes,
            residentBytes: process.residentBytes,
            isSystem: false,
            representativeProcess: process.name,
            memberProcessIdentities: [process.identity]
        )
    }

    private func makeMonitorSnapshot(
        timestamp: Date,
        processes: [ProcessSnapshot],
        groups: [WorkloadGroupSnapshot],
        status: SampleStatus,
        listedCount: Int,
        cpuTime: CPUTimeSnapshot? = nil,
        systemOverride: SystemMemorySnapshot? = nil,
        didSampleProcesses: Bool = true
    ) -> MonitorSnapshot {
        let system = systemOverride ?? makeSystemSnapshot(timestamp: timestamp)
        return MonitorSnapshot(
            timestamp: timestamp,
            system: system,
            systemStatus: .estimated(at: system.timestamp),
            cpuTime: cpuTime,
            cpuStatus: cpuTime.map { _ in .available(at: timestamp) } ?? .unavailable(),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(),
            processes: processes,
            processStatus: status,
            listedProcessCount: listedCount,
            sampledProcessCount: processes.count,
            groups: groups,
            samplingMode: didSampleProcesses ? .panel : .background,
            diagnostics: SamplingDiagnostics(
                mode: didSampleProcesses ? .panel : .background,
                totalDurationMilliseconds: 1,
                processDurationMilliseconds: didSampleProcesses ? 1 : nil,
                processSamplingPerformed: didSampleProcesses,
                processCount: processes.count,
                listedProcessCount: listedCount
            )
        )
    }
}

@MainActor
private final class MutableDateProvider {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

@MainActor
private final class TimestampedMonitorSamplingSource: MonitorSamplingSource {
    private let snapshots: [Date: MonitorSnapshot]

    init(snapshots: [Date: MonitorSnapshot]) {
        self.snapshots = snapshots
    }

    func sample(mode: SamplingMode, at timestamp: Date) async -> MonitorSnapshot {
        snapshots[timestamp] ?? MonitorSnapshot(
            timestamp: timestamp,
            system: nil,
            systemStatus: .error("missing test snapshot"),
            cpuTime: nil,
            cpuStatus: .unavailable(),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(),
            processes: [],
            processStatus: .error("missing test snapshot"),
            listedProcessCount: 0,
            sampledProcessCount: 0,
            groups: [],
            samplingMode: mode
        )
    }
}

@MainActor
private final class FakeMonitorSamplingSource: MonitorSamplingSource {
    private var snapshots: [MonitorSnapshot]
    private(set) var requestedModes: [SamplingMode] = []

    init(snapshots: [MonitorSnapshot]) {
        self.snapshots = snapshots
    }

    func sample(mode: SamplingMode, at timestamp: Date) async -> MonitorSnapshot {
        requestedModes.append(mode)
        if snapshots.count > 1 {
            return snapshots.removeFirst()
        }
        return snapshots[0]
    }
}

@MainActor
private final class BlockingMonitorSamplingSource: MonitorSamplingSource {
    private var snapshots: [MonitorSnapshot]
    private var firstRelease: CheckedContinuation<Void, Never>?
    private(set) var requestedTimestamps: [Date] = []

    init(snapshots: [MonitorSnapshot]) {
        self.snapshots = snapshots
    }

    func sample(mode: SamplingMode, at timestamp: Date) async -> MonitorSnapshot {
        let index = requestedTimestamps.count
        requestedTimestamps.append(timestamp)
        if index == 0 {
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
        }
        return snapshots[min(index, snapshots.count - 1)]
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }
}

@MainActor
private final class SecondPassBlockingMonitorSamplingSource: MonitorSamplingSource {
    private let snapshots: [MonitorSnapshot]
    private var secondRelease: CheckedContinuation<Void, Never>?
    private(set) var requestedTimestamps: [Date] = []

    init(snapshots: [MonitorSnapshot]) {
        self.snapshots = snapshots
    }

    func sample(mode: SamplingMode, at timestamp: Date) async -> MonitorSnapshot {
        let index = requestedTimestamps.count
        requestedTimestamps.append(timestamp)
        if index == 1 {
            await withCheckedContinuation { continuation in
                secondRelease = continuation
            }
        }
        return snapshots[min(index, snapshots.count - 1)]
    }

    func releaseSecond() {
        secondRelease?.resume()
        secondRelease = nil
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

@MainActor
private final class BlockingLoginLaunchRuntime: LoginLaunchRuntime {
    var statusValue: LoginLaunchStatus = .notRegistered
    private(set) var registerStarted = false

    func status() -> LoginLaunchStatus { statusValue }

    func register() async throws {
        registerStarted = true
        try await Task.sleep(for: .seconds(3_600))
        statusValue = .enabled
    }

    func unregister() async throws {
        try await Task.sleep(for: .seconds(3_600))
        statusValue = .notRegistered
    }

    func openSystemSettings() {}
}

@MainActor
private final class LateCompletingLoginLaunchRuntime: LoginLaunchRuntime {
    var statusValue: LoginLaunchStatus = .notRegistered
    private(set) var registerStarted = false
    private var registerContinuation: CheckedContinuation<Void, Never>?

    func status() -> LoginLaunchStatus { statusValue }

    func register() async throws {
        registerStarted = true
        await withCheckedContinuation { continuation in
            registerContinuation = continuation
        }
        statusValue = .enabled
    }

    func unregister() async throws {
        statusValue = .notRegistered
    }

    func completeRegister() {
        registerContinuation?.resume()
        registerContinuation = nil
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
