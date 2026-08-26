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
}
