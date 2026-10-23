import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

final class ProductExperienceU5Tests: XCTestCase {
    private func record(
        _ seconds: TimeInterval,
        used: Double,
        compressed: UInt64 = 10,
        swap: UInt64 = 20,
        workloads: [PersistedWorkloadRecord] = [],
        sampledAt: Date? = nil,
        complete: Bool? = true
    ) -> MemoryHistoryRecord {
        MemoryHistoryRecord(
            timestamp: Date(timeIntervalSince1970: seconds),
            availableFraction: 1 - used,
            compressedBytes: compressed,
            swapUsedBytes: swap,
            workloads: workloads,
            workloadsSampledAt: sampledAt ?? (workloads.isEmpty ? nil : Date(timeIntervalSince1970: seconds)),
            workloadInventoryIsComplete: complete,
            sourceSampledAt: Date(timeIntervalSince1970: seconds)
        )
    }

    func testPeakUsesRawRecordEvenWhenDrawingOmitsIt() {
        var records = (1...300).map { record(Double($0) * 60, used: 0.3) }
        let peak = record(15_000, used: 0.9)
        records.append(peak)
        let data = HistoryTrendData(records: records, hours: 24, now: Date(timeIntervalSince1970: 20_000))
        XCTAssertEqual(data.peak?.timestamp, peak.timestamp)
        XCTAssertTrue(data.records.contains { $0.timestamp == peak.timestamp })
        XCTAssertLessThanOrEqual(data.points.count, 240)
    }

    func testCompressedAndSwapDeltasOnlyUseAdjacentRecordsWithin120Seconds() {
        let first = record(100, used: 0.4, compressed: 100, swap: 200)
        let second = record(200, used: 0.5, compressed: 160, swap: 180)
        let sample = HistorySamplePresentation(record: second, previous: first)
        XCTAssertEqual(sample.compressedDelta, 60)
        XCTAssertEqual(sample.swapDelta, -20)
        XCTAssertEqual(sample.comparisonInterval, 100)

        let gap = HistorySamplePresentation(
            record: record(500, used: 0.5, compressed: 999, swap: 999),
            previous: second
        )
        XCTAssertNil(gap.compressedDelta)
        XCTAssertNil(gap.swapDelta)
        XCTAssertNil(gap.comparisonInterval)
    }

    func testWorkloadQualityDistinguishesCompletePartialUnknownAndEstimated() {
        let workload = PersistedWorkloadRecord(
            id: "w", title: "Workload", processCount: 1,
            attributedFootprintBytes: 1024, attributedResidentBytes: 1024,
            isSystem: false, containsEstimatedFootprint: false
        )
        let complete = HistorySamplePresentation(
            record: record(100, used: 0.5, workloads: [workload], complete: true),
            previous: nil
        )
        XCTAssertEqual(complete.workloadQuality, .complete)
        XCTAssertEqual(complete.topWorkloads.count, 1)

        let partial = HistorySamplePresentation(
            record: record(100, used: 0.5, workloads: [workload], complete: false),
            previous: nil
        )
        XCTAssertEqual(partial.workloadQuality, .partial)

        let unknown = HistorySamplePresentation(
            record: record(100, used: 0.5, workloads: [workload], sampledAt: nil, complete: nil),
            previous: nil
        )
        XCTAssertEqual(unknown.workloadQuality, .unknown)

        let estimated = HistorySamplePresentation(
            record: record(
                100, used: 0.5,
                workloads: [PersistedWorkloadRecord(
                    id: "e", title: "Estimated", processCount: 1,
                    attributedFootprintBytes: 1024, attributedResidentBytes: 1024,
                    isSystem: false, containsEstimatedFootprint: true
                )],
                complete: true
            ),
            previous: nil
        )
        XCTAssertEqual(estimated.workloadQuality, .estimated)
    }

    func testCoverageAndGapCountDoNotFillMissingSamples() {
        let records = [
            record(0, used: 0.2),
            record(60, used: 0.3),
            record(240, used: 0.4),
            record(300, used: 0.5)
        ]
        let data = HistoryTrendData(records: records, hours: 1, now: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(data.gapCount, 1)
        XCTAssertTrue(data.coverageText.contains("4 个有效样本"))
        XCTAssertTrue(data.coverageText.contains("1 处断档"))
        XCTAssertEqual(data.exactRecord(at: records[1].timestamp)?.timestamp, records[1].timestamp)
        XCTAssertEqual(data.adjacentRecord(to: records[1].timestamp, direction: 1)?.timestamp, records[2].timestamp)
    }
}
