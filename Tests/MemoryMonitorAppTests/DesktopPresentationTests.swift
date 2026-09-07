import AppKit
import SwiftUI
import XCTest
import MemoryMonitorCore
@testable import MemoryMonitorApp

@MainActor
final class DesktopPresentationTests: XCTestCase {
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
        let model = MonitorViewModel(sampler: MemoryMonitorUIFixtureSamplingSource(dataset: dataset),
            historyStore: history,
            processActions: ProcessActionController(auditStore: ProcessActionAuditStore(fileURL: root.appendingPathComponent("audit.jsonl"))),
            startRefreshTask: false)
        await model.refreshOnce(at: dataset.referenceDate)
        let navigation = DesktopNavigation()
        let test = MemoryTestController()
        for width in [960, 800] {
            for page in DesktopPage.allCases {
                navigation.page = page
                let view = DesktopWindowRoot(model: model, navigation: navigation, memoryTest: test)
                try render(view, name: "desktop-\(page.rawValue)-\(width)",
                           size: NSSize(width: width, height: width == 960 ? 628 : 538))
            }
        }
        try render(DesktopMenuPanel(model: model, openDesktop: { _ in }, terminationAction: ApplicationTerminationAction(handler: {})),
                   name: "desktop-menu", size: NSSize(width: 290, height: 520))
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
