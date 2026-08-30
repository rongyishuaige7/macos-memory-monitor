import Foundation

/// Deterministic, local-only data used by the isolated desktop UI check.
///
/// The fixture deliberately lives beside the public persistence models so the
/// writer and the app exercise the same constructors and validation rules as
/// production callers. It is never selected unless the app receives the
/// explicit `MEMORY_MONITOR_UI_CHECK_FIXTURE=1` environment flag.
public enum MemoryMonitorUIFixture {
    public static let environmentKey = "MEMORY_MONITOR_UI_CHECK_FIXTURE"

    public struct Dataset: Sendable {
        public let referenceDate: Date
        public let snapshot: MonitorSnapshot
        public let historyRecords: [MemoryHistoryRecord]
        public let auditEvents: [ProcessActionAuditEvent]

        public init(
            referenceDate: Date,
            snapshot: MonitorSnapshot,
            historyRecords: [MemoryHistoryRecord],
            auditEvents: [ProcessActionAuditEvent]
        ) {
            self.referenceDate = referenceDate
            self.snapshot = snapshot
            self.historyRecords = historyRecords
            self.auditEvents = auditEvents
        }

        /// Reuses stable process identities while moving source timestamps to
        /// the caller's sampling instant. This keeps a long-running UI check
        /// fresh without manufacturing a new selection target every pass.
        public func snapshot(at date: Date) -> MonitorSnapshot {
            let timestamp = Self.validDate(date, fallback: referenceDate)
            let source = snapshot
            let system = source.system.map { value in
                SystemMemorySnapshot(
                    timestamp: timestamp,
                    totalBytes: value.totalBytes,
                    pageSize: value.pageSize,
                    freeBytes: value.freeBytes,
                    activeBytes: value.activeBytes,
                    inactiveBytes: value.inactiveBytes,
                    speculativeBytes: value.speculativeBytes,
                    wiredBytes: value.wiredBytes,
                    purgeableBytes: value.purgeableBytes,
                    compressedBytes: value.compressedBytes,
                    throttledPages: value.throttledPages,
                    swapTotalBytes: value.swapTotalBytes,
                    swapUsedBytes: value.swapUsedBytes,
                    swapFreeBytes: value.swapFreeBytes
                )
            }
            let systemStatus = Self.retimestamp(source.systemStatus, at: timestamp)
            let cpuStatus = Self.retimestamp(source.cpuStatus, at: timestamp)
            let gpuStatus = Self.retimestamp(source.gpuStatus, at: timestamp)
            let processStatus = Self.retimestamp(source.processStatus, at: timestamp)
            let diagnostics = SamplingDiagnostics(
                mode: .full,
                totalDurationMilliseconds: source.diagnostics.totalDurationMilliseconds,
                processDurationMilliseconds: source.diagnostics.processDurationMilliseconds,
                processSamplingPerformed: true,
                processCount: source.processes.count,
                listedProcessCount: source.processes.count
            )
            return MonitorSnapshot(
                timestamp: timestamp,
                system: system,
                systemStatus: systemStatus,
                cpuTime: source.cpuTime,
                cpuStatus: cpuStatus,
                gpuUsageFraction: source.gpuUsageFraction,
                gpuStatus: gpuStatus,
                processes: source.processes,
                processStatus: processStatus,
                listedProcessCount: source.processes.count,
                sampledProcessCount: source.processes.count,
                groups: source.groups,
                samplingMode: .full,
                diagnostics: diagnostics
            )
        }

        private static func retimestamp(
            _ status: SampleStatus,
            at date: Date
        ) -> SampleStatus {
            switch status.quality {
            case .available:
                return .available(at: date, message: status.message)
            case .estimated:
                return .estimated(at: date, message: status.message)
            case .unavailable:
                return .unavailable(message: status.message)
            case .error:
                return .error(status.message ?? "fixture 采样失败")
            }
        }

        private static func validDate(_ date: Date, fallback: Date) -> Date {
            guard date.timeIntervalSince1970.isFinite else { return fallback }
            return date
        }
    }

    /// Returns true only for the explicit value used by the launcher. A
    /// malformed or inherited value must never switch a normal launch to
    /// synthetic data.
    public static func isEnabled(environment: [String: String]) -> Bool {
        environment[environmentKey] == "1"
    }

    public static func makeDataset(now: Date = Date()) -> Dataset {
        let referenceDate = alignedDate(now)
        let processes = makeProcesses(referenceDate: referenceDate)
        let groups = makeGroups(processes: processes)
        let snapshot = makeSnapshot(
            referenceDate: referenceDate,
            processes: processes,
            groups: groups
        )
        return Dataset(
            referenceDate: referenceDate,
            snapshot: snapshot,
            historyRecords: makeHistoryRecords(
                referenceDate: referenceDate,
                groups: groups
            ),
            auditEvents: makeAuditEvents(referenceDate: referenceDate)
        )
    }

    private static let gib: UInt64 = 1_073_741_824
    private static let mib: UInt64 = 1_048_576

    private static func alignedDate(_ date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite else {
            return Date(timeIntervalSince1970: 1_800_000_000)
        }
        let aligned = floor(seconds / 60) * 60
        guard aligned.isFinite,
              aligned >= 1,
              aligned <= 253_402_300_799 else {
            return Date(timeIntervalSince1970: 1_800_000_000)
        }
        return Date(timeIntervalSince1970: aligned)
    }

    private static func makeProcesses(referenceDate: Date) -> [ProcessSnapshot] {
        let startSeconds = UInt64(max(referenceDate.timeIntervalSince1970 - 3_600, 1))
        let userID: UInt32 = 501

        func identity(_ index: UInt64) -> ProcessIdentity {
            ProcessIdentity(
                pid: Int32(71_000 + index),
                startTimeSeconds: startSeconds + index,
                startTimeMicroseconds: index * 10_000
            )
        }

        func process(
            _ index: UInt64,
            name: String,
            app: String,
            parentPID: Int32,
            footprint: UInt64,
            resident: UInt64,
            estimated: Bool,
            workingDirectory: String
        ) -> ProcessSnapshot {
            ProcessSnapshot(
                identity: identity(index),
                parentPID: parentPID,
                userID: userID,
                isSystem: false,
                name: name,
                // An absent path keeps this synthetic target un-actionable
                // even if a future UI accidentally exposes an operation row.
                executablePath: nil,
                applicationName: app,
                bundleIdentifier: "com.example.memory-monitor.fixture.\(index)",
                residentBytes: resident,
                physicalFootprintBytes: footprint,
                physicalFootprintIsEstimated: estimated,
                workingDirectoryLabel: workingDirectory,
                virtualBytes: footprint * 3,
                userTimeNanos: 12_000_000_000 + index * 1_000_000_000,
                systemTimeNanos: 3_000_000_000 + index * 250_000_000,
                threadCount: Int32(8 + index)
            )
        }

        let primaryRootPID = Int32(71_000)
        let secondaryRootPID = Int32(71_004)
        return [
            process(
                0,
                name: "Fixture Primary Host Long Display Name Alpha",
                app: "Fixture Workspace Primary Application Alpha",
                parentPID: 1,
                footprint: 1_850 * mib,
                resident: 1_420 * mib,
                estimated: false,
                workingDirectory: "fixture-primary-project"
            ),
            process(
                1,
                name: "Fixture Primary Worker Long Display Name Bravo",
                app: "Fixture Workspace Primary Application Bravo",
                parentPID: primaryRootPID,
                footprint: 1_520 * mib,
                resident: 1_180 * mib,
                estimated: true,
                workingDirectory: "fixture-primary-project"
            ),
            process(
                2,
                name: "Fixture Primary Worker Long Display Name Charlie",
                app: "Fixture Workspace Primary Application Charlie",
                parentPID: primaryRootPID,
                footprint: 1_210 * mib,
                resident: 940 * mib,
                estimated: false,
                workingDirectory: "fixture-primary-project"
            ),
            process(
                3,
                name: "Fixture Primary Worker Long Display Name Delta",
                app: "Fixture Workspace Primary Application Delta",
                parentPID: primaryRootPID,
                footprint: 930 * mib,
                resident: 710 * mib,
                estimated: false,
                workingDirectory: "fixture-primary-project"
            ),
            process(
                4,
                name: "Fixture Secondary Host Long Display Name Echo",
                app: "Fixture Workspace Secondary Application Echo",
                parentPID: 1,
                footprint: 1_140 * mib,
                resident: 860 * mib,
                estimated: false,
                workingDirectory: "fixture-secondary-project"
            ),
            process(
                5,
                name: "Fixture Secondary Worker Long Display Name Foxtrot",
                app: "Fixture Workspace Secondary Application Foxtrot",
                parentPID: secondaryRootPID,
                footprint: 880 * mib,
                resident: 650 * mib,
                estimated: false,
                workingDirectory: "fixture-secondary-project"
            ),
            process(
                6,
                name: "Fixture Secondary Worker Long Display Name Golf",
                app: "Fixture Workspace Secondary Application Golf",
                parentPID: secondaryRootPID,
                footprint: 640 * mib,
                resident: 480 * mib,
                estimated: false,
                workingDirectory: "fixture-secondary-project"
            )
        ].sorted(by: ProcessSnapshot.memoryDescending)
    }

    private static func makeGroups(
        processes: [ProcessSnapshot]
    ) -> [WorkloadGroupSnapshot] {
        let primary = processes.filter { $0.identity.pid < 71_004 }
        let secondary = processes.filter { $0.identity.pid >= 71_004 }

        func group(
            id: String,
            title: String,
            members: [ProcessSnapshot],
            reason: WorkloadAttributionReason,
            parentChain: [String]
        ) -> WorkloadGroupSnapshot {
            WorkloadGroupSnapshot(
                id: id,
                title: title,
                processCount: members.count,
                physicalFootprintBytes: members.reduce(0) { $0 + $1.physicalFootprintBytes },
                residentBytes: members.reduce(0) { $0 + $1.residentBytes },
                containsEstimatedFootprint: members.contains { $0.physicalFootprintIsEstimated },
                isSystem: false,
                representativeProcess: members.first?.name ?? "fixture",
                attributionReason: reason,
                parentChain: parentChain,
                memberProcessIdentities: members.map(\.identity)
            )
        }

        return [
            group(
                id: "fixture-primary-workgroup",
                title: "Fixture Primary Workgroup with a Deliberately Long Display Label",
                members: primary,
                reason: .runtimeWorkingDirectory,
                parentChain: ["fixture-primary-host", "launchd"]
            ),
            group(
                id: "fixture-secondary-workgroup",
                title: "Fixture Secondary Workgroup with Multiple Members",
                members: secondary,
                reason: .processName,
                parentChain: ["fixture-secondary-host", "launchd"]
            )
        ]
    }

    private static func makeSnapshot(
        referenceDate: Date,
        processes: [ProcessSnapshot],
        groups: [WorkloadGroupSnapshot]
    ) -> MonitorSnapshot {
        let total = 16 * gib
        let system = SystemMemorySnapshot(
            timestamp: referenceDate,
            totalBytes: total,
            pageSize: 4_096,
            freeBytes: 1 * gib,
            activeBytes: 6 * gib,
            inactiveBytes: 2 * gib,
            speculativeBytes: 128 * mib,
            wiredBytes: 3 * gib,
            purgeableBytes: 1 * gib,
            compressedBytes: 2 * gib,
            throttledPages: 0,
            swapTotalBytes: 8 * gib,
            swapUsedBytes: 2 * gib,
            swapFreeBytes: 6 * gib
        )
        let diagnostics = SamplingDiagnostics(
            mode: .full,
            totalDurationMilliseconds: 12,
            processDurationMilliseconds: 8,
            processSamplingPerformed: true,
            processCount: processes.count,
            listedProcessCount: processes.count
        )
        return MonitorSnapshot(
            timestamp: referenceDate,
            system: system,
            systemStatus: .available(at: referenceDate),
            cpuTime: CPUTimeSnapshot(
                userTicks: 4_000,
                systemTicks: 1_200,
                idleTicks: 5_000,
                niceTicks: 300
            ),
            cpuStatus: .available(at: referenceDate),
            gpuUsageFraction: 0.42,
            gpuStatus: .available(at: referenceDate),
            processes: processes,
            processStatus: .available(at: referenceDate),
            listedProcessCount: processes.count,
            sampledProcessCount: processes.count,
            groups: groups,
            samplingMode: .full,
            diagnostics: diagnostics
        )
    }

    private static func makeHistoryRecords(
        referenceDate: Date,
        groups: [WorkloadGroupSnapshot]
    ) -> [MemoryHistoryRecord] {
        let primary = groups[0]
        let secondary = groups[1]
        let interval: TimeInterval = 5 * 60
        return (0..<240).map { index in
            let timestamp = referenceDate.addingTimeInterval(-Double(239 - index) * interval)
            let primaryBase = 2 * gib + UInt64(index) * 2 * mib
            // A single large jump guarantees a visible growth event.
            let primaryFootprint = index == 120
                ? primaryBase + 900 * mib
                : primaryBase
            var workloads = [PersistedWorkloadRecord(
                id: primary.id,
                title: primary.title,
                processCount: primary.processCount,
                attributedFootprintBytes: primaryFootprint,
                attributedResidentBytes: primaryFootprint - 300 * mib,
                isSystem: false,
                containsEstimatedFootprint: false
            )]
            // The secondary group enters and leaves the retained ranking so
            // the analyzer emits both appeared and disappeared events.
            if (20...180).contains(index) {
                let secondaryFootprint = 700 * mib + UInt64(index) * mib
                workloads.append(PersistedWorkloadRecord(
                    id: secondary.id,
                    title: secondary.title,
                    processCount: secondary.processCount,
                    attributedFootprintBytes: secondaryFootprint,
                    attributedResidentBytes: secondaryFootprint - 120 * mib,
                    isSystem: false,
                    containsEstimatedFootprint: false
                ))
            }
            // Cross both pressure and Swap thresholds during the window.
            let availableFraction: Double
            let swapUsed: UInt64
            switch index {
            case 70..<95:
                availableFraction = 0.16
                swapUsed = 2 * gib
            case 95..<115:
                availableFraction = 0.08
                swapUsed = 5 * gib
            case 115..<135:
                availableFraction = 0.24
                swapUsed = 800 * mib
            default:
                availableFraction = 0.28
                swapUsed = 800 * mib
            }
            return MemoryHistoryRecord(
                timestamp: timestamp,
                availableFraction: availableFraction,
                compressedBytes: 2 * gib + UInt64(index) * mib,
                swapUsedBytes: swapUsed,
                workloads: workloads,
                workloadsSampledAt: timestamp,
                workloadInventoryIsComplete: true,
                sourceSampledAt: timestamp
            )
        }
    }

    private static func makeAuditEvents(referenceDate: Date) -> [ProcessActionAuditEvent] {
        let longProcess = "Fixture audit process with an intentionally long display label"
        let longApplication = "Fixture audit application with an intentionally long name"
        return (0..<12).map { index in
            let phase: ProcessActionAuditPhase
            let outcome: ProcessActionOutcome
            switch index % 3 {
            case 0:
                phase = .intent
                outcome = .completed
            case 1:
                phase = .signalSent
                outcome = .completed
            default:
                phase = .terminal
                outcome = index % 2 == 0 ? .completed : .timedOut
            }
            let detail = "fixture 审计事件 (index)：这是用于窄宽度和辅助功能读取的较长脱敏说明，包含足够的文本以覆盖中间截断和多行布局边界。"
            return ProcessActionAuditEvent(
                id: "fixture-audit-event-\(index)",
                operationID: "fixture-audit-operation-\(index / 3)",
                timestamp: referenceDate.addingTimeInterval(-Double(11 - index) * 17 * 60),
                action: index % 2 == 0 ? .gracefulExit : .forceTerminate,
                phase: phase,
                outcome: outcome,
                processLabel: "\(longProcess) \(index)",
                applicationName: "\(longApplication) \(index)",
                detail: detail
            )
        }
    }
}
