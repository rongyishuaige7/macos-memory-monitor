import Foundation
import XCTest
@testable import MemoryMonitorApp
@testable import MemoryMonitorCore

@MainActor
final class DesktopIntegrationTests: XCTestCase {
    func testCommandParserKeepsNormalAndLaunchServicesStartsInGUI() throws {
        XCTAssertEqual(
            try DesktopIntegrationCommand.parse([]),
            .launchApplication
        )
        XCTAssertEqual(
            try DesktopIntegrationCommand.parse(["-psn_0_12345"]),
            .launchApplication
        )
    }

    func testCommandParserRequiresExactDesktopArguments() throws {
        XCTAssertEqual(
            try DesktopIntegrationCommand.parse(["--desktop-integration-json"]),
            .report(includeAuditTokenCheck: false)
        )
        XCTAssertEqual(
            try DesktopIntegrationCommand.parse([
                "--desktop-integration-json",
                "--audit-token-dedicated-child"
            ]),
            .report(includeAuditTokenCheck: true)
        )
        XCTAssertThrowsError(
            try DesktopIntegrationCommand.parse(["--audit-token-dedicated-child"])
        )
        XCTAssertThrowsError(
            try DesktopIntegrationCommand.parse([
                "--desktop-integration-json",
                "--audit-token-dedicated-child",
                "4242"
            ])
        )
        XCTAssertThrowsError(
            try DesktopIntegrationCommand.parse(["--unknown"])
        )
    }

    func testReadOnlyReportIsRedactedAndKeepsExplicitLimitations() throws {
        let report = makeReport(
            loginStatus: .unavailable("private login failure"),
            auditToken: .notRun
        )

        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.loginItem.state, .unavailable)
        XCTAssertEqual(report.auditToken.result, .notRun)
        XCTAssertEqual(report.auditToken.target, "dedicated_child")
        XCTAssertEqual(report.limitations, [
            .loginItemStateOnly,
            .loginAfterRestartNotRun,
            .systemPermissionsNotChanged,
            .auditTokenSignalNotRun
        ])

        let data = try JSONEncoder().encode(report)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("4242"))
        XCTAssertFalse(json.contains("private-child"))
        XCTAssertFalse(json.contains("/Users/private/secret"))
        XCTAssertFalse(json.contains("private login failure"))
    }

    func testExecutedAuditCheckRemovesOnlyItsNotRunLimitation() {
        let report = makeReport(
            loginStatus: .requiresApproval,
            auditToken: DesktopAuditTokenCheckReport(result: .passed)
        )

        XCTAssertEqual(report.loginItem.state, .requiresApproval)
        XCTAssertEqual(report.auditToken.result, .passed)
        XCTAssertEqual(report.auditToken.signal, "SIGKILL")
        XCTAssertEqual(report.limitations, [
            .loginItemStateOnly,
            .loginAfterRestartNotRun,
            .systemPermissionsNotChanged
        ])
    }

    func testReportClampsInvalidTimestampAndSanitizesMetadata() {
        let snapshot = makeSnapshot(timestamp: Date(timeIntervalSince1970: .infinity))
        let report = DesktopIntegrationReport(
            snapshot: snapshot,
            productVersion: "1.0.4\nsecret",
            buildNumber: "14\t",
            sourceRevision: "abc\rdef",
            checkoutState: .modified,
            osMajor: -1,
            osMinor: -2,
            osPatch: -3,
            architecture: "arm64\nprivate",
            loginStatus: .notRegistered,
            auditToken: .notRun
        )

        XCTAssertEqual(report.observedAt, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(report.product.version, "1.0.4secret")
        XCTAssertEqual(report.product.build, "14")
        XCTAssertEqual(report.product.sourceRevision, "abcdef")
        XCTAssertEqual(report.platform.osMajor, 0)
        XCTAssertEqual(report.platform.osMinor, 0)
        XCTAssertEqual(report.platform.osPatch, 0)
        XCTAssertEqual(report.platform.architecture, "arm64private")
    }

    func testCurrentReportUsesBundleProvenance() {
        let provenance = BuildProvenance(
            sourceRevision: "abc1234",
            checkoutState: .clean,
            buildInputsDigest: String(repeating: "a", count: 64),
            productVersion: "1.4.2",
            productBuild: "142",
            architecture: "arm64",
            toolchainVersion: "Swift 6.0"
        )
        let report = DesktopIntegrationReport.current(
            snapshot: makeSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
            loginStatus: .notRegistered,
            auditToken: .notRun,
            provenance: provenance
        )

        XCTAssertEqual(report.product.version, "1.4.2")
        XCTAssertEqual(report.product.build, "142")
        XCTAssertEqual(report.product.sourceRevision, "abc1234")
        XCTAssertEqual(report.product.checkoutState, .clean)
        XCTAssertEqual(report.product.buildInputsDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(report.product.provenanceSource, "bundle")
    }

    func testCurrentReportWithoutProvenanceDoesNotInventSource() {
        let report = DesktopIntegrationReport.current(
            snapshot: makeSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
            loginStatus: .notRegistered,
            auditToken: .notRun,
            provenance: nil
        )

        XCTAssertNil(report.product.sourceRevision)
        XCTAssertEqual(report.product.checkoutState, .unknown)
        XCTAssertNil(report.product.buildInputsDigest)
        XCTAssertEqual(report.product.provenanceSource, "unknown")
    }

    private func makeReport(
        loginStatus: LoginLaunchStatus,
        auditToken: DesktopAuditTokenCheckReport
    ) -> DesktopIntegrationReport {
        DesktopIntegrationReport(
            snapshot: makeSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000)),
            productVersion: "1.0.4",
            buildNumber: "14",
            sourceRevision: "abcdef",
            checkoutState: .clean,
            osMajor: 26,
            osMinor: 5,
            osPatch: 1,
            architecture: "arm64",
            loginStatus: loginStatus,
            auditToken: auditToken
        )
    }

    private func makeSnapshot(timestamp: Date) -> MonitorSnapshot {
        let process = ProcessSnapshot(
            identity: ProcessIdentity(
                pid: 4242,
                startTimeSeconds: 1_700_000_000,
                startTimeMicroseconds: 42
            ),
            parentPID: 1,
            userID: 501,
            isSystem: false,
            name: "private-child",
            executablePath: "/Users/private/secret",
            residentBytes: 1,
            physicalFootprintBytes: 2,
            virtualBytes: 3,
            userTimeNanos: 0,
            systemTimeNanos: 0,
            threadCount: 1
        )
        return MonitorSnapshot(
            timestamp: timestamp,
            system: nil,
            systemStatus: .unavailable(),
            cpuTime: nil,
            cpuStatus: .unavailable(),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(),
            processes: [process],
            processStatus: .available(at: timestamp),
            listedProcessCount: 2,
            sampledProcessCount: 1,
            groups: [],
            samplingMode: .full,
            diagnostics: SamplingDiagnostics(
                mode: .full,
                totalDurationMilliseconds: 1,
                processDurationMilliseconds: 1,
                processSamplingPerformed: true,
                processCount: 1,
                listedProcessCount: 2
            )
        )
    }
}
