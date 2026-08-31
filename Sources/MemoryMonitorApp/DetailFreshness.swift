import Foundation
import MemoryMonitorCore

/// Describes which process/workload snapshot a detail view is presenting.
/// This is deliberately independent of SwiftUI so the distinction between a
/// current sample and a retained snapshot can be tested without launching
/// the app.
struct MonitorDetailDataStatus: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case loading
        case current
        case partial
        case retained
        case failed
        case unavailable
    }

    enum RetentionReason: String, Equatable, Sendable {
        case background
        case insufficientCoverage
        case expired
        case invalidTimestamp
        case targetUnavailable
    }

    /// Keep this aligned with the process freshness window used by the
    /// health panel. A retained snapshot remains observable after this point,
    /// but it must not be described as a current detail sample.
    static let staleAfter: TimeInterval = 120
    static let futureTolerance: TimeInterval = 5

    let kind: Kind
    let retentionReason: RetentionReason?
    /// The timestamp of the data shown in the detail view, when known. For a
    /// failed or incomplete pass this is the last successful process sample.
    let sampledAt: Date?
    let observedAt: Date?
    let retainedItemCount: Int
    let sampledItemCount: Int
    let listedItemCount: Int
    let message: String?

    var hasRetainedData: Bool {
        retainedItemCount > 0
    }

    var sampleAge: TimeInterval? {
        guard let sampledAt,
              let observedAt else {
            return nil
        }
        let age = observedAt.timeIntervalSince(sampledAt)
        guard age.isFinite else { return nil }
        return max(age, 0)
    }

    var coverageFraction: Double? {
        guard listedItemCount > 0 else { return nil }
        let coverage = Double(sampledItemCount) / Double(listedItemCount)
        return coverage.isFinite ? min(max(coverage, 0), 1) : nil
    }

    /// Resolves the data contract used by both process and workload details.
    /// `lastSuccessfulSampledAt` is supplied by the live model because a
    /// failed pass intentionally carries no timestamp in `processStatus`.
    static func resolve(
        processStatus: SampleStatus,
        samplingDiagnostics: SamplingDiagnostics,
        retainedItemCount: Int,
        targetPresent: Bool,
        observedAt: Date?,
        lastSuccessfulSampledAt: Date? = nil
    ) -> MonitorDetailDataStatus {
        let retainedCount = max(retainedItemCount, 0)
        let sampledCount = max(samplingDiagnostics.processCount, 0)
        let listedCount = max(samplingDiagnostics.listedProcessCount, sampledCount)
        let safeObservedAt = finiteDate(observedAt)
        let currentSampledAt = finiteDate(processStatus.sampledAt)
        let retainedSampledAt = finiteDate(lastSuccessfulSampledAt) ?? currentSampledAt
        let freshness = freshness(
            sampledAt: currentSampledAt,
            observedAt: safeObservedAt
        )
        let hasUsableCoverage = samplingDiagnostics.processSamplingPerformed
            && sampledCount > 0
            && listedCount > 0
            && (Double(sampledCount) / Double(listedCount)).isFinite
            && Double(sampledCount) / Double(listedCount)
                >= ProcessSamplingResult.minimumUsableCoverage

        func make(
            kind: Kind,
            reason: RetentionReason? = nil,
            sampledAt: Date? = retainedSampledAt,
            message: String? = processStatus.message
        ) -> MonitorDetailDataStatus {
            MonitorDetailDataStatus(
                kind: kind,
                retentionReason: reason,
                sampledAt: sampledAt,
                observedAt: safeObservedAt,
                retainedItemCount: retainedCount,
                sampledItemCount: sampledCount,
                listedItemCount: listedCount,
                message: message
            )
        }

        // A detail window can outlive the row that opened it. Resolve the
        // target boundary before sampling quality so a healthy global pass
        // cannot describe a missing process or workload as current.
        guard targetPresent else {
            if retainedCount > 0 {
                return make(
                    kind: .retained,
                    reason: .targetUnavailable,
                    message: nil
                )
            }
            return make(
                kind: .unavailable,
                reason: .targetUnavailable,
                sampledAt: nil,
                message: nil
            )
        }

        // A background pass intentionally does not touch processStatus. The
        // retained rows are therefore still observable, but are not current.
        if !samplingDiagnostics.processSamplingPerformed {
            return retainedCount > 0
                ? make(kind: .retained, reason: .background)
                : make(kind: .loading, sampledAt: nil, message: nil)
        }

        switch processStatus.quality {
        case .error:
            return make(kind: .failed)
        case .unavailable:
            return make(kind: .unavailable)
        case .available, .estimated:
            guard hasUsableCoverage else {
                guard retainedCount > 0 else {
                    return make(kind: .unavailable)
                }
                return make(
                    kind: .retained,
                    reason: retentionReason(for: freshness, hasUsableCoverage: false)
                )
            }

            switch freshness {
            case .fresh:
                let isPartial = processStatus.quality == .estimated
                    || sampledCount < listedCount
                return make(
                    kind: isPartial ? .partial : .current,
                    sampledAt: currentSampledAt
                )
            case .expired, .invalid:
                guard retainedCount > 0 else {
                    return make(kind: .unavailable, sampledAt: nil)
                }
                return make(
                    kind: .retained,
                    reason: retentionReason(for: freshness, hasUsableCoverage: true)
                )
            }
        }
    }

    private enum Freshness {
        case fresh
        case expired
        case invalid
    }

    private static func freshness(
        sampledAt: Date?,
        observedAt: Date?
    ) -> Freshness {
        guard let sampledAt,
              let observedAt else {
            return .invalid
        }
        let age = observedAt.timeIntervalSince(sampledAt)
        guard age.isFinite else { return .invalid }
        if age < -Self.futureTolerance { return .invalid }
        if age > Self.staleAfter { return .expired }
        return .fresh
    }

    private static func retentionReason(
        for freshness: Freshness,
        hasUsableCoverage: Bool
    ) -> RetentionReason {
        guard hasUsableCoverage else { return .insufficientCoverage }
        switch freshness {
        case .fresh:
            // This branch is only reachable for defensive callers that pass
            // inconsistent metadata. Coverage is the safer explanation.
            return .insufficientCoverage
        case .expired:
            return .expired
        case .invalid:
            return .invalidTimestamp
        }
    }

    private static func finiteDate(_ date: Date?) -> Date? {
        guard let date,
              date.timeIntervalSince1970.isFinite else {
            return nil
        }
        return date
    }
}
