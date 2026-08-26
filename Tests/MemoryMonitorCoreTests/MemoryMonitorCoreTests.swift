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
