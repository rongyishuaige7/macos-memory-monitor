import CryptoKit
import Foundation
import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

@MainActor
final class ProductExperienceU1Tests: XCTestCase {
    func testStatusProjectionNeverLabelsUnknownAsNormal() {
        XCTAssertEqual(
            MonitorStatusProjection.pressure(usable: false, level: .normal).tone,
            .loading
        )
        XCTAssertEqual(
            MonitorStatusProjection.pressure(usable: true, level: .critical).tone,
            .critical
        )

        let statuses: [MonitorDetailDataStatus] = [
            detailStatus(.loading),
            detailStatus(.current),
            detailStatus(.partial),
            detailStatus(.retained, reason: .expired),
            detailStatus(.failed, message: "provider failed"),
            detailStatus(.unavailable)
        ]
        for status in statuses {
            let projection = MonitorStatusProjection.detail(status)
            if status.kind != .current {
                XCTAssertNotEqual(projection.tone, .normal, "unexpected normal for \(status.kind)")
            }
        }
        XCTAssertEqual(
            MonitorStatusProjection.detail(detailStatus(.failed, message: "provider failed")).tone,
            .critical
        )
        XCTAssertEqual(
            MonitorStatusProjection.detail(detailStatus(.unavailable)).tone,
            .unavailable
        )
    }

    func testActionAvailabilityExplainsBlockingReason() {
        XCTAssertFalse(
            MonitorStatusProjection.manualAction(
                busy: true, shuttingDown: false, auditQueueFull: false, auditError: nil
            ).isEnabled
        )
        let enabled = MonitorStatusProjection.manualAction(
            busy: false, shuttingDown: false, auditQueueFull: false, auditError: nil
        )
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertNil(enabled.reason)
        XCTAssertEqual(
            MonitorStatusProjection.manualAction(
                busy: false, shuttingDown: false, auditQueueFull: true, auditError: nil
            ).reason,
            "操作记录待写队列已满，请先恢复记录"
        )
    }

    func testHealthRoutesPointToSpecificSurfaces() {
        XCTAssertEqual(MonitorStatusProjection.healthRoute(for: "audit"), .audit)
        XCTAssertEqual(MonitorStatusProjection.healthRoute(for: "history"), .localData)
        XCTAssertEqual(MonitorStatusProjection.healthRoute(for: "processes"), .processes)
        XCTAssertNil(MonitorStatusProjection.healthRoute(for: "cpu"))
    }

    func testTypedRecoveryErrorsAreNotHidden() {
        XCTAssertEqual(
            MonitorStatusProjection.recoveryStatus(HistoryStoreError.recoveryRequired)?.tone,
            .critical
        )
        XCTAssertEqual(
            MonitorStatusProjection.recoveryStatus(StorageRestoreError.manualRecoveryRequired)?.title,
            "需要人工恢复"
        )
        XCTAssertNil(MonitorStatusProjection.recoveryStatus(nil))
    }

    func testLocalDataInspectionIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("u1-local-data-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = MemoryHistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.5,
            compressedBytes: 1,
            swapUsedBytes: 2,
            workloads: []
        )
        try encoder.encode(MemoryHistoryFile(records: [record]))
            .write(to: root.appendingPathComponent("history.json"))
        let before = try snapshot(root)

        let diagnostics = LocalDataDiagnosticsController(root: root)
        diagnostics.inspect()
        for _ in 0..<200 where diagnostics.isInspecting {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(diagnostics.isInspecting)
        XCTAssertEqual(diagnostics.report?.status, .legacy)
        XCTAssertEqual(try snapshot(root), before)
        XCTAssertFalse(diagnostics.hasPendingRecovery)
    }

    func testPendingRecoveryMarkerIsVisible() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("u1-marker-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: MaintenanceTransaction.url(root: root))
        XCTAssertTrue(LocalDataDiagnosticsController(root: root).hasPendingRecovery)
    }

    func testSupportSummaryWhitelistAndNoOverwrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("u1-summary-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = HistoryInspectionReport(
            status: .healthy,
            format: .segmentedV2,
            recordCount: 3,
            segmentCount: 1,
            journalRecordCount: 0,
            earliestTimestamp: nil,
            latestTimestamp: nil,
            totalBytes: 42,
            indexBytes: 10,
            segmentBytes: 20,
            journalBytes: 0,
            clockBytes: 12,
            issues: [.init(code: "exampleIssue", count: 1)]
        )
        let summary = SupportSummary(
            generatedAt: Date(timeIntervalSince1970: 1),
            productVersion: "1.4.2",
            productBuild: "142",
            operatingSystem: "macOS",
            architecture: "arm64",
            report: report
        )
        let data = try summary.encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("PID"))
        XCTAssertFalse(text.contains("sentinel-process"))
        XCTAssertFalse(text.contains(root.path))
        XCTAssertTrue(text.contains("exampleIssue"))

        let output = root.appendingPathComponent("summary.json")
        try SupportSummaryExporter.write(data, to: output)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try SupportSummaryExporter.write(data, to: output)) { error in
            XCTAssertEqual(error as? SupportSummaryExporter.ExportError, .alreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: output), data)
    }

    private func detailStatus(
        _ kind: MonitorDetailDataStatus.Kind,
        reason: MonitorDetailDataStatus.RetentionReason? = nil,
        message: String? = nil
    ) -> MonitorDetailDataStatus {
        MonitorDetailDataStatus(
            kind: kind,
            retentionReason: reason,
            sampledAt: Date(timeIntervalSince1970: 100),
            observedAt: Date(timeIntervalSince1970: 130),
            retainedItemCount: kind == .retained ? 2 : 0,
            sampledItemCount: 2,
            listedItemCount: 2,
            message: message
        )
    }

    private func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            result[url.path] = [
                String(describing: attributes[.size] ?? ""),
                String(describing: attributes[.modificationDate] ?? ""),
                String(describing: attributes[.posixPermissions] ?? "")
            ].joined(separator: "|")
        }
        return result
    }
}
