import AppKit
import SwiftUI
import XCTest
import MemoryMonitorCore
@testable import MemoryMonitorApp

@MainActor
final class HistoryChartTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    private func record(_ age: Double, used: Double) -> MemoryHistoryRecord {
        .init(timestamp: now.addingTimeInterval(-age), availableFraction: 1 - used,
              compressedBytes: 0, swapUsedBytes: 0)
    }

    func testPeriodSummaryExcludesOutsideFutureAndInvalidSamples() throws {
        let records = [record(7200, used: 0.99), record(600, used: 0.2), record(60, used: 0.8),
                       record(0, used: 0.5), record(-60, used: 1), record(120, used: .nan)]
        let data = HistoryTrendData(records: records, hours: 1, now: now)
        XCTAssertEqual(data.records.count, 3)
        XCTAssertEqual(try XCTUnwrap(data.average), 0.5, accuracy: 0.001)
        XCTAssertEqual(data.records.last?.usedFraction, 0.5)
        XCTAssertEqual(data.peak?.timestamp, now.addingTimeInterval(-60))
        XCTAssertEqual(HistoryTrendData(records: records, hours: 6, now: now).peak?.usedFraction, 0.99)
    }

    func testSummaryAndInspectionUseSamplesOutsideDrawingBudget() throws {
        let records: [MemoryHistoryRecord] = (0..<1440).map { index in
            let age = Double(1439 - index) * 60.0
            let regular = 0.3 + Double(index % 11) / 100.0
            let used: Double = index == 753 ? 0.99 : regular
            return record(age, used: used)
        }
        let data = HistoryTrendData(records: records, hours: 24, now: now)
        XCTAssertLessThanOrEqual(data.points.count, 240)
        XCTAssertEqual(try XCTUnwrap(data.average), records.reduce(0) { $0 + $1.usedFraction } / 1440, accuracy: 0.00001)
        let omitted = try XCTUnwrap(records.first { record in !data.points.contains { $0.timestamp == record.timestamp } })
        XCTAssertEqual(data.nearest(to: omitted.timestamp)?.timestamp, omitted.timestamp)
        XCTAssertEqual(data.peak?.usedFraction, 0.99)
    }

    func testInspectionDoesNotSnapAcrossMissingIntervals() {
        let records = [record(1800, used: 0.4), record(1740, used: 0.5), record(60, used: 0.7), record(0, used: 0.6)]
        let data = HistoryTrendData(records: records, hours: 1, now: now)
        XCTAssertNil(data.nearest(to: now.addingTimeInterval(-900)))
        XCTAssertNil(data.nearest(to: now.addingTimeInterval(-2000)))
        XCTAssertEqual(data.nearest(to: now.addingTimeInterval(-52))?.timestamp, records[2].timestamp)
        XCTAssertNotEqual(data.segments[records[1].timestamp], data.segments[records[2].timestamp])
    }

    func testEmptySingletonAndRepeatedTimestampsStayDefined() {
        let empty = HistoryTrendData(records: [], hours: 1, now: now)
        XCTAssertNil(empty.average)
        XCTAssertNil(empty.peak)
        XCTAssertNil(empty.nearest(to: now))
        XCTAssertEqual(HistoryTrendData.percentage(nil), "--")
        let single = HistoryTrendData(records: [record(0, used: 0.2), record(0, used: 0.5)], hours: 1, now: now)
        XCTAssertEqual(single.records.count, 1)
        XCTAssertEqual(single.average, 0.5)
        XCTAssertEqual(single.isolatedPoints, [now])
    }

    func testNativeChartStatesRenderAtBothSizesAndAppearances() throws {
        let dense = (0..<360).compactMap { index -> MemoryHistoryRecord? in
            guard !(140...190).contains(index) else { return nil }
            return record(Double(359 - index) * 60,
                          used: index == 245 ? 0.96 : 0.56 + sin(Double(index) / 19) * 0.12)
        }
        let states: [(String, [MemoryHistoryRecord], Int)] = [
            ("dense", dense, 6), ("empty", [], 1), ("single", [record(0, used: 0.75)], 1),
            ("constant", (0..<60).map { record(Double($0) * 60, used: 1) }, 1)
        ]
        for appearance in [ColorScheme.dark, .light] {
            for width in [560, 720] {
                for (name, records, hours) in states {
                    let view = MemoryTrend(records: records, hours: hours, now: now, detailed: true)
                        .padding(20).frame(width: CGFloat(width), height: width == 560 ? 360 : 440)
                        .background(appearance == .dark ? Color(white: 0.13) : Color(white: 0.96))
                        .environment(\.colorScheme, appearance)
                    try capture(view, name: "history-\(name)-\(width)-\(appearance)")
                }
            }
        }
    }

    private func capture<V: View>(_ view: V, name: String) throws {
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let output = ProcessInfo.processInfo.environment["MEMORY_MONITOR_SCREENSHOT_DIR"] {
            let root = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name + ".png"))
        }
    }
}
