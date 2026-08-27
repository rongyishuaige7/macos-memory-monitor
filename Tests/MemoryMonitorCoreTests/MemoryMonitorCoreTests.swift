import XCTest
@testable import MemoryMonitorCore

final class MemoryMonitorCoreTests: XCTestCase {
    private enum TestSamplingError: Error {
        case denied
        case unavailable
    }

    func testByteFormatting() {
        XCTAssertEqual(MemoryFormatter.bytes(0), "0 B")
        XCTAssertEqual(MemoryFormatter.bytes(1024), "1.0 KiB")
        XCTAssertEqual(MemoryFormatter.bytes(1024 * 1024), "1.0 MiB")
    }

    func testSystemSamplerReturnsCurrentMachineData() throws {
        let snapshot = try SystemMemorySampler().sample()
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertGreaterThan(snapshot.pageSize, 0)
        XCTAssertGreaterThanOrEqual(snapshot.availableEstimateBytes, snapshot.freeBytes)
        XCTAssertTrue(snapshot.isStructurallyValid)
    }

    func testSampleStatusReportsAgeOnlyForCapturedValues() {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let available = SampleStatus.available(at: capturedAt)
        XCTAssertEqual(
            try XCTUnwrap(available.sampleAge(at: capturedAt.addingTimeInterval(12))),
            12,
            accuracy: 0.001
        )

        let unavailable = SampleStatus.unavailable(message: "没有驱动数据")
        XCTAssertNil(unavailable.sampleAge(at: capturedAt.addingTimeInterval(12)))
        XCTAssertEqual(unavailable.quality, .unavailable)
    }

    func testAvailableEstimateDoesNotDoubleCountSpeculativePages() {
        let snapshot = SystemMemorySnapshot(
            totalBytes: 100,
            pageSize: 1,
            freeBytes: 10,
            activeBytes: 40,
            inactiveBytes: 20,
            speculativeBytes: 50,
            wiredBytes: 30,
            purgeableBytes: 5,
            compressedBytes: 0,
            throttledPages: 0,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            swapFreeBytes: 0
        )

        XCTAssertEqual(snapshot.availableEstimateBytes, 35)
        XCTAssertEqual(snapshot.availableFraction, 0.35, accuracy: 0.0001)
    }

    func testAvailableFractionIsClampedToUnitInterval() {
        let snapshot = SystemMemorySnapshot(
            totalBytes: 10,
            pageSize: 1,
            freeBytes: 100,
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

        XCTAssertEqual(snapshot.availableEstimateBytes, 10)
        XCTAssertEqual(snapshot.availableFraction, 1)
        XCTAssertEqual(snapshot.usedFraction, 0)
    }

    func testCPUUsageCalculatorComputesDeltaFraction() {
        let previous = CPUTimeSnapshot(userTicks: 100, systemTicks: 50, idleTicks: 850, niceTicks: 0)
        let current = CPUTimeSnapshot(userTicks: 200, systemTicks: 100, idleTicks: 950, niceTicks: 0)

        let fraction = try! XCTUnwrap(
            CPUUsageCalculator.usedFraction(current: current, previous: previous)
        )
        XCTAssertEqual(fraction, 0.6, accuracy: 0.0001)
    }

    func testCPUUsageCalculatorRejectsCounterReset() {
        let previous = CPUTimeSnapshot(userTicks: 100, systemTicks: 50, idleTicks: 850, niceTicks: 0)
        let current = CPUTimeSnapshot(userTicks: 10, systemTicks: 5, idleTicks: 20, niceTicks: 0)

        XCTAssertNil(CPUUsageCalculator.usedFraction(current: current, previous: previous))
    }

    func testCPUTimeSnapshotSaturatesCounterSums() {
        let snapshot = CPUTimeSnapshot(
            userTicks: UInt64.max,
            systemTicks: UInt64.max,
            idleTicks: UInt64.max,
            niceTicks: UInt64.max
        )

        XCTAssertEqual(snapshot.activeTicks, UInt64.max)
        XCTAssertEqual(snapshot.totalTicks, UInt64.max)
    }

    func testCPUTimeSamplerReturnsNonZeroCounters() throws {
        let snapshot = try CPUTimeSampler().sample()

        XCTAssertGreaterThan(snapshot.totalTicks, 0)
        XCTAssertGreaterThanOrEqual(snapshot.totalTicks, snapshot.activeTicks)
    }

    func testGPUUsageSamplerReturnsBoundedValueWhenAvailable() {
        guard let value = GPUUsageSampler().sample() else { return }

        XCTAssertGreaterThanOrEqual(value, 0)
        XCTAssertLessThanOrEqual(value, 1)
    }

    func testMonitorSamplerKeepsIndependentSourcesWhenProcessSamplingFails() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let system = makeSystemSnapshot(timestamp: timestamp, compressed: 10, swap: 20)
        let sampler = MonitorSampler(
            systemSampler: { system },
            cpuSampler: { CPUTimeSnapshot(userTicks: 10, systemTicks: 5, idleTicks: 85, niceTicks: 0) },
            gpuSampler: {
                GPUUsageSample(
                    fraction: 0.25,
                    status: .available(at: timestamp)
                )
            },
            processSampler: { throw TestSamplingError.denied }
        )

        let snapshot = sampler.sample(at: timestamp)

        XCTAssertEqual(snapshot.system, system)
        XCTAssertEqual(snapshot.systemStatus.quality, .estimated)
        XCTAssertEqual(snapshot.cpuStatus.quality, .available)
        XCTAssertEqual(snapshot.gpuUsageFraction, 0.25)
        XCTAssertEqual(snapshot.gpuStatus.quality, .available)
        XCTAssertTrue(snapshot.processes.isEmpty)
        XCTAssertEqual(snapshot.processStatus.quality, .error)
        XCTAssertEqual(snapshot.groups, [])
    }

    func testMonitorSamplerMarksInvalidSystemWithoutDiscardingProcesses() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let invalid = SystemMemorySnapshot(
            timestamp: timestamp,
            totalBytes: 0,
            pageSize: 0,
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
        let process = makeProcess(pid: 808, name: "worker", footprint: 100)
        let processResult = ProcessSamplingResult(
            processes: [process],
            listedProcessCount: 1,
            sampledProcessCount: 1,
            skippedProcessCount: 0,
            status: .available(at: timestamp)
        )
        let sampler = MonitorSampler(
            systemSampler: { invalid },
            cpuSampler: { throw TestSamplingError.unavailable },
            gpuSampler: {
                GPUUsageSample(
                    fraction: nil,
                    status: .unavailable(message: "驱动未提供")
                )
            },
            processSampler: { processResult }
        )

        let snapshot = sampler.sample(at: timestamp)

        XCTAssertNil(snapshot.system)
        XCTAssertEqual(snapshot.systemStatus.quality, .error)
        XCTAssertEqual(snapshot.cpuStatus.quality, .error)
        XCTAssertEqual(snapshot.gpuStatus.quality, .unavailable)
        XCTAssertEqual(snapshot.processes, [process])
        XCTAssertEqual(snapshot.processStatus.quality, .available)
    }

    func testMonitorSamplerSortsProcessResultsByStableMemoryOrdering() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let processes = [
            makeProcess(pid: 12, name: "same", footprint: 100),
            makeProcess(pid: 10, name: "same", footprint: 100),
            makeProcess(pid: 11, name: "larger-rss", footprint: 100)
        ].map { process in
            if process.identity.pid == 11 {
                return ProcessSnapshot(
                    identity: process.identity,
                    parentPID: process.parentPID,
                    userID: process.userID,
                    isSystem: process.isSystem,
                    name: process.name,
                    executablePath: process.executablePath,
                    residentBytes: 200,
                    physicalFootprintBytes: process.physicalFootprintBytes,
                    virtualBytes: process.virtualBytes,
                    userTimeNanos: process.userTimeNanos,
                    systemTimeNanos: process.systemTimeNanos,
                    threadCount: process.threadCount
                )
            }
            return process
        }
        let result = ProcessSamplingResult(
            processes: processes,
            listedProcessCount: 3,
            sampledProcessCount: 3,
            skippedProcessCount: 0,
            status: .available(at: timestamp)
        )
        let system = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let sampler = MonitorSampler(
            systemSampler: { system },
            cpuSampler: { CPUTimeSnapshot(userTicks: 1, systemTicks: 1, idleTicks: 1, niceTicks: 0) },
            gpuSampler: {
                GPUUsageSample(fraction: nil, status: .unavailable())
            },
            processSampler: { result }
        )

        let snapshot = sampler.sample(at: timestamp)
        XCTAssertEqual(snapshot.processes.map { $0.identity.pid }, [11, 10, 12])
    }

    func testProcessSamplerFindsCurrentProcess() throws {
        let processes = try ProcessSampler().sample()
        XCTAssertFalse(processes.isEmpty)
        XCTAssertTrue(processes.contains { $0.identity.pid == getpid() })
    }

    func testWorkingDirectoryLabelSanitizerFiltersCommonRoots() {
        XCTAssertEqual(
            WorkingDirectoryLabelSanitizer.label(
                from: "/Users/foo/projects/api",
                homeDirectory: "/Users/foo"
            ),
            "api"
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/Users/foo",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/tmp/build",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/private/var/folders/xx/random",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertEqual(
            WorkingDirectoryLabelSanitizer.label(
                from: "/tmp2/project",
                homeDirectory: "/Users/foo"
            ),
            "project"
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "relative/project",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/Users/foo/project\u{0000}suffix",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/",
                homeDirectory: "/Users/foo"
            )
        )
    }

    func testWorkingDirectoryLabelSanitizerCleansComponentsAndIDs() {
        XCTAssertEqual(
            WorkingDirectoryLabelSanitizer.label(fromComponent: " api/\nworker "),
            "api-worker"
        )

        let longComponent = String(repeating: "x", count: 100)
        let limited = try! XCTUnwrap(
            WorkingDirectoryLabelSanitizer.label(fromComponent: longComponent)
        )
        XCTAssertEqual(limited.count, WorkingDirectoryLabelSanitizer.maxLength)
        XCTAssertFalse(limited.contains("\n"))

        let unicodeID = WorkingDirectoryLabelSanitizer.identifierComponent(for: "中文项目")
        let otherUnicodeID = WorkingDirectoryLabelSanitizer.identifierComponent(for: "另一个项目")
        XCTAssertNotEqual(unicodeID, otherUnicodeID)
        XCTAssertFalse(unicodeID.contains("/"))
    }

    func testProcessSnapshotCodableRetainsWorkingDirectoryLabel() throws {
        let process = makeProcess(pid: 9, name: "node", footprint: 100, workingDirectoryLabel: "api")
        let data = try JSONEncoder().encode(process)
        let decoded = try JSONDecoder().decode(ProcessSnapshot.self, from: data)
        XCTAssertEqual(decoded.workingDirectoryLabel, "api")

        let unsafe = makeProcess(
            pid: 10,
            name: "node",
            footprint: 100,
            workingDirectoryLabel: "/Users/foo/projects/api"
        )
        XCTAssertNil(unsafe.workingDirectoryLabel)
    }

    func testProcessSnapshotDecodingKeepsNewMetadataBackwardCompatibleAndSanitized() throws {
        let process = makeProcess(pid: 11, name: "worker", footprint: 100)
        let encoded = try JSONEncoder().encode(process)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "applicationName")
        object.removeValue(forKey: "bundleIdentifier")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let oldDecoded = try JSONDecoder().decode(ProcessSnapshot.self, from: oldData)
        XCTAssertNil(oldDecoded.applicationName)
        XCTAssertNil(oldDecoded.bundleIdentifier)

        object["applicationName"] = "Display\nName"
        object["bundleIdentifier"] = "com.example/app"
        let unsafeData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ProcessSnapshot.self, from: unsafeData)
        XCTAssertEqual(decoded.applicationName, "DisplayName")
        XCTAssertEqual(decoded.bundleIdentifier, "com.example-app")
    }

    func testApplicationIdentityResolverIgnoresNonAppExecutables() {
        XCTAssertNil(ApplicationIdentityResolver.resolve(executablePath: "/usr/bin/node"))
        let identity = ApplicationIdentity(name: "App/Name", bundleIdentifier: "com.example/app")
        XCTAssertEqual(identity.name, "App-Name")
        XCTAssertEqual(identity.bundleIdentifier, "com.example-app")
    }

    func testWorkloadGrouperAggregatesChromeHelpers() {
        let processes = [
            makeProcess(pid: 10, name: "Google Chrome", footprint: 500),
            makeProcess(pid: 11, name: "Google Chrome Helper (Renderer)", parentPID: 10, footprint: 700),
            makeProcess(pid: 12, name: "Google Chrome Helper (GPU)", parentPID: 10, footprint: 300)
        ]

        let groups = WorkloadGrouper().group(processes)
        let chrome = try! XCTUnwrap(groups.first { $0.id == "chrome" })
        XCTAssertEqual(chrome.title, "Chrome")
        XCTAssertEqual(chrome.processCount, 3)
        XCTAssertEqual(chrome.physicalFootprintBytes, 1_500)
        XCTAssertEqual(chrome.residentBytes, 1_500)
        XCTAssertEqual(chrome.attributionReason, .chromeIdentity)
    }

    func testWorkloadGrouperSortsGroupsByFootprintBeforeSystemPriority() {
        let processes = [
            makeProcess(pid: 13, name: "small-user", footprint: 100),
            makeProcess(pid: 14, name: "large-system", footprint: 1_000, isSystem: true),
            makeProcess(pid: 15, name: "medium-user", footprint: 500)
        ]

        let groups = WorkloadGrouper().group(processes)

        XCTAssertEqual(groups.map(\.physicalFootprintBytes), [1_000, 500, 100])
    }

    func testWorkloadGrouperUsesCodexAncestorForAutomation() {
        let processes = [
            makeProcess(pid: 20, name: "codex", footprint: 100),
            makeProcess(pid: 21, name: "node", parentPID: 20, footprint: 200, workingDirectoryLabel: "api"),
            makeProcess(pid: 22, name: "Google Chrome Helper", parentPID: 21, footprint: 300)
        ]

        let groups = WorkloadGrouper().group(processes)
        let automation = try! XCTUnwrap(groups.first { $0.id == "codex-automation" })
        XCTAssertEqual(automation.processCount, 2)
        XCTAssertEqual(automation.physicalFootprintBytes, 500)
        XCTAssertNil(groups.first { $0.id == "runtime-node-api" })
        XCTAssertEqual(groups.first { $0.id == "codex-session" }?.attributionReason, .codexSession)
    }

    func testWorkloadGrouperSeparatesGenericRuntimesByWorkingDirectory() {
        let processes = [
            makeProcess(pid: 40, name: "node", footprint: 100, workingDirectoryLabel: "api"),
            makeProcess(pid: 41, name: "node", footprint: 200, workingDirectoryLabel: "bot"),
            makeProcess(pid: 42, name: "python3", footprint: 300, workingDirectoryLabel: "bot")
        ]

        let groups = WorkloadGrouper().group(processes)
        XCTAssertEqual(
            Set(groups.map(\.id)),
            Set(["runtime-node-api", "runtime-node-bot", "runtime-python-bot"])
        )
        XCTAssertEqual(groups.first { $0.id == "runtime-node-api" }?.title, "Node · api")
        XCTAssertEqual(groups.first { $0.id == "runtime-python-bot" }?.title, "Python · bot")
    }

    func testWorkloadGrouperInheritsLabelFromRuntimeAncestor() {
        let processes = [
            makeProcess(pid: 50, name: "node", footprint: 100, workingDirectoryLabel: "api"),
            makeProcess(pid: 51, name: "node", parentPID: 50, footprint: 200),
            makeProcess(pid: 52, name: "python3", parentPID: 51, footprint: 300)
        ]

        let groups = WorkloadGrouper().group(processes)
        XCTAssertEqual(groups.first { $0.id == "runtime-node-api" }?.processCount, 2)
        XCTAssertEqual(groups.first { $0.id == "runtime-python-api" }?.processCount, 1)
    }

    func testWorkloadGrouperFallsBackWhenWorkingDirectoryIsUnavailable() {
        let processes = [
            makeProcess(pid: 60, name: "node", footprint: 100),
            makeProcess(pid: 61, name: "python3", footprint: 200)
        ]

        let groups = WorkloadGrouper().group(processes)
        XCTAssertEqual(groups.first { $0.id == "runtime-node" }?.title, "Node")
        XCTAssertEqual(groups.first { $0.id == "runtime-python" }?.title, "Python")
    }

    func testWorkloadGrouperDoesNotAssumeEveryWebKitProcessBelongsToSafari() {
        let processes = [
            makeProcess(pid: 30, name: "WebKit.Networking", footprint: 100),
            makeProcess(pid: 31, name: "Safari", footprint: 200),
            makeProcess(pid: 32, name: "com.apple.WebKit.WebContent", parentPID: 31, footprint: 300)
        ]

        let groups = WorkloadGrouper().group(processes)
        XCTAssertEqual(groups.first { $0.id == "unattributed-webkit" }?.processCount, 1)
        XCTAssertEqual(groups.first { $0.id == "safari-webkit" }?.processCount, 2)
        XCTAssertEqual(
            groups.first { $0.id == "unattributed-webkit" }?.attributionReason,
            .unattributedWebKit
        )
        XCTAssertEqual(
            groups.first { $0.id == "safari-webkit" }?.parentChain,
            ["Safari"]
        )
    }

    func testWorkloadGrouperStopsAtParentCycle() {
        let processes = [
            makeProcess(pid: 100, name: "node", parentPID: 101, footprint: 100, workingDirectoryLabel: "api"),
            makeProcess(pid: 101, name: "python3", parentPID: 100, footprint: 200)
        ]

        let groups = WorkloadGrouper().group(processes)

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.parentChain.count <= 2 })
    }

    func testWorkloadGrouperDoesNotFollowAmbiguousReusedPID() {
        let processes = [
            makeProcess(
                pid: 200,
                name: "codex",
                footprint: 100
            ),
            ProcessSnapshot(
                identity: ProcessIdentity(pid: 200, startTimeSeconds: 2, startTimeMicroseconds: 2),
                parentPID: 1,
                userID: 501,
                isSystem: false,
                name: "unrelated",
                executablePath: "/usr/bin/unrelated",
                residentBytes: 100,
                physicalFootprintBytes: 100,
                virtualBytes: 100,
                userTimeNanos: 0,
                systemTimeNanos: 0,
                threadCount: 1
            ),
            makeProcess(
                pid: 201,
                name: "Google Chrome Helper",
                parentPID: 200,
                footprint: 300
            )
        ]

        let groups = WorkloadGrouper().group(processes)

        XCTAssertNil(groups.first { $0.id == "codex-automation" })
        XCTAssertEqual(groups.first { $0.id == "chrome" }?.attributionReason, .chromeIdentity)
    }

    func testWorkloadTrendAnalyzerReportsExistingGrowingGroups() {
        let previous = [
            makeGroup(id: "chrome", title: "Chrome", footprint: 1_000),
            makeGroup(id: "stable", title: "Stable", footprint: 2_000)
        ]
        let current = [
            makeGroup(id: "chrome", title: "Chrome", footprint: 1_600),
            makeGroup(id: "stable", title: "Stable", footprint: 1_900),
            makeGroup(id: "new", title: "New", footprint: 4_000)
        ]

        let growth = WorkloadTrendAnalyzer().growingGroups(
            previous: previous,
            current: current,
            intervalSeconds: 5
        )

        XCTAssertEqual(growth.count, 1)
        XCTAssertEqual(growth.first?.id, "chrome")
        XCTAssertEqual(growth.first?.deltaBytes, 600)
        XCTAssertEqual(growth.first?.rateBytesPerSecond, 120)
    }

    func testWorkloadTrendAnalyzerRanksByGrowthRate() {
        let previous = [
            makeGroup(id: "large", title: "Large", footprint: 1_000),
            makeGroup(id: "fast", title: "Fast", footprint: 100)
        ]
        let current = [
            makeGroup(id: "large", title: "Large", footprint: 2_000),
            makeGroup(id: "fast", title: "Fast", footprint: 500)
        ]

        let growth = WorkloadTrendAnalyzer().growingGroups(
            previous: previous,
            current: current,
            intervalSeconds: 10
        )

        XCTAssertEqual(growth.map(\.id), ["large", "fast"])
    }

    func testAdaptiveSamplingPolicyThrottlesBackgroundProcessScans() {
        let policy = AdaptiveSamplingPolicy(
            backgroundIntervalSeconds: 20,
            panelIntervalSeconds: 3,
            pressureIntervalSeconds: 5,
            backgroundProcessIntervalSeconds: 60,
            pressureProcessIntervalSeconds: 10
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: false,
                now: start,
                lastProcessSampleAt: nil
            ),
            .backgroundProcess
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: false,
                now: start.addingTimeInterval(20),
                lastProcessSampleAt: start
            ),
            .background
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: false,
                now: start.addingTimeInterval(60),
                lastProcessSampleAt: start
            ),
            .backgroundProcess
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: true,
                pressureActive: false,
                now: start.addingTimeInterval(1),
                lastProcessSampleAt: start
            ),
            .panel
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: true,
                now: start.addingTimeInterval(1),
                lastProcessSampleAt: start
            ),
            .background
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: true,
                now: start.addingTimeInterval(10),
                lastProcessSampleAt: start
            ),
            .pressure
        )
        XCTAssertEqual(
            policy.cadenceDescription(panelPresented: false, pressureActive: true),
            "系统约 5 秒 · 进程约 10 秒"
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: false,
                now: start.addingTimeInterval(-1),
                lastProcessSampleAt: start
            ),
            .backgroundProcess
        )
    }

    func testMonitorSamplerSkipsProcessEnumerationInBackgroundMode() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let system = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let sampledProcess = makeProcess(pid: 900, name: "worker", footprint: 100)
        let sampler = MonitorSampler(
            systemSampler: { system },
            cpuSampler: { CPUTimeSnapshot(userTicks: 10, systemTicks: 5, idleTicks: 85, niceTicks: 0) },
            gpuSampler: { GPUUsageSample(fraction: nil, status: .unavailable()) },
            processSampler: {
                ProcessSamplingResult(
                    processes: [sampledProcess],
                    listedProcessCount: 1,
                    sampledProcessCount: 1,
                    skippedProcessCount: 0,
                    status: .available(at: timestamp)
                )
            }
        )

        let snapshot = sampler.sample(mode: .background, at: timestamp)

        XCTAssertFalse(snapshot.didSampleProcesses)
        XCTAssertEqual(snapshot.samplingMode, .background)
        XCTAssertEqual(snapshot.processStatus.quality, .unavailable)
        XCTAssertTrue(snapshot.processes.isEmpty)
        XCTAssertNil(snapshot.diagnostics.processDurationMilliseconds)
    }

    func testRecommendationEngineReportsGrowthWithSwapEvidence() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let previousTimestamp = timestamp.addingTimeInterval(-60)
        let previousSystem = makePressureSnapshot(
            timestamp: previousTimestamp,
            availableFraction: 0.25,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 5 * 1024 * 1024 * 1024
        )
        let currentSystem = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.15,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 4 * 1024 * 1024 * 1024
        )
        let previousGroup = makeGroup(id: "runtime-node-api", title: "Node · api", footprint: 500 * 1024 * 1024)
        let currentGroup = makeGroup(id: "runtime-node-api", title: "Node · api", footprint: 900 * 1024 * 1024)
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: currentSystem,
            groups: [currentGroup]
        )

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(
                current: current,
                previousSystem: previousSystem,
                previousGroups: [previousGroup],
                previousProcessStatus: .available(at: previousTimestamp)
            )
        )

        let growth = try! XCTUnwrap(recommendations.first { $0.id == "growth-runtime-node-api" })
        XCTAssertEqual(growth.severity, .attention)
        XCTAssertTrue(growth.evidence.contains { $0.label == "Swap 增量" })
        XCTAssertEqual(growth.targetGroupID, "runtime-node-api")
        XCTAssertEqual(growth.title, "Node · api 正在增长")
        XCTAssertTrue(growth.evidence.contains { $0.label == "速度" && $0.value.contains("/分钟") })
    }

    func testRecommendationEngineUsesProcessSampleBaselineForGrowthInterval() {
        let firstProcessTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let latestTimestamp = firstProcessTimestamp.addingTimeInterval(60)
        let previousProcessSystem = makeSystemSnapshot(
            timestamp: firstProcessTimestamp,
            compressed: 0,
            swap: 0
        )
        let interveningSystem = makeSystemSnapshot(
            timestamp: latestTimestamp.addingTimeInterval(-1),
            compressed: 0,
            swap: 0
        )
        let currentSystem = makeSystemSnapshot(
            timestamp: latestTimestamp,
            compressed: 0,
            swap: 0
        )
        let currentGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 900 * 1024 * 1024
        )
        let previousGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 500 * 1024 * 1024
        )
        let current = makeMonitorSnapshot(
            timestamp: latestTimestamp,
            system: currentSystem,
            groups: [currentGroup]
        )

        let recommendation = try! XCTUnwrap(
            RecommendationEngine().evaluate(
                RecommendationContext(
                    current: current,
                    previousSystem: interveningSystem,
                    previousProcessSystem: previousProcessSystem,
                    previousGroups: [previousGroup],
                    previousProcessStatus: .available(at: firstProcessTimestamp)
                )
            ).first { $0.id == "growth-runtime-node-api" }
        )

        XCTAssertTrue(recommendation.evidence.contains { $0.value == "400.0 MiB/分钟" })
    }

    func testRecommendationEnginePrioritizesLargeUserGroupDuringCriticalPressure() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let system = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.05,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )
        let group = makeGroup(
            id: "chrome",
            title: "Chrome",
            footprint: 3 * 1024 * 1024 * 1024
        )
        let current = makeMonitorSnapshot(timestamp: timestamp, system: system, groups: [group])

        let recommendation = try! XCTUnwrap(
            RecommendationEngine().evaluate(RecommendationContext(current: current)).first
        )

        XCTAssertEqual(recommendation.id, "critical-group-chrome")
        XCTAssertEqual(recommendation.severity, .critical)
        XCTAssertEqual(recommendation.targetGroupID, "chrome")
        XCTAssertEqual(recommendation.title, "优先检查 Chrome")
    }

    func testRecommendationEngineUsesDebouncedPressureLevelWhenProvided() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let system = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.05,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )
        let group = makeGroup(id: "chrome", title: "Chrome", footprint: 3 * 1024 * 1024 * 1024)
        let current = makeMonitorSnapshot(timestamp: timestamp, system: system, groups: [group])

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(current: current, pressureLevel: .normal)
        )

        XCTAssertFalse(recommendations.contains { $0.id == "critical-group-chrome" })
    }

    func testRecommendationEngineExplainsRecoveryWhileSwapRemains() {
        let previousTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let timestamp = previousTimestamp.addingTimeInterval(60)
        let previousSystem = makePressureSnapshot(
            timestamp: previousTimestamp,
            availableFraction: 0.15,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 3 * 1024 * 1024 * 1024
        )
        let currentSystem = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.30,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 4 * 1024 * 1024 * 1024
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: currentSystem,
            groups: [],
            didSampleProcesses: false
        )

        let recommendation = try! XCTUnwrap(
            RecommendationEngine().evaluate(
                RecommendationContext(
                    current: current,
                    previousSystem: previousSystem,
                    pressureLevel: .normal,
                    previousPressureLevel: .attention
                )
            ).first
        )

        XCTAssertEqual(recommendation.id, "recovery-swap")
        XCTAssertEqual(recommendation.severity, .info)
    }

    func testRecommendationEngineReportsPartialProcessDataOnlyWhenNoStrongerSignalExists() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let system = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: system,
            groups: [],
            processStatus: .estimated(at: timestamp, message: "部分进程不可读")
        )

        let recommendation = try! XCTUnwrap(
            RecommendationEngine().evaluate(RecommendationContext(current: current)).first
        )

        XCTAssertEqual(recommendation.id, "data-quality-processes")
        XCTAssertEqual(recommendation.severity, .info)
    }

    func testAdaptiveSamplingPolicyUsesPanelCadenceFirst() {
        let policy = AdaptiveSamplingPolicy(
            backgroundIntervalSeconds: 20,
            panelIntervalSeconds: 3,
            pressureIntervalSeconds: 5
        )

        XCTAssertEqual(policy.intervalSeconds(panelPresented: true, pressureActive: false), 3)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: true, pressureActive: true), 3)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: false, pressureActive: true), 5)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: false, pressureActive: false), 20)
    }

    func testAdaptiveSamplingPolicyPreventsNonPositiveIntervals() {
        let policy = AdaptiveSamplingPolicy(
            backgroundIntervalSeconds: 0,
            panelIntervalSeconds: -2,
            pressureIntervalSeconds: .nan
        )

        XCTAssertEqual(policy.intervalSeconds(panelPresented: false, pressureActive: false), 0.1)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: true, pressureActive: false), 0.1)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: false, pressureActive: true), 0.1)

        let infinitePolicy = AdaptiveSamplingPolicy(pressureIntervalSeconds: .infinity)
        XCTAssertEqual(infinitePolicy.intervalSeconds(panelPresented: false, pressureActive: true), 0.1)
    }

    func testMemoryPressureEvaluatorDebouncesTransientTransitions() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var evaluator = MemoryPressureEvaluator(transitionIntervalSeconds: 30)

        XCTAssertEqual(evaluator.update(observed: .normal, at: start), .normal)
        XCTAssertEqual(
            evaluator.update(observed: .attention, at: start.addingTimeInterval(10)),
            .normal
        )
        XCTAssertEqual(evaluator.pendingLevel, .attention)
        XCTAssertTrue(evaluator.pressureActiveForSampling)

        XCTAssertEqual(
            evaluator.update(observed: .normal, at: start.addingTimeInterval(20)),
            .normal
        )
        XCTAssertNil(evaluator.pendingLevel)
        XCTAssertFalse(evaluator.pressureActiveForSampling)
    }

    func testMemoryPressureEvaluatorCommitsSustainedUpgradeAndRecovery() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var evaluator = MemoryPressureEvaluator(transitionIntervalSeconds: 30)

        XCTAssertEqual(evaluator.update(observed: .normal, at: start), .normal)
        XCTAssertEqual(
            evaluator.update(observed: .critical, at: start.addingTimeInterval(1)),
            .normal
        )
        XCTAssertEqual(
            evaluator.update(observed: .critical, at: start.addingTimeInterval(30)),
            .normal
        )
        XCTAssertEqual(
            evaluator.update(observed: .critical, at: start.addingTimeInterval(31)),
            .critical
        )

        XCTAssertEqual(
            evaluator.update(observed: .normal, at: start.addingTimeInterval(60)),
            .critical
        )
        XCTAssertEqual(
            evaluator.update(observed: .normal, at: start.addingTimeInterval(61)),
            .critical
        )
        XCTAssertEqual(
            evaluator.update(observed: .normal, at: start.addingTimeInterval(91)),
            .normal
        )
    }

    func testMemoryPressureEvaluatorClassifiesCriticalBeforeAttention() {
        let snapshot = makePressureSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.05,
            compressedBytes: 8 * 1024 * 1024 * 1024
        )

        XCTAssertEqual(MemoryPressureEvaluator.observedLevel(for: snapshot), .critical)
    }

    func testMemoryPressureEvaluatorUsesSwapThreshold() {
        let snapshot = makePressureSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.30,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )

        XCTAssertEqual(MemoryPressureEvaluator.observedLevel(for: snapshot), .critical)
    }

    func testMemoryHistoryBufferKeepsNewestEntries() {
        let first = makeSystemSnapshot(timestamp: Date(timeIntervalSince1970: 1), compressed: 10, swap: 20)
        let second = makeSystemSnapshot(timestamp: Date(timeIntervalSince1970: 2), compressed: 11, swap: 21)
        let third = makeSystemSnapshot(timestamp: Date(timeIntervalSince1970: 3), compressed: 12, swap: 22)
        var history = MemoryHistoryBuffer(capacity: 2)

        history.append(snapshot: first)
        history.append(snapshot: second)
        history.append(snapshot: third)

        XCTAssertEqual(history.entries.map(\.timestamp), [second.timestamp, third.timestamp])
        XCTAssertEqual(history.entries.map(\.compressedBytes), [11, 12])
    }

    func testMemoryHistoryAnalyzerSummarizesWindowAndPeaks() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeHistoryRecord(timestamp: base, availableFraction: 0.60, swapUsedBytes: 100),
            makeHistoryRecord(timestamp: base.addingTimeInterval(60), availableFraction: 0.25, swapUsedBytes: 200),
            makeHistoryRecord(timestamp: base.addingTimeInterval(120), availableFraction: 0.40, swapUsedBytes: 300)
        ]

        let analysis = MemoryHistoryAnalyzer().analyze(records)

        XCTAssertEqual(analysis.sampleCount, 3)
        XCTAssertEqual(analysis.firstTimestamp, base)
        XCTAssertEqual(analysis.lastTimestamp, base.addingTimeInterval(120))
        XCTAssertEqual(try! XCTUnwrap(analysis.latestUsedFraction), 0.60, accuracy: 0.0001)
        XCTAssertEqual(try! XCTUnwrap(analysis.peakUsedFraction), 0.75, accuracy: 0.0001)
        XCTAssertEqual(analysis.latestSwapUsedBytes, 300)
        XCTAssertEqual(analysis.peakSwapUsedBytes, 300)
        XCTAssertEqual(analysis.windowDuration, 120, accuracy: 0.001)
        XCTAssertTrue(analysis.events.isEmpty)
    }

    func testMemoryHistoryAnalyzerEmitsPressureAndSwapThresholdEvents() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeHistoryRecord(timestamp: base, availableFraction: 0.30, swapUsedBytes: 0),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.15,
                swapUsedBytes: 2 * 1024 * 1024 * 1024
            ),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(120),
                availableFraction: 0.08,
                swapUsedBytes: 5 * 1024 * 1024 * 1024
            ),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(180),
                availableFraction: 0.25,
                swapUsedBytes: 3 * 1024 * 1024 * 1024
            ),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(240),
                availableFraction: 0.30,
                swapUsedBytes: 512 * 1024 * 1024
            )
        ]

        let analysis = MemoryHistoryAnalyzer().analyze(records)

        XCTAssertEqual(analysis.pressureTransitionCount, 3)
        XCTAssertEqual(
            analysis.events.filter { $0.kind == .pressureTransition }.count,
            3
        )
        XCTAssertTrue(analysis.events.contains { $0.title == "内存压力进入注意" })
        XCTAssertTrue(analysis.events.contains { $0.title == "内存压力进入严重" })
        XCTAssertTrue(analysis.events.contains { $0.title == "内存压力恢复正常" })
        XCTAssertTrue(analysis.events.contains { $0.title == "Swap 超过 1.0 GiB" })
        XCTAssertTrue(analysis.events.contains { $0.title == "Swap 超过 4.0 GiB" })
        XCTAssertTrue(analysis.events.contains { $0.title == "Swap 回落至 1.0 GiB 以下" })
    }

    func testMemoryHistoryAnalyzerDescribesWorkloadRankingChanges() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let api = makePersistedWorkload(id: "runtime-node-api", title: "Node · api", footprint: 200 * 1024 * 1024)
        let worker = makePersistedWorkload(id: "runtime-python-worker", title: "Python · worker", footprint: 128 * 1024 * 1024)
        let largerAPI = makePersistedWorkload(id: api.id, title: api.title, footprint: 800 * 1024 * 1024)

        let records = [
            makeHistoryRecord(timestamp: base, availableFraction: 0.40, swapUsedBytes: 0, workloads: [api]),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.40,
                swapUsedBytes: 0,
                workloads: [largerAPI, worker]
            ),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(120),
                availableFraction: 0.40,
                swapUsedBytes: 0,
                workloads: [worker]
            )
        ]

        let analysis = MemoryHistoryAnalyzer().analyze(records)

        XCTAssertTrue(analysis.events.contains {
            $0.kind == .workloadAppeared && $0.targetID == worker.id
        })
        XCTAssertTrue(analysis.events.contains {
            $0.kind == .workloadGrowth && $0.targetID == api.id
        })
        XCTAssertTrue(analysis.events.contains {
            $0.kind == .workloadDisappeared && $0.targetID == api.id
        })
        XCTAssertFalse(analysis.events.contains { $0.targetID == "other-processes" })
    }

    func testMemoryHistoryAnalyzerHandlesDuplicateWorkloadIDs() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024
        )
        let replacement = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 300 * 1024 * 1024
        )
        let records = [
            makeHistoryRecord(timestamp: base, availableFraction: 0.40, swapUsedBytes: 0, workloads: [first]),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.40,
                swapUsedBytes: 0,
                workloads: [first, replacement]
            )
        ]

        let analysis = MemoryHistoryAnalyzer().analyze(records)

        XCTAssertEqual(analysis.sampleCount, 2)
        XCTAssertFalse(analysis.events.contains { $0.kind == .workloadAppeared })
        XCTAssertFalse(analysis.events.contains { $0.kind == .workloadDisappeared })
    }

    func testHistoryStoreStartsEmptyWhenFileIsMissing() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(fileURL: url)
        let records = try await store.load(now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testHistoryStoreCoalescesMinuteAndReloadsFromDisk() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let group = makeGroup(id: "chrome", title: "Chrome", footprint: 300)
        let store = HistoryStore(fileURL: url)

        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base.addingTimeInterval(5), compressed: 10, swap: 20),
            groups: [group],
            now: base.addingTimeInterval(5)
        )
        let firstDiskData = try Data(contentsOf: url)
        let records = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base.addingTimeInterval(55), compressed: 20, swap: 30),
            groups: [group],
            now: base.addingTimeInterval(55)
        )
        XCTAssertEqual(try Data(contentsOf: url), firstDiskData)
        try await store.flush()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].compressedBytes, 20)
        XCTAssertNotEqual(try Data(contentsOf: url), firstDiskData)
        XCTAssertEqual(records[0].workloads.first?.attributedFootprintBytes, 300)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let reloaded = HistoryStore(fileURL: url)
        let loadedRecords = try await reloaded.load(now: base.addingTimeInterval(60))
        XCTAssertEqual(loadedRecords, records)
    }

    func testHistoryStoreDropsRecordsOlderThanRetentionWindow() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let store = HistoryStore(fileURL: url, retentionInterval: 120)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base.addingTimeInterval(60), compressed: 2, swap: 2),
            now: base.addingTimeInterval(60)
        )
        let records = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base.addingTimeInterval(180), compressed: 3, swap: 3),
            now: base.addingTimeInterval(180)
        )

        XCTAssertEqual(records.map(\.compressedBytes), [2, 3])
    }

    func testHistoryStoreCompactsLowPriorityWorkloadsIntoAttributionAggregate() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let groups = [
            makeGroup(id: "one", title: "One", footprint: 100),
            makeGroup(id: "two", title: "Two", footprint: 200),
            makeGroup(id: "three", title: "Three", footprint: 300),
            makeGroup(id: "four", title: "Four", footprint: 400),
            makeGroup(id: "five", title: "Five", footprint: 500)
        ]
        let store = HistoryStore(fileURL: url, maxPersistedWorkloads: 2)
        let records = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            groups: groups,
            now: base
        )

        XCTAssertEqual(records[0].workloads.count, 3)
        XCTAssertEqual(Set(records[0].workloads.map(\.id)), Set(["five", "four", "other-processes"]))
        let aggregate = try XCTUnwrap(records[0].workloads.first { $0.id == "other-processes" })
        XCTAssertEqual(aggregate.processCount, 3)
        XCTAssertEqual(aggregate.attributedFootprintBytes, 600)
    }

    func testHistoryStorePersistsOnlySanitizedRuntimeIdentity() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let processes = [
            makeProcess(
                pid: 70,
                name: "node",
                footprint: 100,
                workingDirectoryLabel: "api"
            )
        ]
        let groups = WorkloadGrouper().group(processes)
        let store = HistoryStore(fileURL: url)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000), compressed: 1, swap: 1),
            groups: groups,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(persisted.contains("runtime-node-api"))
        XCTAssertFalse(persisted.contains("/Users/"))
        XCTAssertFalse(persisted.contains("commandLine"))
    }

    func testHistoryStoreRejectsCorruptFile() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url, options: [.atomic])

        let store = HistoryStore(fileURL: url)
        do {
            _ = try await store.load(now: Date(timeIntervalSince1970: 1_700_000_000))
            XCTFail("Expected corrupt history file to be rejected")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .invalidData)
        }
    }

    func testHistoryStoreRejectsUnsupportedVersion() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(MemoryHistoryFile(version: 99, records: []))
        try data.write(to: url, options: [.atomic])

        let store = HistoryStore(fileURL: url)
        do {
            _ = try await store.load(now: Date(timeIntervalSince1970: 1_700_000_000))
            XCTFail("Expected unsupported history version to be rejected")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .unsupportedVersion(99))
        }
    }

    private func makeGroup(id: String, title: String, footprint: UInt64) -> WorkloadGroupSnapshot {
        WorkloadGroupSnapshot(
            id: id,
            title: title,
            processCount: 1,
            physicalFootprintBytes: footprint,
            residentBytes: footprint,
            isSystem: false,
            representativeProcess: title
        )
    }

    private func makeHistoryRecord(
        timestamp: Date,
        availableFraction: Double,
        swapUsedBytes: UInt64,
        workloads: [PersistedWorkloadRecord] = []
    ) -> MemoryHistoryRecord {
        MemoryHistoryRecord(
            timestamp: timestamp,
            availableFraction: availableFraction,
            compressedBytes: 0,
            swapUsedBytes: swapUsedBytes,
            workloads: workloads
        )
    }

    private func makePersistedWorkload(
        id: String,
        title: String,
        footprint: UInt64,
        isSystem: Bool = false
    ) -> PersistedWorkloadRecord {
        PersistedWorkloadRecord(
            id: id,
            title: title,
            processCount: 1,
            attributedFootprintBytes: footprint,
            attributedResidentBytes: footprint,
            isSystem: isSystem
        )
    }

    private func makeMonitorSnapshot(
        timestamp: Date,
        system: SystemMemorySnapshot?,
        groups: [WorkloadGroupSnapshot],
        processes: [ProcessSnapshot] = [],
        processStatus: SampleStatus? = nil,
        didSampleProcesses: Bool = true
    ) -> MonitorSnapshot {
        let systemStatus = system.map {
            SampleStatus.estimated(at: $0.timestamp, message: "内存使用率按可回收内存估算")
        } ?? .unavailable(message: "系统数据不可用")
        let resolvedProcessStatus = processStatus
            ?? (didSampleProcesses
                ? .available(at: timestamp)
                : .unavailable(message: "本轮未执行进程扫描"))
        let diagnostics = SamplingDiagnostics(
            mode: didSampleProcesses ? .panel : .background,
            totalDurationMilliseconds: 1,
            processDurationMilliseconds: didSampleProcesses ? 1 : nil,
            processSamplingPerformed: didSampleProcesses,
            processCount: processes.count,
            listedProcessCount: processes.count
        )
        return MonitorSnapshot(
            timestamp: timestamp,
            system: system,
            systemStatus: systemStatus,
            cpuTime: nil,
            cpuStatus: .unavailable(message: "测试未提供 CPU 数据"),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(message: "测试未提供 GPU 数据"),
            processes: processes,
            processStatus: resolvedProcessStatus,
            listedProcessCount: processes.count,
            sampledProcessCount: processes.count,
            groups: groups,
            samplingMode: diagnostics.mode,
            diagnostics: diagnostics
        )
    }

    private func makeSystemSnapshot(timestamp: Date, compressed: UInt64, swap: UInt64) -> SystemMemorySnapshot {
        SystemMemorySnapshot(
            timestamp: timestamp,
            totalBytes: 1_000,
            pageSize: 1,
            freeBytes: 100,
            activeBytes: 500,
            inactiveBytes: 0,
            speculativeBytes: 0,
            wiredBytes: 400,
            purgeableBytes: 0,
            compressedBytes: compressed,
            throttledPages: 0,
            swapTotalBytes: 100,
            swapUsedBytes: swap,
            swapFreeBytes: 100 - swap
        )
    }

    private func makePressureSnapshot(
        timestamp: Date,
        availableFraction: Double,
        compressedBytes: UInt64 = 0,
        throttledPages: UInt64 = 0,
        swapTotalBytes: UInt64 = 0,
        swapFreeBytes: UInt64 = 0
    ) -> SystemMemorySnapshot {
        let totalBytes: UInt64 = 16 * 1024 * 1024 * 1024
        let freeBytes = UInt64(Double(totalBytes) * availableFraction)
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
            compressedBytes: compressedBytes,
            throttledPages: throttledPages,
            swapTotalBytes: swapTotalBytes,
            swapUsedBytes: swapTotalBytes >= swapFreeBytes
                ? swapTotalBytes - swapFreeBytes
                : 0,
            swapFreeBytes: swapFreeBytes
        )
    }

    private func makeProcess(
        pid: Int32,
        name: String,
        parentPID: Int32 = 1,
        footprint: UInt64,
        isSystem: Bool = false,
        workingDirectoryLabel: String? = nil
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            identity: ProcessIdentity(pid: pid, startTimeSeconds: 1, startTimeMicroseconds: UInt64(pid)),
            parentPID: parentPID,
            userID: 501,
            isSystem: isSystem,
            name: name,
            executablePath: "/usr/bin/\(name)",
            residentBytes: footprint,
            physicalFootprintBytes: footprint,
            workingDirectoryLabel: workingDirectoryLabel,
            virtualBytes: footprint,
            userTimeNanos: 0,
            systemTimeNanos: 0,
            threadCount: 1
        )
    }

    private func makeTemporaryHistoryURL() -> (file: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMonitorTests-" + UUID().uuidString, isDirectory: true)
        return (directory.appendingPathComponent("history.json"), directory)
    }
}
