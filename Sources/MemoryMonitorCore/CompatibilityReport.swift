import Foundation

public enum CompatibilityCheckoutState: String, Codable, Sendable, Equatable {
    case clean
    case modified
    case unknown
}

public enum CompatibilityReportLimitation: String, Codable, Sendable, Equatable {
    case loginItemRegistrationNotRun = "login_item_registration_not_run"
    case auditTokenSignalNotRun = "audit_token_signal_not_run"
    case systemPermissionsNotChanged = "system_permissions_not_changed"
}

public struct CompatibilityProductReport: Codable, Sendable, Equatable {
    public let version: String?
    public let build: String?
    public let sourceRevision: String?
    public let checkoutState: CompatibilityCheckoutState

    public init(
        version: String?,
        build: String?,
        sourceRevision: String?,
        checkoutState: CompatibilityCheckoutState
    ) {
        self.version = CompatibilityReportSanitizer.text(version, limit: 64)
        self.build = CompatibilityReportSanitizer.text(build, limit: 64)
        self.sourceRevision = CompatibilityReportSanitizer.text(sourceRevision, limit: 64)
        self.checkoutState = checkoutState
    }
}

public struct CompatibilityPlatformReport: Codable, Sendable, Equatable {
    public let osMajor: Int
    public let osMinor: Int
    public let osPatch: Int
    public let architecture: String

    public init(
        osMajor: Int,
        osMinor: Int,
        osPatch: Int,
        architecture: String
    ) {
        self.osMajor = max(osMajor, 0)
        self.osMinor = max(osMinor, 0)
        self.osPatch = max(osPatch, 0)
        self.architecture = CompatibilityReportSanitizer.text(architecture, limit: 32)
            ?? "unknown"
    }
}

public struct CompatibilityMetricReport: Codable, Sendable, Equatable {
    public let quality: SampleQuality
    public let message: String?
    public let usable: Bool

    public init(status: SampleStatus, usable: Bool) {
        self.quality = status.quality
        self.message = CompatibilityReportSanitizer.text(status.message, limit: 256)
        self.usable = usable
    }
}

public struct CompatibilityProcessReport: Codable, Sendable, Equatable {
    public let quality: SampleQuality
    public let message: String?
    public let usable: Bool
    public let samplingPerformed: Bool
    public let sampledCount: Int
    public let listedCount: Int
    public let coverageFraction: Double?
    public let permissionDeniedCount: Int?
    public let readableCoverageFraction: Double?

    public init(snapshot: MonitorSnapshot) {
        let sampledCount = max(snapshot.sampledProcessCount, 0)
        let listedCount = max(snapshot.listedProcessCount, sampledCount)

        self.quality = snapshot.processStatus.quality
        self.message = CompatibilityReportSanitizer.text(
            snapshot.processStatus.message,
            limit: 256
        )
        self.usable = snapshot.processDataIsUsable
        self.samplingPerformed = snapshot.didSampleProcesses
        self.sampledCount = sampledCount
        self.listedCount = listedCount
        self.permissionDeniedCount = snapshot.permissionDeniedProcessCount
        let readableCount = listedCount - snapshot.permissionDeniedProcessCount
        self.readableCoverageFraction = readableCount > 0 ? Double(sampledCount) / Double(readableCount) : nil
        if listedCount > 0 {
            self.coverageFraction = min(
                max(Double(sampledCount) / Double(listedCount), 0),
                1
            )
        } else {
            self.coverageFraction = nil
        }
    }
}

public struct CompatibilitySamplingReport: Codable, Sendable, Equatable {
    public let mode: SamplingMode
    public let totalDurationMilliseconds: Double
    public let processDurationMilliseconds: Double?
    public let system: CompatibilityMetricReport
    public let cpu: CompatibilityMetricReport
    public let gpu: CompatibilityMetricReport
    public let processes: CompatibilityProcessReport

    public init(snapshot: MonitorSnapshot) {
        self.mode = snapshot.samplingMode
        self.totalDurationMilliseconds = snapshot.diagnostics.totalDurationMilliseconds
        self.processDurationMilliseconds = snapshot.diagnostics.processDurationMilliseconds
        self.system = CompatibilityMetricReport(
            status: snapshot.systemStatus,
            usable: snapshot.systemDataIsUsable
        )
        self.cpu = CompatibilityMetricReport(
            status: snapshot.cpuStatus,
            usable: snapshot.cpuTime != nil && snapshot.cpuStatus.hasFiniteSampleTimestamp
        )
        let gpuIsUsable = snapshot.gpuUsageFraction.map {
            $0.isFinite && (0...1).contains($0)
        } ?? false
        self.gpu = CompatibilityMetricReport(
            status: snapshot.gpuStatus,
            usable: gpuIsUsable && snapshot.gpuStatus.hasFiniteSampleTimestamp
        )
        self.processes = CompatibilityProcessReport(snapshot: snapshot)
    }
}

public struct CompatibilityProbeReport: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let automatedLimitations: [CompatibilityReportLimitation] = [
        .loginItemRegistrationNotRun,
        .auditTokenSignalNotRun,
        .systemPermissionsNotChanged
    ]

    public let schemaVersion: Int
    public let observedAt: Date
    public let product: CompatibilityProductReport
    public let platform: CompatibilityPlatformReport
    public let sampling: CompatibilitySamplingReport
    public let limitations: [CompatibilityReportLimitation]

    public init(
        snapshot: MonitorSnapshot,
        productVersion: String? = nil,
        buildNumber: String? = nil,
        sourceRevision: String? = nil,
        checkoutState: CompatibilityCheckoutState = .unknown,
        osMajor: Int,
        osMinor: Int,
        osPatch: Int,
        architecture: String
    ) {
        let timestamp = snapshot.timestamp.timeIntervalSince1970
        self.schemaVersion = Self.currentSchemaVersion
        self.observedAt = timestamp.isFinite
            ? snapshot.timestamp
            : Date(timeIntervalSince1970: 0)
        self.product = CompatibilityProductReport(
            version: productVersion,
            build: buildNumber,
            sourceRevision: sourceRevision,
            checkoutState: checkoutState
        )
        self.platform = CompatibilityPlatformReport(
            osMajor: osMajor,
            osMinor: osMinor,
            osPatch: osPatch,
            architecture: architecture
        )
        self.sampling = CompatibilitySamplingReport(snapshot: snapshot)
        self.limitations = Self.automatedLimitations
    }

    public static func current(
        snapshot: MonitorSnapshot,
        productVersion: String? = nil,
        buildNumber: String? = nil,
        sourceRevision: String? = nil,
        checkoutState: CompatibilityCheckoutState = .unknown
    ) -> CompatibilityProbeReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        return CompatibilityProbeReport(
            snapshot: snapshot,
            productVersion: productVersion,
            buildNumber: buildNumber,
            sourceRevision: sourceRevision,
            checkoutState: checkoutState,
            osMajor: version.majorVersion,
            osMinor: version.minorVersion,
            osPatch: version.patchVersion,
            architecture: architecture
        )
    }
}

private enum CompatibilityReportSanitizer {
    static func text(_ value: String?, limit: Int) -> String? {
        guard let value, limit > 0 else { return nil }
        let scalars = value.unicodeScalars.filter { scalar in
            let codePoint = scalar.value
            return codePoint >= 0x20 && !(0x7F...0x9F).contains(codePoint)
        }
        let sanitized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }
        return String(sanitized.prefix(limit))
    }
}
