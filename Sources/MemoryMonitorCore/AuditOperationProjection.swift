import Foundation

/// Operation-level interpretation of durable audit events. This type never
/// infers success from missing evidence: an operation with only an intent, or
/// with a sent request but no terminal event, remains explicitly unconfirmed.
public enum AuditOperationState: String, Codable, Sendable, Equatable {
    case inProgress
    case intentRecorded
    case requestSentUnconfirmed
    case resultUnconfirmed
    case incomplete
    case completed
    case denied
    case failed
    case cancelled
    case timedOut

    public var displayName: String {
        switch self {
        case .inProgress: return "进行中"
        case .intentRecorded: return "仅确认，结果未确认"
        case .requestSentUnconfirmed: return "已发送，结果未确认"
        case .resultUnconfirmed: return "结果未确认"
        case .incomplete: return "记录不完整"
        case .completed: return "已完成"
        case .denied: return "已拒绝"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .timedOut: return "等待超时"
        }
    }
}

public struct AuditOperationProjection: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let action: ProcessActionKind
    public let processLabel: String
    public let applicationName: String?
    public let state: AuditOperationState
    public let hasIntent: Bool
    public let hasSignalSent: Bool
    public let hasTerminal: Bool
    public let terminalOutcome: ProcessActionOutcome?
    public let firstEventAt: Date
    public let lastEventAt: Date
    public let eventCount: Int
    public let isIncomplete: Bool
    public let isLegacyTerminalOnly: Bool

    public init(
        id: String,
        action: ProcessActionKind,
        processLabel: String,
        applicationName: String?,
        state: AuditOperationState,
        hasIntent: Bool,
        hasSignalSent: Bool,
        hasTerminal: Bool,
        terminalOutcome: ProcessActionOutcome?,
        firstEventAt: Date,
        lastEventAt: Date,
        eventCount: Int,
        isIncomplete: Bool,
        isLegacyTerminalOnly: Bool
    ) {
        self.id = id
        self.action = action
        self.processLabel = processLabel
        self.applicationName = applicationName
        self.state = state
        self.hasIntent = hasIntent
        self.hasSignalSent = hasSignalSent
        self.hasTerminal = hasTerminal
        self.terminalOutcome = terminalOutcome
        self.firstEventAt = firstEventAt
        self.lastEventAt = lastEventAt
        self.eventCount = max(eventCount, 1)
        self.isIncomplete = isIncomplete
        self.isLegacyTerminalOnly = isLegacyTerminalOnly
    }
}

public enum AuditOperationProjector {
    public static func project(
        events: [ProcessActionAuditEvent],
        activeOperationIDs: Set<String>
    ) -> [AuditOperationProjection] {
        let grouped = Dictionary(grouping: events, by: \.operationID)
        var projections: [AuditOperationProjection] = []
        projections.reserveCapacity(grouped.count)

        for (operationID, rawEvents) in grouped {
            let ordered = rawEvents.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.id < $1.id
            }
            guard let first = ordered.first, let last = ordered.last else { continue }
            let hasIntent = ordered.contains { $0.phase == .intent }
            let hasSignalSent = ordered.contains { $0.phase == .signalSent }
            let terminalEvents = ordered.filter { $0.phase == .terminal }
            let terminal = terminalEvents.last
            let terminalOutcome = terminal?.outcome
            let hasTerminal = terminal != nil
            // Old terminal-only records defaulted operationID to the event id.
            // A terminal-only operation whose operationID differs has lost its
            // preceding records through retention and must be marked incomplete.
            let isLegacyTerminalOnly = !hasIntent && !hasSignalSent && hasTerminal
                && ordered.allSatisfy { $0.operationID == $0.id }
            let isIncomplete = (!hasIntent && hasSignalSent)
                || (!hasIntent && !hasSignalSent && hasTerminal && !isLegacyTerminalOnly)

            let state: AuditOperationState
            if let terminalOutcome {
                switch terminalOutcome {
                case .completed: state = .completed
                case .denied: state = .denied
                case .failed: state = .failed
                case .cancelled: state = .cancelled
                case .timedOut: state = .timedOut
                }
            } else if activeOperationIDs.contains(operationID) {
                state = .inProgress
            } else if hasSignalSent {
                state = .requestSentUnconfirmed
            } else if hasIntent {
                state = .intentRecorded
            } else {
                state = .incomplete
            }

            projections.append(AuditOperationProjection(
                id: operationID,
                action: last.action,
                processLabel: last.processLabel,
                applicationName: last.applicationName,
                state: state,
                hasIntent: hasIntent,
                hasSignalSent: hasSignalSent,
                hasTerminal: hasTerminal,
                terminalOutcome: terminalOutcome,
                firstEventAt: first.timestamp,
                lastEventAt: last.timestamp,
                eventCount: ordered.count,
                isIncomplete: isIncomplete,
                isLegacyTerminalOnly: isLegacyTerminalOnly
            ))
        }

        return projections.sorted {
            if $0.lastEventAt != $1.lastEventAt { return $0.lastEventAt > $1.lastEventAt }
            return $0.id < $1.id
        }
    }
}
