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
            makeProcess(pid: 21, name: "node", parentPID: 20, footprint: 200),
            makeProcess(pid: 22, name: "Google Chrome Helper", parentPID: 21, footprint: 300)
        ]

        let groups = WorkloadGrouper().group(processes)
        let automation = try! XCTUnwrap(groups.first { $0.id == "codex-automation" })
        XCTAssertEqual(automation.processCount, 2)
        XCTAssertEqual(automation.physicalFootprintBytes, 500)
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

    private func makeProcess(
        pid: Int32,
        name: String,
        parentPID: Int32 = 1,
        footprint: UInt64,
        isSystem: Bool = false
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
