import XCTest
@testable import MemoryMonitorCore

final class MemoryMonitorCoreTests: XCTestCase {
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
