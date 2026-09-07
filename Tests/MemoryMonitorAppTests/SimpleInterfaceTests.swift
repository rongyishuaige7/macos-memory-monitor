import AppKit
import SwiftUI
import XCTest
import MemoryMonitorCore
@testable import MemoryMonitorApp

@MainActor
final class SimpleInterfaceTests: XCTestCase {
    func testUnavailableSystemCannotLookHealthy() {
        XCTAssertEqual(
            SimpleMonitorPresentation.pressureTitle(usable: false, level: .normal),
            "暂时无法读取"
        )
    }

    func testRetainedListStillExplainsFailedUpdate() {
        let status = MonitorDetailDataStatus.resolve(
            processStatus: .error("provider failed"),
            samplingDiagnostics: SamplingDiagnostics(
                mode: .full, totalDurationMilliseconds: 1,
                processDurationMilliseconds: 1, processSamplingPerformed: true,
                processCount: 0, listedProcessCount: 10
            ),
            retainedItemCount: 10, targetPresent: true, observedAt: Date()
        )
        XCTAssertEqual(SimpleMonitorPresentation.listNotice(status: status), "暂时无法更新，显示上次数据")
    }

    func testProductionViewsFitCompactWindowAndRender() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-monitor-simple-" + UUID().uuidString)
        let dataset = MemoryMonitorUIFixture.makeDataset()
        let actions = ProcessActionController(
            currentUserID: try XCTUnwrap(dataset.snapshot.processes.first).userID,
            auditStore: ProcessActionAuditStore(fileURL: root.appendingPathComponent("actions.jsonl"))
        )
        let model = MonitorViewModel(
            loginLaunchRuntime: SimpleInterfaceLoginRuntime(),
            sampler: MemoryMonitorUIFixtureSamplingSource(dataset: dataset),
            historyStore: HistoryStore(fileURL: root.appendingPathComponent("history.json")),
            processActions: actions,
            startRefreshTask: false
        )
        await model.refreshOnce(at: dataset.referenceDate)
        let popover = MonitorPopover(
            model: model, processActions: actions, loginLaunch: model.loginLaunch,
            terminationAction: ApplicationTerminationAction(handler: {})
        )
        try render(popover, name: "overview", width: 380, maximumHeight: 650)
        try render(popover, name: "overview-dark", width: 380, maximumHeight: 650, dark: true)
        let process = try XCTUnwrap(model.processes.first)
        try render(
            ProcessDetailView(model: model, actions: actions, identity: process.identity),
            name: "detail", width: 380, maximumHeight: 480
        )
        try render(
            MonitorHealthPanel(model: model, processActions: actions, loginLaunch: model.loginLaunch),
            name: "settings", width: 420, maximumHeight: 380
        )
        await model.shutdown()

        // Only this in-memory rendering fixture supplies an actionable path.
        // The shipped UI fixture intentionally keeps its paths unavailable.
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(process)
        ) as? [String: Any])
        fields["executablePath"] = "/tmp/memory-monitor-render-only"
        let actionable = try JSONDecoder().decode(
            ProcessSnapshot.self, from: JSONSerialization.data(withJSONObject: fields)
        )
        let source = dataset.snapshot
        let actionableDataset = MemoryMonitorUIFixture.Dataset(
            referenceDate: dataset.referenceDate,
            snapshot: MonitorSnapshot(
                timestamp: source.timestamp, system: source.system, systemStatus: source.systemStatus,
                cpuTime: source.cpuTime, cpuStatus: source.cpuStatus,
                gpuUsageFraction: source.gpuUsageFraction, gpuStatus: source.gpuStatus,
                processes: [actionable], processStatus: source.processStatus,
                listedProcessCount: 1, sampledProcessCount: 1, groups: []
            ),
            historyRecords: [], auditEvents: []
        )
        let actionController = ProcessActionController(
            currentUserID: actionable.userID,
            auditStore: ProcessActionAuditStore(fileURL: root.appendingPathComponent("action-preview.jsonl"))
        )
        let actionModel = MonitorViewModel(
            loginLaunchRuntime: SimpleInterfaceLoginRuntime(),
            sampler: MemoryMonitorUIFixtureSamplingSource(dataset: actionableDataset),
            historyStore: HistoryStore(fileURL: root.appendingPathComponent("action-history.json")),
            processActions: actionController, startRefreshTask: false
        )
        await actionModel.refreshOnce(at: dataset.referenceDate)
        XCTAssertTrue(actionController.eligibility(for: actionable).allowed)
        try render(
            ProcessDetailView(model: actionModel, actions: actionController, identity: actionable.identity),
            name: "detail-actions", width: 380, maximumHeight: 480
        )
        await actionModel.shutdown()
    }

    private func render<Content: View>(
        _ view: Content, name: String, width: CGFloat, maximumHeight: CGFloat,
        dark: Bool = false
    ) throws {
        let hosting = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        XCTAssertEqual(size.width, width, accuracy: 1)
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertLessThanOrEqual(size.height, maximumHeight)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
        var colors = Set<String>()
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 8, "Rendered view must contain visible content")
        if let output = ProcessInfo.processInfo.environment["MEMORY_MONITOR_SCREENSHOT_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}

@MainActor
private final class SimpleInterfaceLoginRuntime: LoginLaunchRuntime {
    func status() -> LoginLaunchStatus { .notRegistered }
    func register() async throws {}
    func unregister() async throws {}
    func openSystemSettings() {}
}
