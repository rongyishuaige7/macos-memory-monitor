import AppKit
import Darwin
import Foundation
import MemoryMonitorCore

enum DesktopIntegrationCommand: Equatable, Sendable {
    case launchApplication
    case report(includeAuditTokenCheck: Bool)

    static func parse(_ arguments: [String]) throws -> DesktopIntegrationCommand {
        switch arguments {
        case []:
            return .launchApplication
        case let launchArguments
            where launchArguments.allSatisfy({ $0.hasPrefix("-psn_") }):
            return .launchApplication
        case ["--desktop-integration-json"]:
            return .report(includeAuditTokenCheck: false)
        case ["--desktop-integration-json", "--audit-token-dedicated-child"]:
            return .report(includeAuditTokenCheck: true)
        default:
            throw DesktopIntegrationArgumentError.unsupported
        }
    }
}

enum DesktopIntegrationArgumentError: Error, CustomStringConvertible {
    case unsupported

    var description: String {
        "unsupported arguments"
    }
}

enum DesktopLoginItemState: String, Codable, Sendable, Equatable {
    case notRegistered = "not_registered"
    case enabled
    case requiresApproval = "requires_approval"
    case notFound = "not_found"
    case unavailable
    case failed

    init(_ status: LoginLaunchStatus) {
        switch status {
        case .notRegistered: self = .notRegistered
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        case .unavailable: self = .unavailable
        case .failed: self = .failed
        }
    }
}

struct DesktopLoginItemReport: Codable, Sendable, Equatable {
    let state: DesktopLoginItemState

    init(status: LoginLaunchStatus) {
        state = DesktopLoginItemState(status)
    }
}

enum DesktopAuditTokenCheckResult: String, Codable, Sendable, Equatable {
    case notRun = "not_run"
    case passed
    case childLaunchFailed = "child_launch_failed"
    case snapshotUnavailable = "snapshot_unavailable"
    case childExitedBeforeSignal = "child_exited_before_signal"
    case denied
    case signalFailed = "signal_failed"
    case unexpectedTermination = "unexpected_termination"
}

struct DesktopAuditTokenCheckReport: Codable, Sendable, Equatable {
    static let target = "dedicated_child"
    static let signal = "SIGKILL"

    let result: DesktopAuditTokenCheckResult
    let target: String
    let signal: String
    let blockReason: ProcessActionBlockReason?
    let errorCode: Int32?

    init(
        result: DesktopAuditTokenCheckResult,
        blockReason: ProcessActionBlockReason? = nil,
        errorCode: Int32? = nil
    ) {
        self.result = result
        self.target = Self.target
        self.signal = Self.signal
        self.blockReason = blockReason
        self.errorCode = errorCode
    }

    static let notRun = DesktopAuditTokenCheckReport(result: .notRun)
}

enum DesktopIntegrationLimitation: String, Codable, Sendable, Equatable {
    case loginItemStateOnly = "login_item_state_only"
    case loginAfterRestartNotRun = "login_after_restart_not_run"
    case systemPermissionsNotChanged = "system_permissions_not_changed"
    case auditTokenSignalNotRun = "audit_token_signal_not_run"
}

struct DesktopIntegrationReport: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let observedAt: Date
    let product: CompatibilityProductReport
    let platform: CompatibilityPlatformReport
    let loginItem: DesktopLoginItemReport
    let processes: CompatibilityProcessReport
    let auditToken: DesktopAuditTokenCheckReport
    let limitations: [DesktopIntegrationLimitation]

    init(
        snapshot: MonitorSnapshot,
        productVersion: String?,
        buildNumber: String?,
        sourceRevision: String?,
        checkoutState: CompatibilityCheckoutState,
        osMajor: Int,
        osMinor: Int,
        osPatch: Int,
        architecture: String,
        loginStatus: LoginLaunchStatus,
        auditToken: DesktopAuditTokenCheckReport,
        buildInputsDigest: String? = nil,
        provenanceSource: String? = nil
    ) {
        let timestamp = snapshot.timestamp.timeIntervalSince1970
        let validTimestampRange = -62_135_596_800.0...253_402_300_799.0

        schemaVersion = Self.currentSchemaVersion
        observedAt = timestamp.isFinite && validTimestampRange.contains(timestamp)
            ? snapshot.timestamp
            : Date(timeIntervalSince1970: 0)
        product = CompatibilityProductReport(
            version: productVersion,
            build: buildNumber,
            sourceRevision: sourceRevision,
            checkoutState: checkoutState,
            buildInputsDigest: buildInputsDigest,
            provenanceSource: provenanceSource
        )
        platform = CompatibilityPlatformReport(
            osMajor: osMajor,
            osMinor: osMinor,
            osPatch: osPatch,
            architecture: architecture
        )
        loginItem = DesktopLoginItemReport(status: loginStatus)
        processes = CompatibilityProcessReport(snapshot: snapshot)
        self.auditToken = auditToken

        var limitations: [DesktopIntegrationLimitation] = [
            .loginItemStateOnly,
            .loginAfterRestartNotRun,
            .systemPermissionsNotChanged
        ]
        if auditToken.result == .notRun {
            limitations.append(.auditTokenSignalNotRun)
        }
        self.limitations = limitations
    }

    @MainActor
    static func current(
        snapshot: MonitorSnapshot,
        loginStatus: LoginLaunchStatus,
        auditToken: DesktopAuditTokenCheckReport,
        bundle: Bundle = .main,
        provenance: BuildProvenance? = nil
    ) -> DesktopIntegrationReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        let resolved = provenance ?? BuildProvenance.load(from: bundle)
        return DesktopIntegrationReport(
            snapshot: snapshot,
            productVersion: resolved?.productVersion ?? bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            buildNumber: resolved?.productBuild
                ?? bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            sourceRevision: resolved?.sourceRevision,
            checkoutState: resolved?.checkoutState ?? .unknown,
            osMajor: version.majorVersion,
            osMinor: version.minorVersion,
            osPatch: version.patchVersion,
            architecture: resolved?.architecture ?? architecture,
            loginStatus: loginStatus,
            auditToken: auditToken,
            buildInputsDigest: resolved?.buildInputsDigest,
            provenanceSource: resolved == nil ? "unknown" : "bundle"
        )
    }
}

@MainActor
enum DesktopIntegrationRunner {
    static func run(includeAuditTokenCheck: Bool) async -> DesktopIntegrationReport {
        // ServiceManagement resolves mainApp through the current AppKit
        // application. Creating that context does not start the SwiftUI app,
        // its sampling loop, or either persistent store.
        _ = NSApplication.shared
        let loginStatus = LiveLoginLaunchRuntime().status()
        let snapshot = await Task.detached(priority: .utility) {
            MonitorSampler().sample()
        }.value
        let auditToken = includeAuditTokenCheck
            ? await DedicatedChildAuditTokenCheck.run()
            : .notRun

        return DesktopIntegrationReport.current(
            snapshot: snapshot,
            loginStatus: loginStatus,
            auditToken: auditToken
        )
    }
}

@MainActor
private enum DedicatedChildAuditTokenCheck {
    static func run() async -> DesktopAuditTokenCheckReport {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]

        do {
            try process.run()
        } catch {
            return DesktopAuditTokenCheckReport(result: .childLaunchFailed)
        }

        defer {
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }

        let sampler = ProcessSampler()
        var initialSnapshot: ProcessSnapshot?
        for _ in 0..<40 {
            if let snapshot = sampler.sample(pid: process.processIdentifier) {
                initialSnapshot = snapshot
                break
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return DesktopAuditTokenCheckReport(result: .snapshotUnavailable)
            }
        }
        guard let initialSnapshot else {
            return DesktopAuditTokenCheckReport(result: .snapshotUnavailable)
        }

        let runtime = LiveProcessActionRuntime(
            sampler: sampler,
            policy: ProcessActionPolicy(
                currentUserID: UInt32(getuid()),
                monitorPID: Int32(getpid())
            )
        )
        switch await runtime.sendForce(to: initialSnapshot) {
        case .sent:
            process.waitUntilExit()
            guard process.terminationReason == .uncaughtSignal,
                  process.terminationStatus == SIGKILL else {
                return DesktopAuditTokenCheckReport(result: .unexpectedTermination)
            }
            return DesktopAuditTokenCheckReport(result: .passed)
        case .alreadyExited:
            return DesktopAuditTokenCheckReport(result: .childExitedBeforeSignal)
        case .denied(let reason):
            return DesktopAuditTokenCheckReport(result: .denied, blockReason: reason)
        case .failed(let code):
            return DesktopAuditTokenCheckReport(result: .signalFailed, errorCode: code)
        }
    }
}

@main
@MainActor
enum MemoryMonitorEntryPoint {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            switch try DesktopIntegrationCommand.parse(arguments) {
            case .launchApplication:
                MemoryMonitorApp.main()
            case .report(let includeAuditTokenCheck):
                if includeAuditTokenCheck,
                   ProcessInfo.processInfo.environment[
                    "MEMORY_MONITOR_ALLOW_AUDIT_TOKEN_TEST"
                   ] != "1" {
                    writeStandardError(
                        "memory-monitor-app: audit-token check requires explicit opt-in\n"
                    )
                    Darwin.exit(2)
                }
                let report = await DesktopIntegrationRunner.run(
                    includeAuditTokenCheck: includeAuditTokenCheck
                )
                try write(report: report)
            }
        } catch is DesktopIntegrationArgumentError {
            writeStandardError(
                "memory-monitor-app: unsupported arguments; desktop diagnostics "
                    + "accept only --desktop-integration-json and the dedicated-child option\n"
            )
            Darwin.exit(2)
        } catch {
            writeStandardError("memory-monitor-app: unable to encode desktop report\n")
            Darwin.exit(1)
        }
    }

    private static func write(report: DesktopIntegrationReport) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func writeStandardError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
