import Foundation
import XCTest
import MemoryMonitorCore
@testable import MemoryMonitorApp

final class CleanupCPUActivityTests: XCTestCase {
    private let app = cleanupApp(1)

    private func process(_ pid: Int32, parent: Int32 = 1, path: String = "/usr/local/bin/worker",
                         nanos: UInt64 = 0, start: UInt64 = 1000) -> ProcessSnapshot {
        ProcessSnapshot(identity: .init(pid: pid, startTimeSeconds: start, startTimeMicroseconds: 0),
                        parentPID: parent, userID: app.process.userID, isSystem: false, name: "worker",
                        executablePath: path, residentBytes: 1, physicalFootprintBytes: 1, virtualBytes: 1,
                        userTimeNanos: nanos, systemTimeNanos: 0, threadCount: 1)
    }

    private func scan(_ helpers: [ProcessSnapshot], failures: [ProcessReadDiagnostic] = []) -> ProcessSamplingResult {
        let rows = [app.process] + helpers
        return .init(processes: rows, listedProcessCount: rows.count + failures.count,
                     sampledProcessCount: rows.count, skippedProcessCount: failures.count,
                     status: .estimated(at: Date()), readFailures: failures)
    }

    func testBusyDescendantProtectsIdleMainProcess() throws {
        var tracker = CleanupCPUActivityTracker()
        let child = process(9001, parent: app.id.pid)
        let grandchild = process(9002, parent: 9001)
        XCTAssertNil(tracker.update(application: app, scan: scan([child, grandchild]), at: 10))
        let busy = process(9002, parent: 9001, nanos: 500_000_000)
        let cpu = try XCTUnwrap(tracker.update(application: app, scan: scan([child, busy]), at: 11))
        XCTAssertEqual(cpu, 50, accuracy: 0.001)
        XCTAssertEqual(observation(app, cpu: cpu).protection, "当前忙碌")
    }

    func testLaunchdHelperInsideBundleCountsButUnrelatedWorkerDoesNot() throws {
        var tracker = CleanupCPUActivityTracker()
        let path = app.authorization.bundlePath + "/Contents/XPCServices/Helper"
        let first = scan([process(9001, path: path), process(9002)])
        _ = tracker.update(application: app, scan: first, at: 10)
        let second = scan([process(9001, path: path, nanos: 100_000_000), process(9002, nanos: 9_000_000_000)])
        XCTAssertEqual(try XCTUnwrap(tracker.update(application: app, scan: second, at: 11)), 10, accuracy: 0.001)
    }

    func testMembershipAndPIDIdentityChangesRequireAnotherStableWindow() {
        var tracker = CleanupCPUActivityTracker()
        let child = process(9001, parent: app.id.pid)
        _ = tracker.update(application: app, scan: scan([]), at: 10)
        XCTAssertNil(tracker.update(application: app, scan: scan([child]), at: 11))
        XCTAssertEqual(tracker.update(application: app, scan: scan([child]), at: 12), 0)
        let replacement = process(9001, parent: app.id.pid, start: 2000)
        XCTAssertNil(tracker.update(application: app, scan: scan([replacement]), at: 13))
        XCTAssertNil(tracker.update(application: app, scan: scan([]), at: 14))
        XCTAssertEqual(tracker.update(application: app, scan: scan([]), at: 15), 0)
    }

    func testUnreadableOrUncertainFamilyCannotAppearIdle() {
        var tracker = CleanupCPUActivityTracker()
        let denied = ProcessReadDiagnostic(pid: 9001, parentPID: app.id.pid, userID: app.process.userID,
                                          executablePath: "/usr/local/bin/worker", reason: .permissionDenied)
        XCTAssertTrue(scan([], failures: [denied]).isUsable, "List refresh and safe cleanup have separate gates")
        _ = tracker.update(application: app, scan: scan([]), at: 10)
        XCTAssertNil(tracker.update(application: app, scan: scan([], failures: [denied]), at: 11))
        XCTAssertNil(tracker.update(application: app, scan: scan([]), at: 12))
        XCTAssertEqual(tracker.update(application: app, scan: scan([]), at: 13), 0)
        let unknown = ProcessReadDiagnostic(pid: 9002, reason: .unavailable)
        XCTAssertNil(tracker.update(application: app, scan: scan([], failures: [unknown]), at: 14))
    }

    func testCounterRollbackAndInvalidOrStaleTimeNeverProduceIdle() {
        var tracker = CleanupCPUActivityTracker()
        let child = process(9001, parent: app.id.pid, nanos: 100)
        _ = tracker.update(application: app, scan: scan([child]), at: 10)
        XCTAssertNil(tracker.update(application: app, scan: scan([process(9001, parent: app.id.pid)]), at: 11))
        XCTAssertNil(tracker.update(application: app, scan: scan([]), at: .nan))
        XCTAssertNil(tracker.update(application: app, scan: scan([]), at: 12))
        XCTAssertNil(tracker.update(application: app, scan: scan([]), at: 12.1))
        XCTAssertNil(tracker.update(application: app, scan: scan([]), at: 40))
    }

    func testIndependentFamilyEnumerationScopesUnrelatedPermissionFailures() {
        var tracker = CleanupCPUActivityTracker()
        let unrelated = ProcessReadDiagnostic(pid: 9001, executablePath: "/System/Library/Protected",
                                              reason: .permissionDenied)
        let report = scan([], failures: [unrelated])
        XCTAssertNil(tracker.update(application: app, scan: report, at: 10, descendantPIDs: []))
        XCTAssertEqual(tracker.update(application: app, scan: report, at: 11, descendantPIDs: []), 0)
        XCTAssertNil(tracker.update(application: app, scan: report, at: 12, descendantPIDs: [9001]),
                     "An unreadable actual child must still block cleanup")
        XCTAssertNil(tracker.update(application: app, scan: scan([]), at: 13, descendantPIDs: [9999]),
                     "A newly enumerated child absent from the CPU scan is incomplete")
    }
}
