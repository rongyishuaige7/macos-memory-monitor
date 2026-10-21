import AppKit
import SwiftUI
import XCTest
import MemoryMonitorCore
@testable import MemoryMonitorApp

@MainActor
final class DesktopPresentationTests: XCTestCase {
    func testHistoryRangeAndGapsUseOriginalSamples() {
        let now = Date()
        func record(_ age: Double) -> MemoryHistoryRecord {
            .init(timestamp: now.addingTimeInterval(-age), availableFraction: 0.5, compressedBytes: 0, swapUsedBytes: 0)
        }
        XCTAssertEqual(DesktopPresentation.initialHistoryHours([], now: now), 1)
        XCTAssertEqual(DesktopPresentation.initialHistoryHours([record(600)], now: now), 1)
        XCTAssertEqual(DesktopPresentation.initialHistoryHours([record(7200)], now: now), 6)
        XCTAssertEqual(DesktopPresentation.initialHistoryHours([record(40000)], now: now), 24)
        let records = [record(600), record(540), record(60), record(0)]
        let segments = DesktopPresentation.chartSegments(records, hours: 1, now: now)
        XCTAssertEqual(segments[records[0].timestamp], segments[records[1].timestamp])
        XCTAssertNotEqual(segments[records[1].timestamp], segments[records[2].timestamp])
        let dense = (0..<1440).map { record(Double($0) * 60) }
        XCTAssertEqual(Set(DesktopPresentation.chartSegments(dense, hours: 24, now: now).values).count, 1)
    }

    func testGroupingKeepsEachVisibleProcessOnceAndSearchesMembers() throws {
        let processes = MemoryMonitorUIFixture.makeDataset().snapshot.processes
        let groups = DesktopPresentation.groupedProcesses([], processes: processes, query: "", includeSystem: true, sort: .memory, cpu: [:])
        XCTAssertEqual(groups.flatMap(\.members).count, processes.count)
        let first = try XCTUnwrap(processes.first)
        let group = WorkloadGroupSnapshot(id: "app", title: "An application", processCount: processes.count,
            physicalFootprintBytes: 0, residentBytes: 0, isSystem: false, representativeProcess: first.name,
            memberProcessIdentities: processes.map(\.identity))
        let grouped = DesktopPresentation.groupedProcesses([group, group], processes: processes,
            query: String(first.identity.pid), includeSystem: true, sort: .memory, cpu: [:])
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped.first?.members.count, processes.count)
        XCTAssertNil(grouped.first?.cpu([first.identity: 10]))
    }

    func testChartBudgetPreservesPeakAndEndpoints() {
        let now = Date()
        let records = (0..<1440).map { index in
            MemoryHistoryRecord(timestamp: now.addingTimeInterval(Double(index - 1439) * 60),
                availableFraction: index == 753 ? 0.01 : 0.5, compressedBytes: 0, swapUsedBytes: 0)
        }
        let points = DesktopPresentation.chartRecords(records, hours: 24, now: now)
        XCTAssertLessThanOrEqual(points.count, 240)
        XCTAssertEqual(points.first?.timestamp, records.first?.timestamp)
        XCTAssertEqual(points.last?.timestamp, records.last?.timestamp)
        XCTAssertTrue(points.contains { $0.usedFraction == 0.99 })
        XCTAssertTrue(DesktopPresentation.chartRecords(records, hours: 1, now: now).allSatisfy {
            $0.timestamp >= now.addingTimeInterval(-3600)
        })
    }

    func testProcessSearchAndCPUSort() throws {
        let processes = MemoryMonitorUIFixture.makeDataset().snapshot.processes
        let first = try XCTUnwrap(processes.first)
        let last = try XCTUnwrap(processes.last)
        let searched = DesktopPresentation.processes(processes, query: String(first.identity.pid), includeSystem: true,
                                                       sort: .memory, cpu: [:])
        XCTAssertTrue(searched.contains { $0.identity == first.identity })
        let sorted = DesktopPresentation.processes(processes, query: "", includeSystem: true, sort: .cpu,
                                                    cpu: [last.identity: 70, first.identity: 20])
        XCTAssertEqual(sorted.first?.identity, last.identity)
        XCTAssertTrue(DesktopPresentation.processes(processes, query: "", includeSystem: false, sort: .memory, cpu: [:])
            .allSatisfy { !$0.isSystem && $0.userID != 0 })
    }

    func testCPUBaselineRequiresForwardTimeAndRejectsCounterReset() throws {
        let process = try XCTUnwrap(MemoryMonitorUIFixture.makeDataset().snapshot.processes.first)
        let now = Date()
        var baseline = ProcessCPUBaseline()
        XCTAssertTrue(baseline.update([process], at: now).isEmpty)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(process)) as? [String: Any])
        fields["userTimeNanos"] = process.userTimeNanos + 2_000_000_000
        let updated = try JSONDecoder().decode(ProcessSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(baseline.update([updated], at: now.addingTimeInterval(4))[process.identity], 50)
        XCTAssertTrue(baseline.update([process], at: now.addingTimeInterval(8)).isEmpty)
        XCTAssertTrue(baseline.update([process], at: now).isEmpty)
    }

    func testTestPolicyRejectsPressureUnavailableAndOversizedRequests() throws {
        let system = try XCTUnwrap(MemoryMonitorUIFixture.makeDataset().snapshot.system)
        XCTAssertNotNil(MemoryTestPolicy.refusal(system: system, usable: true, pressure: .critical, requested: 1))
        XCTAssertNotNil(MemoryTestPolicy.refusal(system: system, usable: false, pressure: .normal, requested: 1))
        XCTAssertNotNil(MemoryTestPolicy.refusal(system: nil, usable: true, pressure: .normal, requested: 1))
        XCTAssertNotNil(MemoryTestPolicy.refusal(system: system, usable: true, pressure: .normal, requested: 1024 * 1024 * 1024))
        XCTAssertNil(MemoryTestPolicy.refusal(system: system, usable: true, pressure: .normal, requested: 128 * 1024 * 1024))
    }

    func testMemoryTestControllerIsDisabledByDefault() {
        let test = MemoryTestController()
        XCTAssertFalse(test.isEnabled)
        test.start(
            system: nil,
            usable: false,
            pressure: nil,
            intensity: .light
        )
        XCTAssertFalse(test.isRunning)
        XCTAssertTrue(test.message?.contains("不允许") == true)
    }

    func testWorkerCancelsAndRefusesPressureWithoutLargeAllocations() async {
        let refused = await MemoryTestWorker.run(bytes: 1024, check: { false }, progress: { _, _ in })
        XCTAssertFalse(refused.completed)
        let task = Task.detached {
            await MemoryTestWorker.run(bytes: 1024 * 1024, check: { true }, progress: { _, _ in })
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertFalse(cancelled.completed)
        XCTAssertTrue(cancelled.message.contains("已停止"))
        let completed = await MemoryTestWorker.run(bytes: 1024, seconds: 1, check: { true }, progress: { _, _ in })
        XCTAssertTrue(completed.completed)
    }

    func testAllDesktopPagesRenderAtDefaultAndMinimumSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-render-" + UUID().uuidString)
        let dataset = MemoryMonitorUIFixture.makeDataset()
        let history = HistoryStore(fileURL: root.appendingPathComponent("history.json"))
        _ = try await history.merge(records: dataset.historyRecords, now: dataset.referenceDate)
        let model = MonitorViewModel(sampler: MemoryMonitorUIFixtureSamplingSource(dataset: dataset),
            historyStore: history,
            processActions: ProcessActionController(auditStore: ProcessActionAuditStore(fileURL: root.appendingPathComponent("audit.jsonl"))),
            startRefreshTask: false)
        await model.refreshOnce(at: dataset.referenceDate)
        let navigation = DesktopNavigation()
        let test = MemoryTestController()
        let suite = "desktop-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for appearance in ["dark", "light"] {
        defaults.set(appearance, forKey: "desktopAppearance")
        for width in [960, 800] {
            for page in DesktopPage.allCases {
                navigation.page = page
                let view = DesktopWindowRoot(model: model, navigation: navigation, memoryTest: test)
                try render(view.defaultAppStorage(defaults), name: "desktop-\(page.rawValue)-\(width)-\(appearance)",
                           size: NSSize(width: width, height: width == 960 ? 628 : 538))
            }
        }
        }
        try render(DesktopMenuPanel(model: model, openDesktop: { _ in }, terminationAction: ApplicationTerminationAction(handler: {})),
                   name: "desktop-menu", size: NSSize(width: 290, height: 520))
        await model.shutdown()
    }

    func testCleanupStatesAndAuthorizationSheetRender() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-render-" + UUID().uuidString)
        let dataset = MemoryMonitorUIFixture.makeDataset()
        let model = MonitorViewModel(sampler: MemoryMonitorUIFixtureSamplingSource(dataset: dataset),
            historyStore: HistoryStore(fileURL: root.appendingPathComponent("history.json")),
            processActions: ProcessActionController(auditStore: ProcessActionAuditStore(fileURL: root.appendingPathComponent("audit.jsonl"))),
            startRefreshTask: false)
        await model.refreshOnce(at: dataset.referenceDate)
        let suite = "cleanup-render-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for appearance in ["dark", "light"] {
            defaults.set(appearance, forKey: "desktopAppearance")
            let runtime = FakeCleanupRuntime()
            runtime.observations = (1...4).map { observation(cleanupApp($0)) }
            runtime.exitResult = .running
            runtime.afterBytes = runtime.beforeBytes + 64 * 1024 * 1024
            let cleanup = SmartCleanupController(runtime: runtime, defaults: defaults)
            cleanup.setAuthorized(cleanupApp(1), true)
            cleanup.setAuthorized(cleanupApp(2), true)
            let navigation = DesktopNavigation()
            let view = DesktopRelease(model: model, cleanup: cleanup, navigation: navigation)
                .background(Color(nsColor: .windowBackgroundColor))
                .defaultAppStorage(defaults).environment(\.colorScheme, appearance == "dark" ? .dark : .light)
            var recorded: Set<String> = []
            runtime.onSleep = {
                let name = String(describing: cleanup.phase)
                if recorded.insert(name).inserted {
                    do { try self.render(view, name: "cleanup-\(name)-\(appearance)", size: NSSize(width: 617, height: 458)) }
                    catch { XCTFail("Cleanup render failed: \(error)") }
                }
                if cleanup.phase == .waiting { runtime.exitResult = .exited }
            }
            cleanup.start()
            await cleanup.waitUntilFinished()
            XCTAssertTrue(recorded.contains("scanning"))
            XCTAssertTrue(recorded.contains("waiting"))
            XCTAssertTrue(recorded.contains("measuring"))
            try render(view, name: "cleanup-result-\(appearance)", size: NSSize(width: 617, height: 458))
            cleanup.refreshApplications()
            for _ in 0..<100 where cleanup.isRefreshing { await Task.yield() }
            XCTAssertFalse(cleanup.applications.isEmpty)
            try render(CleanupApplicationsSheet(cleanup: cleanup).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, appearance == "dark" ? .dark : .light),
                       name: "cleanup-authorization-\(appearance)", size: NSSize(width: 520, height: 480))
            await cleanup.shutdown()
        }
        await model.shutdown()
    }

    private func render<V: View>(_ view: V, name: String, size: NSSize) throws {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.width, size.width, accuracy: 1)
        XCTAssertEqual(hosting.fittingSize.height, size.height, accuracy: 1)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 9) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 9) {
                if let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255)),\(Int(c.blueComponent * 255))")
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 20, name)
        if let output = ProcessInfo.processInfo.environment["MEMORY_MONITOR_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
