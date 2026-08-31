import Foundation
import XCTest
@testable import MemoryMonitorCore

final class MemoryMonitorUIFixtureTests: XCTestCase {
    func testFixtureEnvironmentRequiresExplicitOne() {
        XCTAssertTrue(
            MemoryMonitorUIFixture.isEnabled(
                environment: [MemoryMonitorUIFixture.environmentKey: "1"]
            )
        )
        for value in [nil, "", "0", "true", " 1 "] as [String?] {
            var environment: [String: String] = [:]
            if let value {
                environment[MemoryMonitorUIFixture.environmentKey] = value
            }
            XCTAssertFalse(MemoryMonitorUIFixture.isEnabled(environment: environment))
        }
    }

    func testFixtureRequiresPairedTemporaryStorageOverride() {
        let storageKey = MemoryMonitorStoragePaths.overrideEnvironmentKey
        let validEnvironment = [
            MemoryMonitorUIFixture.environmentKey: "1",
            storageKey: "/tmp/memory-monitor-ui-check-paired"
        ]
        XCTAssertEqual(
            MemoryMonitorUIFixture.isolatedStorageRootURL(environment: validEnvironment)?.path,
            URL(fileURLWithPath: "/tmp/memory-monitor-ui-check-paired")
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        )

        let invalidEnvironments: [[String: String]] = [
            [:],
            [MemoryMonitorUIFixture.environmentKey: "1"],
            [storageKey: "/tmp/memory-monitor-ui-check-paired"],
            [MemoryMonitorUIFixture.environmentKey: "0", storageKey: "/tmp/memory-monitor-ui-check-paired"],
            [MemoryMonitorUIFixture.environmentKey: "1", storageKey: "relative/path"],
            [MemoryMonitorUIFixture.environmentKey: "1", storageKey: "/Users/example/production"]
        ]
        for environment in invalidEnvironments {
            XCTAssertNil(
                MemoryMonitorUIFixture.isolatedStorageRootURL(environment: environment),
                "fixture launch should fail closed: \(environment)"
            )
        }
    }

    func testFixtureContainsStableMultipleMembersAndSafeTargets() throws {
        let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)
        let dataset = MemoryMonitorUIFixture.makeDataset(now: referenceDate)

        XCTAssertEqual(dataset.snapshot.groups.count, 2)
        XCTAssertEqual(dataset.snapshot.processes.count, 7)
        XCTAssertEqual(dataset.historyRecords.count, 240)
        XCTAssertEqual(dataset.auditEvents.count, 12)

        let processIDs = Set(dataset.snapshot.processes.map(\.identity))
        for group in dataset.snapshot.groups {
            XCTAssertGreaterThanOrEqual(group.processCount, 3)
            XCTAssertEqual(group.memberProcessIdentities.count, group.processCount)
            XCTAssertTrue(Set(group.memberProcessIdentities).isSubset(of: processIDs))
        }
        XCTAssertTrue(dataset.snapshot.processDataIsUsable)
        XCTAssertTrue(dataset.snapshot.processes.allSatisfy { $0.executablePath == nil })
        XCTAssertTrue(dataset.snapshot.processes.allSatisfy {
            $0.name.count <= WorkingDirectoryLabelSanitizer.maxLength
        })
    }

    func testFixtureRetimestampsWithoutChangingSelectionIdentities() throws {
        let dataset = MemoryMonitorUIFixture.makeDataset(
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let later = Date(timeIntervalSince1970: 1_750_000_123)
        let first = dataset.snapshot(at: later)

        XCTAssertEqual(first.timestamp, later)
        XCTAssertEqual(first.system?.timestamp, later)
        XCTAssertEqual(first.systemStatus.sampledAt, later)
        XCTAssertEqual(first.processStatus.sampledAt, later)
        XCTAssertEqual(
            first.processes.map(\.identity),
            dataset.snapshot.processes.map(\.identity)
        )
        XCTAssertEqual(first.groups, dataset.snapshot.groups)
        XCTAssertTrue(first.processDataIsUsable)
    }

    func testFixtureHistoryProducesMultipleExplainableEvents() {
        let dataset = MemoryMonitorUIFixture.makeDataset(
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let analysis = MemoryHistoryAnalyzer().analyze(dataset.historyRecords)
        let kinds = Set(analysis.events.map(\.kind))

        XCTAssertTrue(kinds.contains(.workloadAppeared))
        XCTAssertTrue(kinds.contains(.workloadDisappeared))
        XCTAssertTrue(kinds.contains(.workloadGrowth))
        XCTAssertTrue(kinds.contains(.pressureTransition))
        XCTAssertGreaterThan(analysis.events.count, 3)
    }

    func testFixtureAuditEventsStayWithinPersistedLimits() {
        let dataset = MemoryMonitorUIFixture.makeDataset(
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )
        XCTAssertTrue(dataset.auditEvents.allSatisfy { $0.id.count <= 80 })
        XCTAssertTrue(dataset.auditEvents.allSatisfy { $0.detail.count <= 240 })
        XCTAssertEqual(
            Set(dataset.auditEvents.map(\.id)).count,
            dataset.auditEvents.count
        )
        XCTAssertTrue(dataset.auditEvents.allSatisfy { $0.hasValidFixtureFields })
    }

    func testFixtureRoundTripsThroughHistoryAndAuditStores() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMonitorFixtureTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)
        let dataset = MemoryMonitorUIFixture.makeDataset(now: referenceDate)
        let historyURL = MemoryMonitorStoragePaths.historyFileURL(root: root)
        let auditURL = MemoryMonitorStoragePaths.auditFileURL(root: root)

        let historyStore = HistoryStore(
            fileURL: historyURL,
            compactionRecordThreshold: 1_000,
            compactionByteThreshold: 64 * 1024 * 1024
        )
        for record in dataset.historyRecords {
            _ = try await historyStore.append(record, now: referenceDate)
        }
        let preFlushDiagnostics = await historyStore.diagnostics()
        XCTAssertEqual(
            preFlushDiagnostics.journalRecordCount,
            dataset.historyRecords.count - 1
        )

        let replayStore = HistoryStore(
            fileURL: historyURL,
            compactionRecordThreshold: 1_000,
            compactionByteThreshold: 64 * 1024 * 1024
        )
        let replayedHistory = try await replayStore.load(now: referenceDate)
        XCTAssertEqual(replayedHistory, dataset.historyRecords)

        try await historyStore.flush(now: referenceDate)
        let finalHistoryStore = HistoryStore(
            fileURL: historyURL,
            compactionRecordThreshold: 1_000,
            compactionByteThreshold: 64 * 1024 * 1024
        )
        let finalHistory = try await finalHistoryStore.load(now: referenceDate)
        XCTAssertEqual(finalHistory, dataset.historyRecords)

        let auditStore = ProcessActionAuditStore(fileURL: auditURL)
        for event in dataset.auditEvents {
            _ = try await auditStore.append(event, now: referenceDate)
        }
        try await auditStore.flush(now: referenceDate)
        let finalAuditStore = ProcessActionAuditStore(fileURL: auditURL)
        let reloadedAudit = try await finalAuditStore.load(now: referenceDate)
        XCTAssertEqual(
            Set(reloadedAudit.map(\.id)),
            Set(dataset.auditEvents.map(\.id))
        )

        let expectedFiles = [
            historyURL,
            URL(fileURLWithPath: historyURL.path + ".journal"),
            URL(fileURLWithPath: historyURL.path + ".clock"),
            URL(fileURLWithPath: historyURL.path + ".lock"),
            auditURL,
            URL(fileURLWithPath: auditURL.path + ".clock"),
            URL(fileURLWithPath: auditURL.path + ".lock")
        ]
        for file in expectedFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual(
                (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0 & 0o777,
                0o600,
                file.path
            )
        }
    }
}

private extension ProcessActionAuditEvent {
    /// Tests cannot access the store's fileprivate validation helper; these
    /// checks cover the public invariants that the fixture writer relies on.
    var hasValidFixtureFields: Bool {
        !id.isEmpty
            && !operationID.isEmpty
            && timestamp.timeIntervalSince1970.isFinite
            && !processLabel.isEmpty
            && !detail.isEmpty
    }
}
