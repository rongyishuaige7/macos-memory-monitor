import XCTest
@testable import MemoryMonitorCore

private final class TestCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class MemoryMonitorCoreTests: XCTestCase {
    private enum TestSamplingError: Error {
        case denied
        case unavailable
    }

    func testByteFormatting() {
        XCTAssertEqual(MemoryFormatter.bytes(0), "0 B")
        XCTAssertEqual(MemoryFormatter.bytes(1024), "1.0 KiB")
        XCTAssertEqual(MemoryFormatter.bytes(1024 * 1024), "1.0 MiB")
    }

    func testSystemSamplerReturnsCurrentMachineData() throws {
        let snapshot = try SystemMemorySampler().sample()
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertGreaterThan(snapshot.pageSize, 0)
        XCTAssertGreaterThanOrEqual(snapshot.availableEstimateBytes, snapshot.freeBytes)
        XCTAssertTrue(snapshot.isStructurallyValid)
    }

    func testSampleStatusReportsAgeOnlyForCapturedValues() {
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let available = SampleStatus.available(at: capturedAt)
        XCTAssertEqual(
            try XCTUnwrap(available.sampleAge(at: capturedAt.addingTimeInterval(12))),
            12,
            accuracy: 0.001
        )

        let unavailable = SampleStatus.unavailable(message: "没有驱动数据")
        XCTAssertNil(unavailable.sampleAge(at: capturedAt.addingTimeInterval(12)))
        XCTAssertEqual(unavailable.quality, .unavailable)
    }

    func testAvailableEstimateDoesNotDoubleCountSpeculativePages() {
        let snapshot = SystemMemorySnapshot(
            totalBytes: 100,
            pageSize: 1,
            freeBytes: 10,
            activeBytes: 40,
            inactiveBytes: 20,
            speculativeBytes: 50,
            wiredBytes: 30,
            purgeableBytes: 5,
            compressedBytes: 0,
            throttledPages: 0,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            swapFreeBytes: 0
        )

        XCTAssertEqual(snapshot.availableEstimateBytes, 35)
        XCTAssertEqual(snapshot.availableFraction, 0.35, accuracy: 0.0001)
    }

    func testAvailableFractionIsClampedToUnitInterval() {
        let snapshot = SystemMemorySnapshot(
            totalBytes: 10,
            pageSize: 1,
            freeBytes: 100,
            activeBytes: 0,
            inactiveBytes: 0,
            speculativeBytes: 0,
            wiredBytes: 0,
            purgeableBytes: 0,
            compressedBytes: 0,
            throttledPages: 0,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            swapFreeBytes: 0
        )

        XCTAssertEqual(snapshot.availableEstimateBytes, 10)
        XCTAssertEqual(snapshot.availableFraction, 1)
        XCTAssertEqual(snapshot.usedFraction, 0)
    }

    func testAvailableEstimateRejectsArithmeticOverflow() {
        let snapshot = SystemMemorySnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            totalBytes: 100,
            pageSize: 1,
            freeBytes: UInt64.max,
            activeBytes: 0,
            inactiveBytes: 1,
            speculativeBytes: 0,
            wiredBytes: 0,
            purgeableBytes: 0,
            compressedBytes: 0,
            throttledPages: 0,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            swapFreeBytes: 0
        )

        XCTAssertEqual(snapshot.availableEstimateBytes, 0)
        XCTAssertFalse(snapshot.isStructurallyValid)
    }

    func testSystemSnapshotRejectsInconsistentSwapValues() {
        func makeSnapshot(swapTotal: UInt64, swapUsed: UInt64, swapFree: UInt64) -> SystemMemorySnapshot {
            SystemMemorySnapshot(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                totalBytes: 100,
                pageSize: 1,
                freeBytes: 10,
                activeBytes: 70,
                inactiveBytes: 10,
                speculativeBytes: 0,
                wiredBytes: 10,
                purgeableBytes: 0,
                compressedBytes: 0,
                throttledPages: 0,
                swapTotalBytes: swapTotal,
                swapUsedBytes: swapUsed,
                swapFreeBytes: swapFree
            )
        }

        XCTAssertTrue(makeSnapshot(swapTotal: 100, swapUsed: 70, swapFree: 30).isStructurallyValid)
        XCTAssertFalse(makeSnapshot(swapTotal: 100, swapUsed: 101, swapFree: 0).isStructurallyValid)
        XCTAssertFalse(makeSnapshot(swapTotal: 100, swapUsed: 0, swapFree: 101).isStructurallyValid)
    }

    func testCPUUsageCalculatorComputesDeltaFraction() {
        let previous = CPUTimeSnapshot(userTicks: 100, systemTicks: 50, idleTicks: 850, niceTicks: 0)
        let current = CPUTimeSnapshot(userTicks: 200, systemTicks: 100, idleTicks: 950, niceTicks: 0)

        let fraction = try! XCTUnwrap(
            CPUUsageCalculator.usedFraction(current: current, previous: previous)
        )
        XCTAssertEqual(fraction, 0.6, accuracy: 0.0001)
    }

    func testCPUUsageCalculatorRejectsCounterReset() {
        let previous = CPUTimeSnapshot(userTicks: 100, systemTicks: 50, idleTicks: 850, niceTicks: 0)
        let current = CPUTimeSnapshot(userTicks: 10, systemTicks: 5, idleTicks: 20, niceTicks: 0)

        XCTAssertNil(CPUUsageCalculator.usedFraction(current: current, previous: previous))
    }

    func testCPUTimeSnapshotSaturatesCounterSums() {
        let snapshot = CPUTimeSnapshot(
            userTicks: UInt64.max,
            systemTicks: UInt64.max,
            idleTicks: UInt64.max,
            niceTicks: UInt64.max
        )

        XCTAssertEqual(snapshot.activeTicks, UInt64.max)
        XCTAssertEqual(snapshot.totalTicks, UInt64.max)
    }

    func testCPUTimeSamplerReturnsNonZeroCounters() throws {
        let snapshot = try CPUTimeSampler().sample()

        XCTAssertGreaterThan(snapshot.totalTicks, 0)
        XCTAssertGreaterThanOrEqual(snapshot.totalTicks, snapshot.activeTicks)
    }

    func testMachSamplerCountValidationRejectsPartialStructs() {
        XCTAssertTrue(
            SystemMemorySampler.hasSufficientStatisticsCount(actual: 8, expected: 8)
        )
        XCTAssertFalse(
            SystemMemorySampler.hasSufficientStatisticsCount(actual: 7, expected: 8)
        )
        XCTAssertTrue(
            CPUTimeSampler.hasSufficientStatisticsCount(actual: 5, expected: 4)
        )
        XCTAssertFalse(
            CPUTimeSampler.hasSufficientStatisticsCount(actual: 3, expected: 4)
        )
    }

    func testGPUUsageSamplerReturnsBoundedValueWhenAvailable() {
        guard let value = GPUUsageSampler().sample() else { return }

        XCTAssertGreaterThanOrEqual(value, 0)
        XCTAssertLessThanOrEqual(value, 1)
    }

    func testGPUUsageSampleRejectsInvalidFractionAndTimestamp() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        for fraction in [Double.nan, Double.infinity, -0.1, 1.1] {
            let sample = GPUUsageSample(
                fraction: fraction,
                status: .available(at: timestamp)
            )
            XCTAssertNil(sample.fraction)
            XCTAssertEqual(sample.status.quality, .error)
        }

        let invalidTimestamp = GPUUsageSample(
            fraction: 0.25,
            status: .available(at: Date(timeIntervalSince1970: .nan))
        )
        XCTAssertNil(invalidTimestamp.fraction)
        XCTAssertEqual(invalidTimestamp.status.quality, .error)

        let missingFraction = GPUUsageSample(
            fraction: nil,
            status: .available(at: timestamp)
        )
        XCTAssertNil(missingFraction.fraction)
        XCTAssertEqual(missingFraction.status.quality, .unavailable)
    }

    func testGPUUsageSampleDropsFractionForUnusableStatus() {
        let unavailable = GPUUsageSample(
            fraction: 0.5,
            status: .unavailable(message: "驱动未提供数据")
        )
        XCTAssertNil(unavailable.fraction)
        XCTAssertEqual(unavailable.status.quality, .unavailable)

        let failed = GPUUsageSample(
            fraction: 0.5,
            status: .error("provider failed")
        )
        XCTAssertNil(failed.fraction)
        XCTAssertEqual(failed.status.quality, .error)
    }

    func testMonitorSamplerRejectsGPUValueFromDifferentSamplingPass() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let system = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let sampler = MonitorSampler(
            systemSampler: { system },
            cpuSampler: { CPUTimeSnapshot(userTicks: 1, systemTicks: 1, idleTicks: 1, niceTicks: 0) },
            gpuSampler: {
                GPUUsageSample(
                    fraction: 0.5,
                    status: .available(
                        at: timestamp.addingTimeInterval(
                            MonitorSnapshot.gpuSampleTimestampTolerance + 1
                        )
                    )
                )
            },
            processSampler: { throw TestSamplingError.unavailable }
        )

        let snapshot = sampler.sample(at: timestamp)

        XCTAssertNil(snapshot.gpuUsageFraction)
        XCTAssertEqual(snapshot.gpuStatus.quality, .error)
    }

    func testCheckedSamplingArithmeticRejectsOverflow() {
        XCTAssertEqual(
            SystemMemorySampler.checkedPageBytes(4, pageSize: 1024),
            4096
        )
        XCTAssertNil(
            SystemMemorySampler.checkedPageBytes(UInt64.max, pageSize: 2)
        )

        XCTAssertEqual(
            ProcessSampler.checkedPIDBufferByteCount(capacity: 2),
            2 * MemoryLayout<pid_t>.stride
        )
        XCTAssertNil(ProcessSampler.checkedPIDBufferByteCount(capacity: 0))
        XCTAssertNil(ProcessSampler.checkedPIDBufferByteCount(capacity: Int.max))
        XCTAssertTrue(ProcessSampler.isPIDByteCountAligned(MemoryLayout<pid_t>.stride * 2))
        XCTAssertFalse(ProcessSampler.isPIDByteCountAligned(MemoryLayout<pid_t>.stride * 2 + 1))
    }

    func testSystemSamplerAcceptsOnlyExactSysctlPayloadSize() {
        let expected = MemoryLayout<xsw_usage>.size

        XCTAssertFalse(
            SystemMemorySampler.hasExpectedSysctlByteCount(actual: 0, expected: expected)
        )
        XCTAssertFalse(
            SystemMemorySampler.hasExpectedSysctlByteCount(actual: expected - 1, expected: expected)
        )
        XCTAssertTrue(
            SystemMemorySampler.hasExpectedSysctlByteCount(actual: expected, expected: expected)
        )
        XCTAssertFalse(
            SystemMemorySampler.hasExpectedSysctlByteCount(actual: expected + 1, expected: expected)
        )
        XCTAssertFalse(
            SystemMemorySampler.hasExpectedSysctlByteCount(actual: 0, expected: 0)
        )
    }

    func testProcessSamplerDoesNotMarkZeroRowScanAsUsable() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let zeroRows = ProcessSampler.sampleStatus(
            at: timestamp,
            listedProcessCount: 10,
            sampledProcessCount: 0,
            hasEstimatedFootprint: false
        )

        XCTAssertEqual(zeroRows.quality, .unavailable)
        XCTAssertNil(zeroRows.sampledAt)
        XCTAssertTrue(zeroRows.message?.contains("10") == true)
        XCTAssertFalse(
            ProcessSamplingResult(
                processes: [],
                listedProcessCount: 10,
                sampledProcessCount: 0,
                skippedProcessCount: 10,
                status: zeroRows
            ).isUsable
        )

        let partial = ProcessSampler.sampleStatus(
            at: timestamp,
            listedProcessCount: 10,
            sampledProcessCount: 1,
            hasEstimatedFootprint: false
        )
        XCTAssertEqual(partial.quality, .estimated)
        XCTAssertEqual(partial.sampledAt, timestamp)

        let complete = ProcessSampler.sampleStatus(
            at: timestamp,
            listedProcessCount: 1,
            sampledProcessCount: 1,
            hasEstimatedFootprint: false
        )
        XCTAssertEqual(complete.quality, .available)
        XCTAssertEqual(complete.sampledAt, timestamp)
    }

    func testProcessSamplerRejectsIdentityChangesDuringSnapshotAssembly() {
        let requestedPID: Int32 = 700
        let initial = ProcessIdentity(
            pid: requestedPID,
            startTimeSeconds: 1_700_000_000,
            startTimeMicroseconds: 123
        )
        let reused = ProcessIdentity(
            pid: requestedPID,
            startTimeSeconds: initial.startTimeSeconds + 1,
            startTimeMicroseconds: initial.startTimeMicroseconds
        )
        let wrongPID = ProcessIdentity(
            pid: requestedPID + 1,
            startTimeSeconds: initial.startTimeSeconds,
            startTimeMicroseconds: initial.startTimeMicroseconds
        )

        XCTAssertTrue(
            ProcessSampler.hasStableIdentity(
                requestedPID: requestedPID,
                initial: initial,
                final: initial
            )
        )
        XCTAssertFalse(
            ProcessSampler.hasStableIdentity(
                requestedPID: requestedPID,
                initial: initial,
                final: reused
            )
        )
        XCTAssertFalse(
            ProcessSampler.hasStableIdentity(
                requestedPID: requestedPID,
                initial: initial,
                final: wrongPID
            )
        )
    }

    func testMonitorSamplerRejectsNonFiniteTimestampWithoutCallingProviders() {
        let counter = TestCallCounter()
        let system = makeSystemSnapshot(timestamp: Date(timeIntervalSince1970: 0), compressed: 0, swap: 0)
        let sampler = MonitorSampler(
            systemSampler: {
                counter.increment()
                return system
            },
            cpuSampler: {
                counter.increment()
                return CPUTimeSnapshot(userTicks: 1, systemTicks: 1, idleTicks: 1, niceTicks: 0)
            },
            gpuSampler: {
                counter.increment()
                return GPUUsageSample(fraction: nil, status: .unavailable())
            },
            processSampler: {
                counter.increment()
                return ProcessSamplingResult(
                    processes: [], listedProcessCount: 0, sampledProcessCount: 0,
                    skippedProcessCount: 0, status: .unavailable()
                )
            }
        )

        let snapshot = sampler.sample(mode: .full, at: Date(timeIntervalSince1970: .nan))

        XCTAssertEqual(counter.count, 0)
        XCTAssertNil(snapshot.system)
        XCTAssertEqual(snapshot.systemStatus.quality, .error)
        XCTAssertEqual(snapshot.cpuStatus.quality, .error)
        XCTAssertEqual(snapshot.gpuStatus.quality, .error)
        XCTAssertEqual(snapshot.processStatus.quality, .error)
        XCTAssertTrue(snapshot.timestamp.timeIntervalSince1970.isFinite)
        XCTAssertFalse(snapshot.didSampleProcesses)
    }

    func testMonitorSamplerKeepsIndependentSourcesWhenProcessSamplingFails() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let system = makeSystemSnapshot(timestamp: timestamp, compressed: 10, swap: 20)
        let sampler = MonitorSampler(
            systemSampler: { system },
            cpuSampler: { CPUTimeSnapshot(userTicks: 10, systemTicks: 5, idleTicks: 85, niceTicks: 0) },
            gpuSampler: {
                GPUUsageSample(
                    fraction: 0.25,
                    status: .available(at: timestamp)
                )
            },
            processSampler: { throw TestSamplingError.denied }
        )

        let snapshot = sampler.sample(at: timestamp)

        XCTAssertEqual(snapshot.system, system)
        XCTAssertEqual(snapshot.systemStatus.quality, .estimated)
        XCTAssertEqual(snapshot.cpuStatus.quality, .available)
        XCTAssertEqual(snapshot.gpuUsageFraction, 0.25)
        XCTAssertEqual(snapshot.gpuStatus.quality, .available)
        XCTAssertTrue(snapshot.processes.isEmpty)
        XCTAssertEqual(snapshot.processStatus.quality, .error)
        XCTAssertEqual(snapshot.groups, [])
        XCTAssertFalse(snapshot.processSamplingSucceeded)
        XCTAssertFalse(snapshot.processDataIsUsable)
    }

    func testMonitorSnapshotAcceptsHighCoverageEstimatedProcessResult() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let process = makeProcess(pid: 809, name: "worker", footprint: 100)
        let snapshot = MonitorSnapshot(
            timestamp: timestamp,
            system: makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0),
            systemStatus: .estimated(at: timestamp),
            cpuTime: nil,
            cpuStatus: .unavailable(),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(),
            processes: [process],
            processStatus: .estimated(at: timestamp, message: "部分条目受权限限制"),
            listedProcessCount: 2,
            sampledProcessCount: 1,
            groups: []
        )

        XCTAssertTrue(snapshot.processSamplingSucceeded)
        XCTAssertTrue(snapshot.processDataIsUsable)
    }

    func testMonitorSnapshotRejectsEmptyAndLowCoverageProcessResults() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let process = makeProcess(pid: 810, name: "worker", footprint: 100)
        let empty = MonitorSnapshot(
            timestamp: timestamp,
            system: nil,
            systemStatus: .unavailable(),
            cpuTime: nil,
            cpuStatus: .unavailable(),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(),
            processes: [],
            processStatus: .estimated(at: timestamp),
            listedProcessCount: 10,
            sampledProcessCount: 0,
            groups: []
        )
        let lowCoverage = MonitorSnapshot(
            timestamp: timestamp,
            system: nil,
            systemStatus: .unavailable(),
            cpuTime: nil,
            cpuStatus: .unavailable(),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(),
            processes: [process],
            processStatus: .estimated(at: timestamp),
            listedProcessCount: 10,
            sampledProcessCount: 1,
            groups: []
        )

        XCTAssertTrue(empty.processSamplingSucceeded)
        XCTAssertFalse(empty.processDataIsUsable)
        XCTAssertTrue(lowCoverage.processSamplingSucceeded)
        XCTAssertFalse(lowCoverage.processDataIsUsable)
    }

    func testMonitorSnapshotRequiresFiniteProcessTimestampNearSnapshot() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let process = makeProcess(pid: 811, name: "worker", footprint: 100)
        let makeSnapshot: (Date) -> MonitorSnapshot = { sampledAt in
            MonitorSnapshot(
                timestamp: timestamp,
                system: nil,
                systemStatus: .unavailable(),
                cpuTime: nil,
                cpuStatus: .unavailable(),
                gpuUsageFraction: nil,
                gpuStatus: .unavailable(),
                processes: [process],
                processStatus: .available(at: sampledAt),
                listedProcessCount: 1,
                sampledProcessCount: 1,
                groups: []
            )
        }

        let withinTolerance = makeSnapshot(
            timestamp.addingTimeInterval(MonitorSnapshot.processSampleTimestampTolerance)
        )
        XCTAssertEqual(
            withinTolerance.validatedProcessSampleAt,
            timestamp.addingTimeInterval(MonitorSnapshot.processSampleTimestampTolerance)
        )
        XCTAssertTrue(withinTolerance.processSamplingSucceeded)
        XCTAssertTrue(withinTolerance.processDataIsUsable)

        for sampledAt in [
            timestamp.addingTimeInterval(-MonitorSnapshot.processSampleTimestampTolerance - 0.1),
            timestamp.addingTimeInterval(MonitorSnapshot.processSampleTimestampTolerance + 0.1),
            Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: .infinity)
        ] {
            let snapshot = makeSnapshot(sampledAt)
            XCTAssertNil(snapshot.validatedProcessSampleAt)
            XCTAssertFalse(snapshot.processSamplingSucceeded)
            XCTAssertFalse(snapshot.processDataIsUsable)
        }

        let notAttempted = MonitorSnapshot(
            timestamp: timestamp,
            system: nil,
            systemStatus: .unavailable(),
            cpuTime: nil,
            cpuStatus: .unavailable(),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(),
            processes: [process],
            processStatus: .available(at: timestamp),
            listedProcessCount: 1,
            sampledProcessCount: 1,
            groups: [],
            samplingMode: .background,
            diagnostics: SamplingDiagnostics(
                mode: .background,
                totalDurationMilliseconds: 1,
                processDurationMilliseconds: nil,
                processSamplingPerformed: false,
                processCount: 1,
                listedProcessCount: 1
            )
        )
        XCTAssertNil(notAttempted.validatedProcessSampleAt)
        XCTAssertFalse(notAttempted.processSamplingSucceeded)
        XCTAssertFalse(notAttempted.processDataIsUsable)
    }

    func testMonitorSnapshotRequiresFiniteSystemTimestampNearSnapshot() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let makeSnapshot: (Date, Date) -> MonitorSnapshot = { [self] systemAt, statusAt in
            let system = self.makeSystemSnapshot(timestamp: systemAt, compressed: 0, swap: 0)
            return MonitorSnapshot(
                timestamp: timestamp,
                system: system,
                systemStatus: .estimated(at: statusAt),
                cpuTime: nil,
                cpuStatus: .unavailable(),
                gpuUsageFraction: nil,
                gpuStatus: .unavailable(),
                processes: [],
                processStatus: .unavailable(),
                listedProcessCount: 0,
                sampledProcessCount: 0,
                groups: []
            )
        }

        let withinTolerance = makeSnapshot(
            timestamp.addingTimeInterval(MonitorSnapshot.systemSampleTimestampTolerance),
            timestamp.addingTimeInterval(MonitorSnapshot.systemSampleTimestampTolerance)
        )
        XCTAssertEqual(
            withinTolerance.validatedSystemSampleAt,
            timestamp.addingTimeInterval(MonitorSnapshot.systemSampleTimestampTolerance)
        )
        XCTAssertTrue(withinTolerance.systemDataIsUsable)

        let invalidPairs = [
            (
                timestamp.addingTimeInterval(-MonitorSnapshot.systemSampleTimestampTolerance - 0.1),
                timestamp
            ),
            (
                timestamp,
                timestamp.addingTimeInterval(MonitorSnapshot.systemSampleTimestampTolerance + 0.1)
            ),
            (Date(timeIntervalSince1970: .nan), timestamp),
            (timestamp, Date(timeIntervalSince1970: .infinity))
        ]
        for (systemAt, statusAt) in invalidPairs {
            let snapshot = makeSnapshot(systemAt, statusAt)
            XCTAssertNil(snapshot.validatedSystemSampleAt)
            XCTAssertNil(snapshot.validatedSystemSample)
            XCTAssertFalse(snapshot.systemDataIsUsable)
        }
    }

    func testMonitorSamplerMarksInvalidSystemWithoutDiscardingProcesses() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let invalid = SystemMemorySnapshot(
            timestamp: timestamp,
            totalBytes: 0,
            pageSize: 0,
            freeBytes: 0,
            activeBytes: 0,
            inactiveBytes: 0,
            speculativeBytes: 0,
            wiredBytes: 0,
            purgeableBytes: 0,
            compressedBytes: 0,
            throttledPages: 0,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            swapFreeBytes: 0
        )
        let process = makeProcess(pid: 808, name: "worker", footprint: 100)
        let processResult = ProcessSamplingResult(
            processes: [process],
            listedProcessCount: 1,
            sampledProcessCount: 1,
            skippedProcessCount: 0,
            status: .available(at: timestamp)
        )
        let sampler = MonitorSampler(
            systemSampler: { invalid },
            cpuSampler: { throw TestSamplingError.unavailable },
            gpuSampler: {
                GPUUsageSample(
                    fraction: nil,
                    status: .unavailable(message: "驱动未提供")
                )
            },
            processSampler: { processResult }
        )

        let snapshot = sampler.sample(at: timestamp)

        XCTAssertNil(snapshot.system)
        XCTAssertEqual(snapshot.systemStatus.quality, .error)
        XCTAssertEqual(snapshot.cpuStatus.quality, .error)
        XCTAssertEqual(snapshot.gpuStatus.quality, .unavailable)
        XCTAssertEqual(snapshot.processes, [process])
        XCTAssertEqual(snapshot.processStatus.quality, .available)
    }

    func testProcessSamplerRejectsNonFiniteRequestedTimestampBeforeScanning() {
        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(
                try ProcessSampler().sampleDetailed(at: Date(timeIntervalSince1970: seconds))
            ) { error in
                guard let error = error as? MemoryMonitorError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(
                    error.description,
                    "进程采样时间无效"
                )
            }
        }
    }

    func testMonitorSamplerSortsProcessResultsByStableMemoryOrdering() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let processes = [
            makeProcess(pid: 12, name: "same", footprint: 100),
            makeProcess(pid: 10, name: "same", footprint: 100),
            makeProcess(pid: 11, name: "larger-rss", footprint: 100)
        ].map { process in
            if process.identity.pid == 11 {
                return ProcessSnapshot(
                    identity: process.identity,
                    parentPID: process.parentPID,
                    userID: process.userID,
                    isSystem: process.isSystem,
                    name: process.name,
                    executablePath: process.executablePath,
                    residentBytes: 200,
                    physicalFootprintBytes: process.physicalFootprintBytes,
                    virtualBytes: process.virtualBytes,
                    userTimeNanos: process.userTimeNanos,
                    systemTimeNanos: process.systemTimeNanos,
                    threadCount: process.threadCount
                )
            }
            return process
        }
        let result = ProcessSamplingResult(
            processes: processes,
            listedProcessCount: 3,
            sampledProcessCount: 3,
            skippedProcessCount: 0,
            status: .available(at: timestamp)
        )
        let system = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let sampler = MonitorSampler(
            systemSampler: { system },
            cpuSampler: { CPUTimeSnapshot(userTicks: 1, systemTicks: 1, idleTicks: 1, niceTicks: 0) },
            gpuSampler: {
                GPUUsageSample(fraction: nil, status: .unavailable())
            },
            processSampler: { result }
        )

        let snapshot = sampler.sample(at: timestamp)
        XCTAssertEqual(snapshot.processes.map { $0.identity.pid }, [11, 10, 12])
    }

    func testProcessSamplerFindsCurrentProcess() throws {
        let processes = try ProcessSampler().sample()
        XCTAssertFalse(processes.isEmpty)
        XCTAssertTrue(processes.contains { $0.identity.pid == getpid() })
    }

    func testProcessSamplerCanReadOneCurrentProcessByPID() throws {
        let process = try XCTUnwrap(ProcessSampler().sample(pid: getpid()))
        XCTAssertEqual(process.identity.pid, getpid())
        XCTAssertGreaterThan(process.identity.startTimeSeconds, 0)
    }

    func testProcessActionPolicyAllowsCurrentUserProcess() {
        let process = makeProcess(pid: 700, name: "worker", footprint: 100)
        let validation = ProcessActionPolicy(currentUserID: 501, monitorPID: 999)
            .validate(expected: process, current: process)

        XCTAssertTrue(validation.allowed)
        XCTAssertNil(validation.reason)
    }

    func testProcessActionPolicyRejectsOtherUsersAndProtectedProcesses() {
        let otherUser = makeProcess(pid: 701, name: "worker", footprint: 100, userID: 502)
        let systemFlagged = makeProcess(pid: 702, name: "worker", footprint: 100, isSystem: true)
        let protectedName = makeProcess(pid: 703, name: "launchd", footprint: 100)
        let protectedPath = makeProcess(
            pid: 704,
            name: "helper",
            footprint: 100,
            executablePath: "/usr/libexec/helper"
        )
        let policy = ProcessActionPolicy(currentUserID: 501, monitorPID: 999)

        XCTAssertEqual(
            policy.validate(expected: otherUser, current: otherUser).reason,
            .userMismatch
        )
        XCTAssertEqual(
            policy.validate(expected: systemFlagged, current: systemFlagged).reason,
            .protectedProcess
        )
        XCTAssertEqual(
            policy.validate(expected: protectedName, current: protectedName).reason,
            .protectedProcess
        )
        XCTAssertEqual(
            policy.validate(expected: protectedPath, current: protectedPath).reason,
            .protectedProcess
        )
    }

    func testProcessActionPolicyRejectsSelfAndMissingIdentityData() {
        let selfProcess = makeProcess(pid: 705, name: "worker", footprint: 100)
        let noPath = makeProcess(pid: 706, name: "worker", footprint: 100, omitExecutablePath: true)
        let policy = ProcessActionPolicy(currentUserID: 501, monitorPID: 705)

        XCTAssertEqual(
            policy.validate(expected: selfProcess, current: selfProcess).reason,
            .selfProcess
        )
        XCTAssertEqual(
            policy.validate(expected: noPath, current: noPath).reason,
            .executablePathUnavailable
        )
        XCTAssertEqual(
            policy.validate(expected: selfProcess, current: nil).reason,
            .missingSnapshot
        )
    }

    func testProcessActionPolicyRejectsPIDParentAndPathChanges() {
        let expected = makeProcess(pid: 707, name: "worker", parentPID: 10, footprint: 100)
        let identityChanged = makeProcess(
            pid: 707,
            name: "worker",
            parentPID: 10,
            footprint: 100,
            startTimeSeconds: 2
        )
        let parentChanged = makeProcess(pid: 707, name: "worker", parentPID: 11, footprint: 100)
        let pathChanged = makeProcess(
            pid: 707,
            name: "worker",
            parentPID: 10,
            footprint: 100,
            executablePath: "/Users/test/bin/worker"
        )
        let policy = ProcessActionPolicy(currentUserID: 501, monitorPID: 999)

        XCTAssertEqual(
            policy.validate(expected: expected, current: identityChanged).reason,
            .identityChanged
        )
        XCTAssertEqual(
            policy.validate(expected: expected, current: parentChanged).reason,
            .parentChanged
        )
        XCTAssertEqual(
            policy.validate(expected: expected, current: pathChanged).reason,
            .executablePathChanged
        )
    }

    func testProcessActionPolicyRejectsInvalidIdentityUIDAndParent() {
        let policy = ProcessActionPolicy(currentUserID: 501, monitorPID: 999)
        let invalidPID = makeProcess(pid: 0, name: "worker", footprint: 100)
        let invalidSeconds = makeProcess(
            pid: 708,
            name: "worker",
            footprint: 100,
            startTimeSeconds: 0
        )
        let invalidMicroseconds = makeProcess(
            pid: 709,
            name: "worker",
            footprint: 100,
            startTimeMicroseconds: 1_000_000
        )
        let rootProcess = makeProcess(pid: 710, name: "worker", footprint: 100, userID: 0)
        let missingParent = makeProcess(pid: 711, name: "worker", parentPID: 0, footprint: 100)

        XCTAssertEqual(
            policy.validate(expected: invalidPID, current: invalidPID).reason,
            .invalidIdentity
        )
        XCTAssertEqual(
            policy.validate(expected: invalidSeconds, current: invalidSeconds).reason,
            .invalidIdentity
        )
        XCTAssertEqual(
            policy.validate(expected: invalidMicroseconds, current: invalidMicroseconds).reason,
            .invalidIdentity
        )
        XCTAssertEqual(
            policy.validate(expected: rootProcess, current: rootProcess).reason,
            .protectedProcess
        )
        XCTAssertEqual(
            policy.validate(expected: missingParent, current: missingParent).reason,
            .parentUnavailable
        )
    }

    func testProcessIdentityRejectsAbsurdStartTime() {
        let process = makeProcess(
            pid: 712,
            name: "worker",
            footprint: 100,
            startTimeSeconds: UInt64.max
        )
        let policy = ProcessActionPolicy(currentUserID: 501, monitorPID: 999)

        XCTAssertFalse(process.identity.isStructurallyValid)
        XCTAssertNil(process.startDate)
        XCTAssertEqual(
            policy.validate(expected: process, current: process).reason,
            .invalidIdentity
        )
    }

    func testProcessActionAuditEventRedactsIdentityDetails() throws {
        let event = ProcessActionAuditEvent(
            id: "event-1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            action: .gracefulExit,
            outcome: .failed,
            processLabel: "worker",
            applicationName: "Worker",
            detail: "PID 12345 failed at /Users/test/project\u{001B}[31m"
        )

        XCTAssertFalse(event.detail.contains("12345"))
        XCTAssertFalse(event.detail.contains("/Users/test"))
        XCTAssertFalse(event.detail.unicodeScalars.contains { $0.value < 0x20 })

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(event)
        let payload = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(payload.contains("/Users/test"))
        XCTAssertFalse(payload.contains("12345"))
    }

    func testProcessActionAuditEventSanitizesValuesWhenDecoded() throws {
        let payload = """
        {"id":"event-2","timestamp":"2023-11-14T22:13:20Z","action":"gracefulExit","outcome":"failed","processLabel":"worker","applicationName":"Worker","detail":"PID 9876 /Users/test/private"}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let event = try decoder.decode(ProcessActionAuditEvent.self, from: payload)
        XCTAssertFalse(event.detail.contains("9876"))
        XCTAssertFalse(event.detail.contains("/Users/test"))
    }

    func testProcessActionAuditStorePersistsWithRetentionLimitAndPermissions() async throws {
        let paths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ProcessActionAuditStore(
            fileURL: paths.file,
            retentionInterval: 1_000,
            maximumEvents: 2
        )

        let old = makeAuditEvent(id: "old", timestamp: now.addingTimeInterval(-2_000))
        let first = makeAuditEvent(id: "first", timestamp: now.addingTimeInterval(-10))
        let second = makeAuditEvent(id: "second", timestamp: now)
        _ = try await store.append(old, now: now)
        _ = try await store.append(first, now: now)
        let events = try await store.append(second, now: now)

        XCTAssertEqual(events.map(\.id), ["second", "first"])
        let reloaded = ProcessActionAuditStore(
            fileURL: paths.file,
            retentionInterval: 1_000,
            maximumEvents: 2
        )
        let reloadedEvents = try await reloaded.load(now: now)
        XCTAssertEqual(reloadedEvents.map(\.id), ["second", "first"])

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: paths.directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: paths.file.path)
        let directoryMode = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let fileMode = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
    }

    func testProcessActionAuditStoreSerializesConcurrentActorAppends() async throws {
        let paths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }

        let base = Date(timeIntervalSince1970: 1_699_900_000)
        let seed = ProcessActionAuditStore(fileURL: paths.file, maximumEvents: 10_000)
        _ = try await seed.append(makeAuditEvent(id: "0", timestamp: base), now: base)

        let events = (1...24).map { index in
            makeAuditEvent(
                id: String(index),
                timestamp: base.addingTimeInterval(Double(index))
            )
        }
        let stores = events.map { _ in
            ProcessActionAuditStore(fileURL: paths.file, maximumEvents: 10_000)
        }
        await withTaskGroup(of: Void.self) { group in
            for (event, store) in zip(events, stores) {
                group.addTask {
                    _ = try? await store.append(event, now: event.timestamp)
                }
            }
        }

        let loaded = try await ProcessActionAuditStore(fileURL: paths.file, maximumEvents: 10_000)
            .load(now: base.addingTimeInterval(30))
        XCTAssertEqual(loaded.count, 25)
        XCTAssertEqual(Set(loaded.map(\.id)), Set((0...24).map(String.init)))
    }

    func testProcessActionAuditStoreKeepsEventsAcrossClockRollback() async throws {
        let paths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ProcessActionAuditStore(fileURL: paths.file, retentionInterval: 1_000)
        _ = try await store.append(makeAuditEvent(id: "first", timestamp: base), now: base)
        _ = try await store.append(
            makeAuditEvent(id: "second", timestamp: base.addingTimeInterval(60)),
            now: base.addingTimeInterval(60)
        )

        let rolledBack = base.addingTimeInterval(-600)
        let inMemory = try await store.load(now: rolledBack)
        XCTAssertEqual(inMemory.map(\.id), ["second", "first"])
        let reloaded = ProcessActionAuditStore(fileURL: paths.file, retentionInterval: 1_000)
        let persisted = try await reloaded.load(now: rolledBack)
        XCTAssertEqual(persisted.map(\.id), ["second", "first"])
    }

    func testProcessActionAuditStoreIgnoresOrphanClockAnchorAfterDataReset() async throws {
        let paths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }

        let future = Date(timeIntervalSince1970: 1_700_000_600)
        let original = ProcessActionAuditStore(fileURL: paths.file, retentionInterval: 300)
        _ = try await original.append(
            makeAuditEvent(id: "old", timestamp: future),
            now: future
        )

        try FileManager.default.removeItem(at: paths.file)
        let resetNow = future.addingTimeInterval(-600)
        let resetStore = ProcessActionAuditStore(fileURL: paths.file, retentionInterval: 300)
        _ = try await resetStore.append(
            makeAuditEvent(id: "new", timestamp: resetNow),
            now: resetNow
        )

        let reloaded = try await ProcessActionAuditStore(fileURL: paths.file, retentionInterval: 300)
            .load(now: resetNow)
        XCTAssertEqual(reloaded.map(\.id), ["new"])
    }

    func testProcessActionAuditStoreRepairsIncompleteTail() async throws {
        let paths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        let event = makeAuditEvent(id: "valid", timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)
        data.append(contentsOf: Data(#"{"id":"incomplete"}"#.utf8).dropLast(2))
        try data.write(to: paths.file)

        let store = ProcessActionAuditStore(fileURL: paths.file)
        let loaded = try await store.load(now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(loaded.map(\.id), ["valid"])
        let repaired = try Data(contentsOf: paths.file)
        XCTAssertTrue(repaired.last == 0x0A)
        XCTAssertFalse(String(data: repaired, encoding: .utf8)?.contains("incomplete") == true)
    }

    func testProcessActionAuditStoreRollsBackFailedAppendInMemory() async throws {
        let paths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makeAuditEvent(id: "first", timestamp: now)
        let second = makeAuditEvent(id: "second", timestamp: now.addingTimeInterval(1))
        let store = ProcessActionAuditStore(fileURL: paths.file)
        _ = try await store.append(first, now: now)

        try? FileManager.default.removeItem(at: paths.file)
        try FileManager.default.createDirectory(at: paths.file, withIntermediateDirectories: true)
        do {
            _ = try await store.append(second, now: now)
            XCTFail("Expected audit append to fail")
        } catch let error as ProcessActionAuditStoreError {
            XCTAssertEqual(error, .writeFailed)
        }

        do {
            _ = try await store.load(now: now)
            XCTFail("Expected loaded audit read to surface the unreadable path")
        } catch let error as ProcessActionAuditStoreError {
            XCTAssertEqual(error, .readFailed)
        }
        try? FileManager.default.removeItem(at: paths.file)
        try await store.flush()
        let reloaded = ProcessActionAuditStore(fileURL: paths.file)
        let reloadedEvents = try await reloaded.load(now: now)
        XCTAssertEqual(reloadedEvents.map(\.id), ["first"])
    }

    func testHistoryStoreLoadedReadSurfacesUnreadablePathAndKeepsRetryableView() async throws {
        let paths = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(fileURL: paths.file)
        _ = try await store.append(
            makeHistoryRecord(timestamp: now, availableFraction: 0.4, swapUsedBytes: 1),
            now: now
        )

        try? FileManager.default.removeItem(at: paths.file)
        try FileManager.default.createDirectory(at: paths.file, withIntermediateDirectories: true)
        do {
            _ = try await store.append(
                makeHistoryRecord(
                    timestamp: now.addingTimeInterval(60),
                    availableFraction: 0.35,
                    swapUsedBytes: 2
                ),
                now: now.addingTimeInterval(60)
            )
            XCTFail("Expected history append to fail while the target is a directory")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .writeFailed)
        }
        do {
            _ = try await store.load(now: now)
            XCTFail("Expected loaded history read to surface the unreadable path")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .readFailed)
        }

        // Restoring the target lets the actor's preserved view be repaired by
        // the normal write retry path instead of silently losing the sample.
        try FileManager.default.removeItem(at: paths.file)
        try await store.flush(now: now)
        let reloaded = try await HistoryStore(fileURL: paths.file).load(now: now)
        XCTAssertEqual(reloaded.map(\.swapUsedBytes), [1, 2])
    }

    func testHistoryAndAuditStoresRejectBlankOrSchemaInvalidJournalTail() async throws {
        let (historyURL, historyDirectory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let historyStore = HistoryStore(fileURL: historyURL)
        _ = try await historyStore.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )
        let historyEncoder = JSONEncoder()
        historyEncoder.dateEncodingStrategy = .iso8601
        var blankJournal = try historyEncoder.encode(makeHistoryRecord(
            timestamp: base.addingTimeInterval(60),
            availableFraction: 0.4,
            swapUsedBytes: 2
        ))
        blankJournal.append(contentsOf: Data("\n\n".utf8))
        try blankJournal.write(to: historyStore.journalURL, options: [.atomic])
        do {
            _ = try await HistoryStore(fileURL: historyURL).load(now: base.addingTimeInterval(60))
            XCTFail("Expected blank journal line to fail")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .invalidData)
        }

        let actionPaths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: actionPaths.directory) }
        try FileManager.default.createDirectory(at: actionPaths.directory, withIntermediateDirectories: true)
        let event = makeAuditEvent(id: "valid", timestamp: base)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var invalidTail = try encoder.encode(event)
        invalidTail.append(0x0A)
        // Valid JSON syntax, but not a valid audit-event schema. It must not
        // be mistaken for a crash-truncated final line.
        invalidTail.append(contentsOf: Data(#"{"id":"schema-only"}"#.utf8))
        try invalidTail.write(to: actionPaths.file, options: [.atomic])
        do {
            _ = try await ProcessActionAuditStore(fileURL: actionPaths.file).load(now: base)
            XCTFail("Expected schema-invalid journal tail to fail")
        } catch let error as ProcessActionAuditStoreError {
            XCTAssertEqual(error, .invalidData)
        }
    }

    func testHistoryStoreRejectsCompleteSchemaInvalidJournalLine() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // This is complete, syntactically valid JSON, but it cannot decode as
        // a MemoryHistoryRecord. It must not be treated as a crash-truncated
        // tail merely because it is the last line.
        let data = Data(
            #"{"timestamp":"2023-11-14T22:13:20Z","availableFraction":0.4}"#.utf8
        )
        let journalURL = URL(fileURLWithPath: url.path + ".journal")
        try data.write(to: journalURL, options: [.atomic])

        do {
            _ = try await HistoryStore(fileURL: url).load(
                now: Date(timeIntervalSince1970: 1_700_000_000)
            )
            XCTFail("Expected schema-invalid history journal line to fail")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .invalidData)
        }
    }

    func testHistoryAndAuditStoresRejectNonFiniteNowWithoutMutation() async throws {
        let (historyURL, historyDirectory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: historyDirectory) }
        let actionPaths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: actionPaths.directory) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let historyStore = HistoryStore(fileURL: historyURL)
        _ = try await historyStore.append(
            makeHistoryRecord(timestamp: base, availableFraction: 0.4, swapUsedBytes: 1),
            now: base
        )
        let auditStore = ProcessActionAuditStore(fileURL: actionPaths.file)
        _ = try await auditStore.append(makeAuditEvent(id: "first", timestamp: base), now: base)
        let historyBefore = try Data(contentsOf: historyURL)
        let auditBefore = try Data(contentsOf: actionPaths.file)

        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            let invalidNow = Date(timeIntervalSince1970: seconds)

            do {
                _ = try await historyStore.load(now: invalidNow)
                XCTFail("Expected invalid history load time to fail")
            } catch let error as HistoryStoreError {
                XCTAssertEqual(error, .invalidData)
            }
            do {
                _ = try await historyStore.currentRecords(now: invalidNow)
                XCTFail("Expected invalid history query time to fail")
            } catch let error as HistoryStoreError {
                XCTAssertEqual(error, .invalidData)
            }
            do {
                _ = try await historyStore.append(
                    makeHistoryRecord(
                        timestamp: base.addingTimeInterval(60),
                        availableFraction: 0.3,
                        swapUsedBytes: 2
                    ),
                    now: invalidNow
                )
                XCTFail("Expected invalid history append time to fail")
            } catch let error as HistoryStoreError {
                XCTAssertEqual(error, .invalidData)
            }

            do {
                _ = try await auditStore.load(now: invalidNow)
                XCTFail("Expected invalid audit load time to fail")
            } catch let error as ProcessActionAuditStoreError {
                XCTAssertEqual(error, .invalidData)
            }
            do {
                _ = try await auditStore.append(
                    makeAuditEvent(id: "second", timestamp: base.addingTimeInterval(1)),
                    now: invalidNow
                )
                XCTFail("Expected invalid audit append time to fail")
            } catch let error as ProcessActionAuditStoreError {
                XCTAssertEqual(error, .invalidData)
            }
        }

        XCTAssertEqual(try Data(contentsOf: historyURL), historyBefore)
        XCTAssertEqual(try Data(contentsOf: actionPaths.file), auditBefore)
        let retainedHistory = try await historyStore.currentRecords(now: base)
        let retainedAudit = try await auditStore.load(now: base)
        XCTAssertEqual(retainedHistory.count, 1)
        XCTAssertEqual(retainedAudit.map(\.id), ["first"])
    }

    func testPersistenceModelsRejectInvalidDecodedFields() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let invalidFraction = Data("""
        {"timestamp":"2023-11-14T22:13:20Z","availableFraction":1.5,"compressedBytes":0,"swapUsedBytes":0,"workloads":[]}
        """.utf8)
        XCTAssertThrowsError(try decoder.decode(MemoryHistoryRecord.self, from: invalidFraction))

        let invalidWorkload = Data("""
        {"id":"worker","title":"Worker","processCount":-1,"attributedFootprintBytes":1,"attributedResidentBytes":1,"isSystem":false}
        """.utf8)
        XCTAssertThrowsError(try decoder.decode(PersistedWorkloadRecord.self, from: invalidWorkload))

        let invalidAuditID = Data("""
        {"id":"","timestamp":"2023-11-14T22:13:20Z","action":"gracefulExit","outcome":"failed","processLabel":"worker","detail":"failed"}
        """.utf8)
        XCTAssertThrowsError(try decoder.decode(ProcessActionAuditEvent.self, from: invalidAuditID))

        let nonFiniteDateDecoder = JSONDecoder()
        nonFiniteDateDecoder.dateDecodingStrategy = .secondsSince1970
        nonFiniteDateDecoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let invalidAuditDate = Data("""
        {"id":"event","timestamp":"NaN","action":"gracefulExit","outcome":"failed","processLabel":"worker","detail":"failed"}
        """.utf8)
        XCTAssertThrowsError(
            try nonFiniteDateDecoder.decode(ProcessActionAuditEvent.self, from: invalidAuditDate)
        )

        let legacyAuditEvent = Data("""
        {"id":"legacy","timestamp":"2023-11-14T22:13:20Z","action":"gracefulExit","outcome":"completed","processLabel":"worker","detail":"done"}
        """.utf8)
        let decodedLegacy = try decoder.decode(ProcessActionAuditEvent.self, from: legacyAuditEvent)
        XCTAssertNil(decodedLegacy.applicationName)

        let recommendationDecoder = JSONDecoder()
        recommendationDecoder.dateDecodingStrategy = .secondsSince1970
        let malformedRecommendation = Data("""
        {"id":"r","severity":"info","title":"title","detail":"detail","evidence":[],"confidence":5,"targetGroupID":null,"generatedAt":1700000000}
        """.utf8)
        let decodedRecommendation = try recommendationDecoder.decode(
            MemoryRecommendation.self,
            from: malformedRecommendation
        )
        XCTAssertEqual(decodedRecommendation.confidence, 1)
        XCTAssertEqual(decodedRecommendation.confidencePercent, 100)

        let malformedDiagnostics = Data("""
        {"mode":"panel","totalDurationMilliseconds":-4,"processDurationMilliseconds":-2,"processSamplingPerformed":true,"processCount":-1,"listedProcessCount":-3}
        """.utf8)
        let decodedDiagnostics = try decoder.decode(SamplingDiagnostics.self, from: malformedDiagnostics)
        XCTAssertEqual(decodedDiagnostics.totalDurationMilliseconds, 0)
        XCTAssertEqual(decodedDiagnostics.processDurationMilliseconds, 0)
        XCTAssertEqual(decodedDiagnostics.processCount, 0)
        XCTAssertEqual(decodedDiagnostics.listedProcessCount, 0)
    }

    func testAuditStoreRejectsMalformedUnterminatedJSONTail() async throws {
        let paths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(makeAuditEvent(id: "valid", timestamp: base))
        data.append(0x0A)
        // The open brace alone is not enough to call a tail truncated: this
        // prefix already violates object grammar and cannot be repaired at EOF.
        data.append(contentsOf: Data(#"{"id" 1"#.utf8))
        try data.write(to: paths.file, options: [.atomic])

        do {
            _ = try await ProcessActionAuditStore(fileURL: paths.file).load(now: base)
            XCTFail("Expected malformed terminal JSON to fail")
        } catch let error as ProcessActionAuditStoreError {
            XCTAssertEqual(error, .invalidData)
        }
    }

    func testAuditStoreDistinguishesUTF8TruncationFromInvalidTail() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var seed = try encoder.encode(makeAuditEvent(id: "seed", timestamp: base))
        seed.append(0x0A)

        let stringPrefix = Data(
            #"{"id":"tail","timestamp":"2023-11-14T22:13:20Z","action":"gracefulExit","outcome":"completed","processLabel":"worker","detail":"prefix"#.utf8
        )
        let outsideStringPrefix = Data(
            #"{"id":"tail","timestamp":"2023-11-14T22:13:20Z","action":"gracefulExit","outcome":"completed","processLabel":"worker","detail":"prefix"}"#.utf8
        )

        let recoverableTails: [[UInt8]] = [
            [0xE4, 0xB8], // Chinese scalar cut before its final continuation.
            [0xF0, 0x9F, 0x98] // Emoji scalar cut before its final continuation.
        ]
        for tail in recoverableTails {
            let paths = makeTemporaryActionURL()
            defer { try? FileManager.default.removeItem(at: paths.directory) }
            var data = seed
            data.append(contentsOf: stringPrefix)
            data.append(contentsOf: tail)
            try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
            try data.write(to: paths.file, options: [.atomic])

            do {
                let loaded = try await ProcessActionAuditStore(fileURL: paths.file).load(now: base)
                XCTAssertEqual(loaded.map(\.id), ["seed"])
            } catch {
                XCTFail("Expected truncated UTF-8 tail to recover (\(tail)): \(error)")
            }
        }

        let invalidTails: [[UInt8]] = [
            [0xE0, 0x80], // Overlong scalar boundary.
            [0xED, 0xA0], // UTF-16 surrogate boundary.
            [0xF4, 0x90] // Code point above U+10FFFF.
        ]
        for tail in invalidTails {
            let paths = makeTemporaryActionURL()
            defer { try? FileManager.default.removeItem(at: paths.directory) }
            var data = seed
            data.append(contentsOf: stringPrefix)
            data.append(contentsOf: tail)
            try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
            try data.write(to: paths.file, options: [.atomic])

            do {
                _ = try await ProcessActionAuditStore(fileURL: paths.file).load(now: base)
                XCTFail("Expected invalid UTF-8 tail to fail")
            } catch let error as ProcessActionAuditStoreError {
                XCTAssertEqual(error, .invalidData)
            }
        }

        let outsideStringPaths = makeTemporaryActionURL()
        defer { try? FileManager.default.removeItem(at: outsideStringPaths.directory) }
        var outsideStringData = seed
        outsideStringData.append(contentsOf: outsideStringPrefix)
        outsideStringData.append(contentsOf: [0xE0, 0xA0])
        try FileManager.default.createDirectory(
            at: outsideStringPaths.directory,
            withIntermediateDirectories: true
        )
        try outsideStringData.write(to: outsideStringPaths.file, options: [.atomic])
        do {
            _ = try await ProcessActionAuditStore(fileURL: outsideStringPaths.file).load(now: base)
            XCTFail("Expected UTF-8 outside a JSON string to fail")
        } catch let error as ProcessActionAuditStoreError {
            XCTAssertEqual(error, .invalidData)
        }
    }

    func testWorkingDirectoryLabelSanitizerFiltersCommonRoots() {
        XCTAssertEqual(
            WorkingDirectoryLabelSanitizer.label(
                from: "/Users/foo/projects/api",
                homeDirectory: "/Users/foo"
            ),
            "api"
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/Users/foo",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/tmp/build",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/private/var/folders/xx/random",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertEqual(
            WorkingDirectoryLabelSanitizer.label(
                from: "/tmp2/project",
                homeDirectory: "/Users/foo"
            ),
            "project"
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "relative/project",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/Users/foo/project\u{0000}suffix",
                homeDirectory: "/Users/foo"
            )
        )
        XCTAssertNil(
            WorkingDirectoryLabelSanitizer.label(
                from: "/",
                homeDirectory: "/Users/foo"
            )
        )
    }

    func testWorkingDirectoryLabelSanitizerCleansComponentsAndIDs() {
        XCTAssertEqual(
            WorkingDirectoryLabelSanitizer.label(fromComponent: " api/\nworker "),
            "api-worker"
        )

        let longComponent = String(repeating: "x", count: 100)
        let limited = try! XCTUnwrap(
            WorkingDirectoryLabelSanitizer.label(fromComponent: longComponent)
        )
        XCTAssertEqual(limited.count, WorkingDirectoryLabelSanitizer.maxLength)
        XCTAssertFalse(limited.contains("\n"))

        let unicodeID = WorkingDirectoryLabelSanitizer.identifierComponent(for: "中文项目")
        let otherUnicodeID = WorkingDirectoryLabelSanitizer.identifierComponent(for: "另一个项目")
        XCTAssertNotEqual(unicodeID, otherUnicodeID)
        XCTAssertFalse(unicodeID.contains("/"))
    }

    func testProcessSnapshotCodableRetainsWorkingDirectoryLabel() throws {
        let process = makeProcess(pid: 9, name: "node", footprint: 100, workingDirectoryLabel: "api")
        let data = try JSONEncoder().encode(process)
        let decoded = try JSONDecoder().decode(ProcessSnapshot.self, from: data)
        XCTAssertEqual(decoded.workingDirectoryLabel, "api")

        let unsafe = makeProcess(
            pid: 10,
            name: "node",
            footprint: 100,
            workingDirectoryLabel: "/Users/foo/projects/api"
        )
        XCTAssertNil(unsafe.workingDirectoryLabel)
    }

    func testProcessSnapshotDecodingKeepsNewMetadataBackwardCompatibleAndSanitized() throws {
        let process = makeProcess(pid: 11, name: "worker", footprint: 100)
        let encoded = try JSONEncoder().encode(process)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "applicationName")
        object.removeValue(forKey: "bundleIdentifier")
        let oldData = try JSONSerialization.data(withJSONObject: object)
        let oldDecoded = try JSONDecoder().decode(ProcessSnapshot.self, from: oldData)
        XCTAssertNil(oldDecoded.applicationName)
        XCTAssertNil(oldDecoded.bundleIdentifier)

        object["applicationName"] = "Display\nName"
        object["bundleIdentifier"] = "com.example/app"
        let unsafeData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ProcessSnapshot.self, from: unsafeData)
        XCTAssertEqual(decoded.applicationName, "DisplayName")
        XCTAssertEqual(decoded.bundleIdentifier, "com.example-app")
    }

    func testApplicationIdentityResolverIgnoresNonAppExecutables() {
        XCTAssertNil(ApplicationIdentityResolver.resolve(executablePath: "/usr/bin/node"))
        let identity = ApplicationIdentity(name: "App/Name", bundleIdentifier: "com.example/app")
        XCTAssertEqual(identity.name, "App-Name")
        XCTAssertEqual(identity.bundleIdentifier, "com.example-app")
    }

    func testWorkloadGrouperAggregatesChromeHelpers() {
        let processes = [
            makeProcess(pid: 10, name: "Google Chrome", footprint: 500),
            makeProcess(pid: 11, name: "Google Chrome Helper (Renderer)", parentPID: 10, footprint: 700),
            makeProcess(pid: 12, name: "Google Chrome Helper (GPU)", parentPID: 10, footprint: 300)
        ]

        let groups = WorkloadGrouper().group(processes)
        let chrome = try! XCTUnwrap(groups.first { $0.id == "chrome" })
        XCTAssertEqual(chrome.title, "Chrome")
        XCTAssertEqual(chrome.processCount, 3)
        XCTAssertEqual(chrome.physicalFootprintBytes, 1_500)
        XCTAssertEqual(chrome.residentBytes, 1_500)
        XCTAssertEqual(chrome.attributionReason, .chromeIdentity)
    }

    func testWorkloadGrouperSortsGroupsByFootprintBeforeSystemPriority() {
        let processes = [
            makeProcess(pid: 13, name: "small-user", footprint: 100),
            makeProcess(pid: 14, name: "large-system", footprint: 1_000, isSystem: true),
            makeProcess(pid: 15, name: "medium-user", footprint: 500)
        ]

        let groups = WorkloadGrouper().group(processes)

        XCTAssertEqual(groups.map(\.physicalFootprintBytes), [1_000, 500, 100])
    }

    func testWorkloadGrouperUsesCodexAncestorForAutomation() {
        let processes = [
            makeProcess(pid: 20, name: "codex", footprint: 100),
            makeProcess(pid: 21, name: "node", parentPID: 20, footprint: 200, workingDirectoryLabel: "api"),
            makeProcess(pid: 22, name: "Google Chrome Helper", parentPID: 21, footprint: 300)
        ]

        let groups = WorkloadGrouper().group(processes)
        let automation = try! XCTUnwrap(groups.first { $0.id == "codex-automation" })
        XCTAssertEqual(automation.processCount, 2)
        XCTAssertEqual(automation.physicalFootprintBytes, 500)
        XCTAssertNil(groups.first { $0.id == "runtime-node-api" })
        XCTAssertEqual(groups.first { $0.id == "codex-session" }?.attributionReason, .codexSession)
    }

    func testWorkloadGrouperSeparatesGenericRuntimesByWorkingDirectory() {
        let processes = [
            makeProcess(pid: 40, name: "node", footprint: 100, workingDirectoryLabel: "api"),
            makeProcess(pid: 41, name: "node", footprint: 200, workingDirectoryLabel: "bot"),
            makeProcess(pid: 42, name: "python3", footprint: 300, workingDirectoryLabel: "bot")
        ]

        let groups = WorkloadGrouper().group(processes)
        XCTAssertEqual(
            Set(groups.map(\.id)),
            Set(["runtime-node-api", "runtime-node-bot", "runtime-python-bot"])
        )
        XCTAssertEqual(groups.first { $0.id == "runtime-node-api" }?.title, "Node · api")
        XCTAssertEqual(groups.first { $0.id == "runtime-python-bot" }?.title, "Python · bot")
    }

    func testWorkloadGrouperInheritsLabelFromRuntimeAncestor() {
        let processes = [
            makeProcess(pid: 50, name: "node", footprint: 100, workingDirectoryLabel: "api"),
            makeProcess(pid: 51, name: "node", parentPID: 50, footprint: 200),
            makeProcess(pid: 52, name: "python3", parentPID: 51, footprint: 300)
        ]

        let groups = WorkloadGrouper().group(processes)
        XCTAssertEqual(groups.first { $0.id == "runtime-node-api" }?.processCount, 2)
        XCTAssertEqual(groups.first { $0.id == "runtime-python-api" }?.processCount, 1)
    }

    func testWorkloadGrouperFallsBackWhenWorkingDirectoryIsUnavailable() {
        let processes = [
            makeProcess(pid: 60, name: "node", footprint: 100),
            makeProcess(pid: 61, name: "python3", footprint: 200)
        ]

        let groups = WorkloadGrouper().group(processes)
        XCTAssertEqual(groups.first { $0.id == "runtime-node" }?.title, "Node")
        XCTAssertEqual(groups.first { $0.id == "runtime-python" }?.title, "Python")
    }

    func testWorkloadGrouperDoesNotAssumeEveryWebKitProcessBelongsToSafari() {
        let processes = [
            makeProcess(pid: 30, name: "WebKit.Networking", footprint: 100),
            makeProcess(pid: 31, name: "Safari", footprint: 200),
            makeProcess(pid: 32, name: "com.apple.WebKit.WebContent", parentPID: 31, footprint: 300)
        ]

        let groups = WorkloadGrouper().group(processes)
        XCTAssertEqual(groups.first { $0.id == "unattributed-webkit" }?.processCount, 1)
        XCTAssertEqual(groups.first { $0.id == "safari-webkit" }?.processCount, 2)
        XCTAssertEqual(
            groups.first { $0.id == "unattributed-webkit" }?.attributionReason,
            .unattributedWebKit
        )
        XCTAssertEqual(
            groups.first { $0.id == "safari-webkit" }?.parentChain,
            ["Safari"]
        )
    }

    func testWorkloadGrouperStopsAtParentCycle() {
        let processes = [
            makeProcess(pid: 100, name: "node", parentPID: 101, footprint: 100, workingDirectoryLabel: "api"),
            makeProcess(pid: 101, name: "python3", parentPID: 100, footprint: 200)
        ]

        let groups = WorkloadGrouper().group(processes)

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.parentChain.count <= 2 })
    }

    func testWorkloadGrouperDoesNotFollowAmbiguousReusedPID() {
        let processes = [
            makeProcess(
                pid: 200,
                name: "codex",
                footprint: 100
            ),
            ProcessSnapshot(
                identity: ProcessIdentity(pid: 200, startTimeSeconds: 2, startTimeMicroseconds: 2),
                parentPID: 1,
                userID: 501,
                isSystem: false,
                name: "unrelated",
                executablePath: "/usr/bin/unrelated",
                residentBytes: 100,
                physicalFootprintBytes: 100,
                virtualBytes: 100,
                userTimeNanos: 0,
                systemTimeNanos: 0,
                threadCount: 1
            ),
            makeProcess(
                pid: 201,
                name: "Google Chrome Helper",
                parentPID: 200,
                footprint: 300
            )
        ]

        let groups = WorkloadGrouper().group(processes)

        XCTAssertNil(groups.first { $0.id == "codex-automation" })
        XCTAssertEqual(groups.first { $0.id == "chrome" }?.attributionReason, .chromeIdentity)
    }

    func testWorkloadGrouperDoesNotMatchIncidentalPathSubstrings() {
        let processes = [
            makeProcess(
                pid: 210,
                name: "worker",
                footprint: 100,
                executablePath: "/Users/me/chrome-project/bin/worker"
            ),
            makeProcess(
                pid: 211,
                name: "worker",
                footprint: 100,
                executablePath: "/Users/me/safari-backup/bin/worker"
            ),
            makeProcess(
                pid: 212,
                name: "worker",
                footprint: 100,
                executablePath: "/Users/me/vmmigration/bin/worker"
            )
        ]

        let groups = WorkloadGrouper().group(processes)

        XCTAssertNil(groups.first { $0.id == "chrome" })
        XCTAssertNil(groups.first { $0.id == "safari-webkit" })
        XCTAssertNil(groups.first { $0.id == "virtual-machines" })
        XCTAssertEqual(groups.first { $0.id == "process-worker" }?.processCount, 3)
    }

    func testWorkloadGrouperStillMatchesKnownApplicationComponents() {
        let chrome = makeProcess(
            pid: 213,
            name: "worker",
            footprint: 100,
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper (Renderer)"
        )
        let safari = makeProcess(
            pid: 214,
            name: "worker",
            footprint: 100,
            executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"
        )

        let groups = WorkloadGrouper().group([chrome, safari])

        XCTAssertEqual(groups.first { $0.id == "chrome" }?.processCount, 1)
        XCTAssertEqual(groups.first { $0.id == "safari-webkit" }?.processCount, 1)
    }

    func testWorkloadTrendAnalyzerReportsExistingGrowingGroups() {
        let previous = [
            makeGroup(id: "chrome", title: "Chrome", footprint: 1_000),
            makeGroup(id: "stable", title: "Stable", footprint: 2_000)
        ]
        let current = [
            makeGroup(id: "chrome", title: "Chrome", footprint: 1_600),
            makeGroup(id: "stable", title: "Stable", footprint: 1_900),
            makeGroup(id: "new", title: "New", footprint: 4_000)
        ]

        let growth = WorkloadTrendAnalyzer().growingGroups(
            previous: previous,
            current: current,
            intervalSeconds: 5
        )

        XCTAssertEqual(growth.count, 1)
        XCTAssertEqual(growth.first?.id, "chrome")
        XCTAssertEqual(growth.first?.deltaBytes, 600)
        XCTAssertEqual(growth.first?.rateBytesPerSecond, 120)
    }

    func testWorkloadTrendAnalyzerRanksByGrowthRate() {
        let previous = [
            makeGroup(id: "large", title: "Large", footprint: 1_000),
            makeGroup(id: "fast", title: "Fast", footprint: 100)
        ]
        let current = [
            makeGroup(id: "large", title: "Large", footprint: 2_000),
            makeGroup(id: "fast", title: "Fast", footprint: 500)
        ]

        let growth = WorkloadTrendAnalyzer().growingGroups(
            previous: previous,
            current: current,
            intervalSeconds: 10
        )

        XCTAssertEqual(growth.map(\.id), ["large", "fast"])
    }

    func testWorkloadTrendAnalyzerDeduplicatesGroupIDs() {
        let previous = [
            makeGroup(id: "alpha", title: "Alpha B", footprint: 150),
            makeGroup(id: "alpha", title: "Alpha A", footprint: 100),
            makeGroup(id: "beta", title: "Beta", footprint: 200)
        ]
        let current = [
            makeGroup(id: "beta", title: "Beta", footprint: 260),
            makeGroup(id: "alpha", title: "Alpha D", footprint: 240),
            makeGroup(id: "alpha", title: "Alpha C", footprint: 250)
        ]

        let growth = WorkloadTrendAnalyzer().growingGroups(
            previous: previous,
            current: current,
            intervalSeconds: 10
        )

        XCTAssertEqual(growth.map(\.id), ["alpha", "beta"])
        XCTAssertEqual(growth[0].deltaBytes, 100)
        XCTAssertEqual(growth[0].rateBytesPerSecond, 10)
        XCTAssertEqual(growth[1].deltaBytes, 60)
        XCTAssertEqual(growth[1].rateBytesPerSecond, 6)
        XCTAssertTrue(growth.allSatisfy { $0.rateBytesPerSecond.isFinite })
    }

    func testWorkloadTrendAnalyzerPrefersExactDuplicateOverLargerEstimate() {
        let previous = [
            makeGroup(
                id: "worker",
                title: "Worker exact",
                footprint: 100,
                containsEstimatedFootprint: false
            ),
            makeGroup(
                id: "worker",
                title: "Worker RSS fallback",
                footprint: 10_000,
                containsEstimatedFootprint: true
            )
        ]
        let current = [
            makeGroup(
                id: "worker",
                title: "Worker",
                footprint: 200,
                containsEstimatedFootprint: false
            )
        ]

        let growth = WorkloadTrendAnalyzer().growingGroups(
            previous: previous,
            current: current,
            intervalSeconds: 10
        )

        XCTAssertEqual(growth.count, 1)
        XCTAssertEqual(growth.first?.id, "worker")
        XCTAssertEqual(growth.first?.deltaBytes, 100)
    }

    func testWorkloadTrendAnalyzerRejectsInvalidIntervals() {
        let previous = [makeGroup(id: "alpha", title: "Alpha", footprint: 100)]
        let current = [makeGroup(id: "alpha", title: "Alpha", footprint: 200)]
        let analyzer = WorkloadTrendAnalyzer()

        XCTAssertTrue(analyzer.growingGroups(previous: previous, current: current, intervalSeconds: 0).isEmpty)
        XCTAssertTrue(analyzer.growingGroups(previous: previous, current: current, intervalSeconds: -1).isEmpty)
        XCTAssertTrue(analyzer.growingGroups(previous: previous, current: current, intervalSeconds: .nan).isEmpty)
        XCTAssertTrue(analyzer.growingGroups(previous: previous, current: current, intervalSeconds: .infinity).isEmpty)
    }

    func testAdaptiveSamplingPolicyThrottlesBackgroundProcessScans() {
        let policy = AdaptiveSamplingPolicy(
            backgroundIntervalSeconds: 20,
            panelIntervalSeconds: 3,
            pressureIntervalSeconds: 5,
            backgroundProcessIntervalSeconds: 60,
            pressureProcessIntervalSeconds: 10
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: false,
                now: start,
                lastProcessSampleAt: nil
            ),
            .backgroundProcess
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: false,
                now: start.addingTimeInterval(20),
                lastProcessSampleAt: start
            ),
            .background
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: false,
                now: start.addingTimeInterval(60),
                lastProcessSampleAt: start
            ),
            .backgroundProcess
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: true,
                pressureActive: false,
                now: start.addingTimeInterval(1),
                lastProcessSampleAt: start
            ),
            .panel
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: true,
                now: start.addingTimeInterval(1),
                lastProcessSampleAt: start
            ),
            .background
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: true,
                now: start.addingTimeInterval(10),
                lastProcessSampleAt: start
            ),
            .pressure
        )
        XCTAssertEqual(
            policy.cadenceDescription(panelPresented: false, pressureActive: true),
            "系统约 5 秒 · 进程约 10 秒"
        )
        XCTAssertEqual(
            policy.samplingMode(
                panelPresented: false,
                pressureActive: false,
                now: start.addingTimeInterval(-1),
                lastProcessSampleAt: start
            ),
            .backgroundProcess
        )
    }

    func testMonitorSamplerSkipsProcessEnumerationInBackgroundMode() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let system = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let sampledProcess = makeProcess(pid: 900, name: "worker", footprint: 100)
        let sampler = MonitorSampler(
            systemSampler: { system },
            cpuSampler: { CPUTimeSnapshot(userTicks: 10, systemTicks: 5, idleTicks: 85, niceTicks: 0) },
            gpuSampler: { GPUUsageSample(fraction: nil, status: .unavailable()) },
            processSampler: {
                ProcessSamplingResult(
                    processes: [sampledProcess],
                    listedProcessCount: 1,
                    sampledProcessCount: 1,
                    skippedProcessCount: 0,
                    status: .available(at: timestamp)
                )
            }
        )

        let snapshot = sampler.sample(mode: .background, at: timestamp)

        XCTAssertFalse(snapshot.didSampleProcesses)
        XCTAssertEqual(snapshot.samplingMode, .background)
        XCTAssertEqual(snapshot.processStatus.quality, .unavailable)
        XCTAssertTrue(snapshot.processes.isEmpty)
        XCTAssertNil(snapshot.diagnostics.processDurationMilliseconds)
    }

    func testRecommendationEngineReportsGrowthWithSwapEvidence() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let previousTimestamp = timestamp.addingTimeInterval(-60)
        let previousSystem = makePressureSnapshot(
            timestamp: previousTimestamp,
            availableFraction: 0.25,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 5 * 1024 * 1024 * 1024
        )
        let currentSystem = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.15,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 4 * 1024 * 1024 * 1024
        )
        let previousGroup = makeGroup(id: "runtime-node-api", title: "Node · api", footprint: 500 * 1024 * 1024)
        let currentGroup = makeGroup(id: "runtime-node-api", title: "Node · api", footprint: 900 * 1024 * 1024)
        let currentProcess = makeProcess(
            pid: 1201,
            name: "node",
            footprint: currentGroup.physicalFootprintBytes
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: currentSystem,
            groups: [currentGroup],
            processes: [currentProcess]
        )

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(
                current: current,
                previousSystem: previousSystem,
                previousProcessSystem: previousSystem,
                previousGroups: [previousGroup],
                previousProcessStatus: .available(at: previousTimestamp),
                previousProcessInventoryIsComplete: true
            )
        )

        let growth = try! XCTUnwrap(recommendations.first { $0.id == "growth-runtime-node-api" })
        XCTAssertEqual(growth.severity, .attention)
        XCTAssertTrue(growth.evidence.contains { $0.label == "Swap 增量" })
        XCTAssertEqual(growth.targetGroupID, "runtime-node-api")
        XCTAssertEqual(growth.title, "Node · api 较上一轮增加")
        XCTAssertTrue(growth.evidence.contains { $0.label == "速度" && $0.value.contains("/分钟") })
    }

    func testRecommendationEngineUsesProcessSampleBaselineForGrowthInterval() {
        let firstProcessTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let latestTimestamp = firstProcessTimestamp.addingTimeInterval(60)
        let previousProcessSystem = makeSystemSnapshot(
            timestamp: firstProcessTimestamp,
            compressed: 0,
            swap: 0
        )
        let interveningSystem = makeSystemSnapshot(
            timestamp: latestTimestamp.addingTimeInterval(-1),
            compressed: 0,
            swap: 0
        )
        let currentSystem = makeSystemSnapshot(
            timestamp: latestTimestamp,
            compressed: 0,
            swap: 0
        )
        let currentGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 900 * 1024 * 1024
        )
        let previousGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 500 * 1024 * 1024
        )
        let currentProcess = makeProcess(
            pid: 1202,
            name: "node",
            footprint: currentGroup.physicalFootprintBytes
        )
        let current = makeMonitorSnapshot(
            timestamp: latestTimestamp,
            system: currentSystem,
            groups: [currentGroup],
            processes: [currentProcess]
        )

        let recommendation = try! XCTUnwrap(
            RecommendationEngine().evaluate(
                RecommendationContext(
                    current: current,
                    previousSystem: interveningSystem,
                    previousProcessSystem: previousProcessSystem,
                    previousGroups: [previousGroup],
                    previousProcessStatus: .available(at: firstProcessTimestamp),
                    previousProcessInventoryIsComplete: true
                )
            ).first { $0.id == "growth-runtime-node-api" }
        )

        XCTAssertTrue(recommendation.evidence.contains { $0.value == "400.0 MiB/分钟" })
    }

    func testRecommendationEngineIgnoresInvalidPairedSystemForProcessGrowth() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let previousTimestamp = timestamp.addingTimeInterval(-60)
        let currentSystem = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let invalidPreviousProcessSystem = makeSystemSnapshot(
            timestamp: Date(timeIntervalSince1970: .nan),
            compressed: 0,
            swap: 0
        )
        let previousGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024
        )
        let currentGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 200 * 1024 * 1024
        )
        let currentProcess = makeProcess(
            pid: 1207,
            name: "node",
            footprint: currentGroup.physicalFootprintBytes
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: currentSystem,
            groups: [currentGroup],
            processes: [currentProcess]
        )

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(
                current: current,
                previousProcessSystem: invalidPreviousProcessSystem,
                previousGroups: [previousGroup],
                previousProcessStatus: .available(at: previousTimestamp),
                previousProcessInventoryIsComplete: true
            )
        )

        let growth = try! XCTUnwrap(
            recommendations.first { $0.id == "growth-runtime-node-api" }
        )
        XCTAssertFalse(growth.evidence.contains { $0.label == "Swap 增量" })
    }

    func testRecommendationEnginePrioritizesLargeUserGroupDuringCriticalPressure() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let system = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.05,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )
        let group = makeGroup(
            id: "chrome",
            title: "Chrome",
            footprint: 3 * 1024 * 1024 * 1024
        )
        let process = makeProcess(pid: 1203, name: "Google Chrome", footprint: group.physicalFootprintBytes)
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: system,
            groups: [group],
            processes: [process]
        )

        let recommendation = try! XCTUnwrap(
            RecommendationEngine().evaluate(RecommendationContext(current: current)).first
        )

        XCTAssertEqual(recommendation.id, "critical-group-chrome")
        XCTAssertEqual(recommendation.severity, .critical)
        XCTAssertEqual(recommendation.targetGroupID, "chrome")
        XCTAssertEqual(recommendation.title, "优先检查 Chrome")
    }

    func testRecommendationEngineSuppressesCriticalGroupWhenFootprintIsEstimated() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let system = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.05,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )
        let group = makeGroup(
            id: "chrome",
            title: "Chrome",
            footprint: 3 * 1024 * 1024 * 1024,
            containsEstimatedFootprint: true
        )
        let process = makeProcess(
            pid: 1210,
            name: "Google Chrome",
            footprint: group.physicalFootprintBytes,
            physicalFootprintIsEstimated: true
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: system,
            groups: [group],
            processes: [process],
            processStatus: .estimated(at: timestamp, message: "部分 footprint 使用 RSS 估算")
        )

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(current: current)
        )

        XCTAssertFalse(recommendations.contains { $0.id == "critical-group-chrome" })
        let quality = try! XCTUnwrap(recommendations.first)
        XCTAssertEqual(quality.id, "data-quality-processes")
        XCTAssertTrue(quality.detail.contains("RSS 估算"))
        XCTAssertTrue(quality.evidence.contains {
            $0.label == "footprint 口径" && $0.value == "RSS 估算"
        })
    }

    func testRecommendationEngineSuppressesCriticalGroupAtPartialCoverageBoundary() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let system = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.05,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )
        let group = makeGroup(
            id: "chrome",
            title: "Chrome",
            footprint: 3 * 1024 * 1024 * 1024
        )
        let process = makeProcess(pid: 1211, name: "Google Chrome", footprint: group.physicalFootprintBytes)
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: system,
            groups: [group],
            processes: [process],
            processStatus: .available(at: timestamp),
            listedCount: 2
        )

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(current: current)
        )

        XCTAssertFalse(recommendations.contains { $0.id == "critical-group-chrome" })
        XCTAssertTrue(recommendations.isEmpty)
    }

    func testRecommendationEngineMarksSameQualityEstimatedGrowth() {
        let previousTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let timestamp = previousTimestamp.addingTimeInterval(60)
        let previousSystem = makeSystemSnapshot(timestamp: previousTimestamp, compressed: 0, swap: 0)
        let currentSystem = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let previousGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024,
            containsEstimatedFootprint: true
        )
        let currentGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 200 * 1024 * 1024,
            containsEstimatedFootprint: true
        )
        let process = makeProcess(
            pid: 1212,
            name: "node",
            footprint: currentGroup.physicalFootprintBytes,
            physicalFootprintIsEstimated: true
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: currentSystem,
            groups: [currentGroup],
            processes: [process],
            processStatus: .estimated(at: timestamp, message: "部分 footprint 使用 RSS 估算")
        )

        let recommendation = try! XCTUnwrap(
            RecommendationEngine().evaluate(
                RecommendationContext(
                    current: current,
                    previousProcessSystem: previousSystem,
                    previousGroups: [previousGroup],
                    previousProcessStatus: .estimated(at: previousTimestamp, message: "部分 footprint 使用 RSS 估算"),
                    previousProcessInventoryIsComplete: true
                )
            ).first { $0.id == "growth-runtime-node-api" }
        )

        XCTAssertLessThanOrEqual(recommendation.confidence, 0.50)
        XCTAssertEqual(recommendation.evidence.first?.label, "footprint 口径")
        XCTAssertEqual(recommendation.evidence.first?.value, "RSS 估算")
        XCTAssertTrue(recommendation.detail.contains("RSS 估算"))
    }

    func testRecommendationEngineSuppressesGrowthAcrossFootprintQualityChange() {
        let previousTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let timestamp = previousTimestamp.addingTimeInterval(60)
        let previousSystem = makeSystemSnapshot(timestamp: previousTimestamp, compressed: 0, swap: 0)
        let currentSystem = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let previousGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024,
            containsEstimatedFootprint: true
        )
        let currentGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 200 * 1024 * 1024
        )
        let process = makeProcess(
            pid: 1213,
            name: "node",
            footprint: currentGroup.physicalFootprintBytes
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: currentSystem,
            groups: [currentGroup],
            processes: [process],
            processStatus: .available(at: timestamp)
        )

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(
                current: current,
                previousProcessSystem: previousSystem,
                previousGroups: [previousGroup],
                previousProcessStatus: .estimated(at: previousTimestamp, message: "部分 footprint 使用 RSS 估算"),
                previousProcessInventoryIsComplete: true
            )
        )

        XCTAssertFalse(recommendations.contains { $0.id == "growth-runtime-node-api" })
    }

    func testRecommendationEngineUsesDebouncedPressureLevelWhenProvided() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let system = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.05,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )
        let group = makeGroup(id: "chrome", title: "Chrome", footprint: 3 * 1024 * 1024 * 1024)
        let process = makeProcess(pid: 1204, name: "Google Chrome", footprint: group.physicalFootprintBytes)
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: system,
            groups: [group],
            processes: [process]
        )

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(current: current, pressureLevel: .normal)
        )

        XCTAssertFalse(recommendations.contains { $0.id == "critical-group-chrome" })
    }

    func testRecommendationEngineExplainsRecoveryWhileSwapRemains() {
        let previousTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let timestamp = previousTimestamp.addingTimeInterval(60)
        let previousSystem = makePressureSnapshot(
            timestamp: previousTimestamp,
            availableFraction: 0.15,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 3 * 1024 * 1024 * 1024
        )
        let currentSystem = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.30,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 4 * 1024 * 1024 * 1024
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: currentSystem,
            groups: [],
            didSampleProcesses: false
        )

        let recommendation = try! XCTUnwrap(
            RecommendationEngine().evaluate(
                RecommendationContext(
                    current: current,
                    previousSystem: previousSystem,
                    pressureLevel: .normal,
                    previousPressureLevel: .attention
                )
            ).first
        )

        XCTAssertEqual(recommendation.id, "recovery-swap")
        XCTAssertEqual(recommendation.severity, .info)
    }

    func testRecommendationEngineReportsPartialProcessDataOnlyWhenNoStrongerSignalExists() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let system = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: system,
            groups: [],
            processStatus: .estimated(at: timestamp, message: "部分进程不可读")
        )

        let recommendation = try! XCTUnwrap(
            RecommendationEngine().evaluate(RecommendationContext(current: current)).first
        )

        XCTAssertEqual(recommendation.id, "data-quality-processes")
        XCTAssertEqual(recommendation.severity, .info)
    }

    func testRecommendationEngineSuppressesCriticalGroupForLowCoverage() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let system = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.05,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )
        let group = makeGroup(id: "chrome", title: "Chrome", footprint: 3 * 1024 * 1024 * 1024)
        let process = makeProcess(pid: 1205, name: "Google Chrome", footprint: group.physicalFootprintBytes)
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: system,
            groups: [group],
            processes: [process],
            processStatus: .estimated(at: timestamp, message: "大部分条目不可读"),
            listedCount: 10
        )

        let recommendations = RecommendationEngine().evaluate(RecommendationContext(current: current))

        XCTAssertFalse(recommendations.contains { $0.id == "critical-group-chrome" })
        XCTAssertEqual(recommendations.first?.id, "data-quality-processes")
    }

    func testRecommendationEngineSuppressesGrowthForLowCoverage() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_060)
        let previousTimestamp = timestamp.addingTimeInterval(-60)
        let previousSystem = makeSystemSnapshot(timestamp: previousTimestamp, compressed: 0, swap: 0)
        let currentSystem = makeSystemSnapshot(timestamp: timestamp, compressed: 0, swap: 0)
        let previousGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024
        )
        let currentGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 200 * 1024 * 1024
        )
        let process = makeProcess(pid: 1206, name: "node", footprint: currentGroup.physicalFootprintBytes)
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: currentSystem,
            groups: [currentGroup],
            processes: [process],
            processStatus: .estimated(at: timestamp),
            listedCount: 10
        )

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(
                current: current,
                previousSystem: previousSystem,
                previousGroups: [previousGroup],
                previousProcessStatus: .available(at: previousTimestamp),
                previousProcessInventoryIsComplete: true
            )
        )

        XCTAssertFalse(recommendations.contains { $0.id == "growth-runtime-node-api" })
        XCTAssertEqual(recommendations.first?.id, "data-quality-processes")
    }

    func testRecommendationEngineRequiresCompletePreviousInventoryForGrowth() {
        let previousTimestamp = Date(timeIntervalSince1970: 1_700_010_000)
        let timestamp = previousTimestamp.addingTimeInterval(60)
        let previousGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024
        )
        let currentGroup = makeGroup(
            id: previousGroup.id,
            title: previousGroup.title,
            footprint: 200 * 1024 * 1024
        )
        let process = makeProcess(
            pid: 1220,
            name: "node",
            footprint: currentGroup.physicalFootprintBytes
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: nil,
            groups: [currentGroup],
            processes: [process]
        )

        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(
                current: current,
                previousGroups: [previousGroup],
                previousProcessStatus: .available(at: previousTimestamp),
                previousProcessInventoryIsComplete: false
            )
        )

        XCTAssertFalse(recommendations.contains { $0.id == "growth-runtime-node-api" })
    }

    func testRecommendationEngineRejectsExpiredAndNonIncreasingProcessBaselines() {
        let previousTimestamp = Date(timeIntervalSince1970: 1_700_020_000)
        let currentTimestamp = previousTimestamp.addingTimeInterval(10 * 60)
        let previousGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024
        )
        let currentGroup = makeGroup(
            id: previousGroup.id,
            title: previousGroup.title,
            footprint: 200 * 1024 * 1024
        )
        let process = makeProcess(
            pid: 1221,
            name: "node",
            footprint: currentGroup.physicalFootprintBytes
        )
        let expired = makeMonitorSnapshot(
            timestamp: currentTimestamp,
            system: nil,
            groups: [currentGroup],
            processes: [process],
            processStatus: .available(at: currentTimestamp)
        )
        let nonIncreasing = makeMonitorSnapshot(
            timestamp: previousTimestamp.addingTimeInterval(60),
            system: nil,
            groups: [currentGroup],
            processes: [process],
            processStatus: .available(at: previousTimestamp)
        )
        let context: (MonitorSnapshot) -> RecommendationContext = { current in
            RecommendationContext(
                current: current,
                previousGroups: [previousGroup],
                previousProcessStatus: .available(at: previousTimestamp),
                previousProcessInventoryIsComplete: true
            )
        }

        XCTAssertFalse(RecommendationEngine().evaluate(context(expired)).contains {
            $0.id == "growth-runtime-node-api"
        })
        XCTAssertFalse(RecommendationEngine().evaluate(context(nonIncreasing)).contains {
            $0.id == "growth-runtime-node-api"
        })
    }

    func testRecommendationEngineZeroSwapGrowthThresholdStillRequiresPositiveDelta() {
        let previousTimestamp = Date(timeIntervalSince1970: 1_700_030_000)
        let timestamp = previousTimestamp.addingTimeInterval(60)
        let previousSystem = makePressureSnapshot(
            timestamp: previousTimestamp,
            availableFraction: 0.30,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 6 * 1024 * 1024 * 1024
        )
        let currentSystem = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.30,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 6 * 1024 * 1024 * 1024
        )
        let previousGroup = makeGroup(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024
        )
        let currentGroup = makeGroup(
            id: previousGroup.id,
            title: previousGroup.title,
            footprint: 200 * 1024 * 1024
        )
        let process = makeProcess(
            pid: 1222,
            name: "node",
            footprint: currentGroup.physicalFootprintBytes
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: currentSystem,
            groups: [currentGroup],
            processes: [process]
        )

        let recommendation = try! XCTUnwrap(
            RecommendationEngine(swapGrowthThresholdBytes: 0).evaluate(
                RecommendationContext(
                    current: current,
                    previousProcessSystem: previousSystem,
                    previousGroups: [previousGroup],
                    previousProcessStatus: .available(at: previousTimestamp),
                    previousProcessInventoryIsComplete: true
                )
            ).first { $0.id == "growth-runtime-node-api" }
        )

        XCTAssertEqual(recommendation.severity, .info)
        XCTAssertFalse(recommendation.detail.contains("Swap 上升"))
        XCTAssertFalse(recommendation.evidence.contains { $0.label == "Swap 增量" })
    }

    func testRecommendationEngineDoesNotCallRisingOrUnchangedSwapRecovery() {
        let previousTimestamp = Date(timeIntervalSince1970: 1_700_040_000)
        let timestamp = previousTimestamp.addingTimeInterval(60)
        let previousSystem = makePressureSnapshot(
            timestamp: previousTimestamp,
            availableFraction: 0.15,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 5 * 1024 * 1024 * 1024
        )

        for swapFreeBytes in [
            5 * UInt64(1024 * 1024 * 1024),
            4 * UInt64(1024 * 1024 * 1024)
        ] {
            let currentSystem = makePressureSnapshot(
                timestamp: timestamp,
                availableFraction: 0.30,
                swapTotalBytes: 8 * 1024 * 1024 * 1024,
                swapFreeBytes: swapFreeBytes
            )
            let current = makeMonitorSnapshot(
                timestamp: timestamp,
                system: currentSystem,
                groups: [],
                didSampleProcesses: false
            )
            let recommendations = RecommendationEngine().evaluate(
                RecommendationContext(
                    current: current,
                    previousSystem: previousSystem,
                    pressureLevel: .normal,
                    previousPressureLevel: .attention
                )
            )

            XCTAssertFalse(recommendations.contains { $0.id == "recovery-swap" })
        }
    }

    func testRecommendationEngineExcludesMonitorAndArbitrarySystemGroups() {
        let previousTimestamp = Date(timeIntervalSince1970: 1_700_050_000)
        let timestamp = previousTimestamp.addingTimeInterval(60)
        let monitor = makeProcess(
            pid: 1223,
            name: "memory-monitor-app",
            footprint: 3 * 1024 * 1024 * 1024
        )
        let previousMonitorGroup = makeGroup(
            id: "process-memory-monitor-app",
            title: "Memory Monitor",
            footprint: 100 * 1024 * 1024,
            memberProcessIdentities: [monitor.identity]
        )
        let currentMonitorGroup = makeGroup(
            id: previousMonitorGroup.id,
            title: previousMonitorGroup.title,
            footprint: monitor.physicalFootprintBytes,
            memberProcessIdentities: [monitor.identity]
        )
        let criticalSystem = makePressureSnapshot(
            timestamp: timestamp,
            availableFraction: 0.05,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: criticalSystem,
            groups: [currentMonitorGroup],
            processes: [monitor]
        )
        let recommendations = RecommendationEngine().evaluate(
            RecommendationContext(
                current: current,
                previousGroups: [previousMonitorGroup],
                previousProcessStatus: .available(at: previousTimestamp),
                previousProcessInventoryIsComplete: true,
                excludedProcessIDs: [monitor.identity.pid],
                pressureLevel: .critical
            )
        )

        XCTAssertFalse(recommendations.contains { $0.targetGroupID == currentMonitorGroup.id })

        let systemGroup = makeGroup(
            id: "vendor-daemon",
            title: "Vendor Daemon",
            footprint: 200 * 1024 * 1024,
            isSystem: true
        )
        let previousSystemGroup = makeGroup(
            id: systemGroup.id,
            title: systemGroup.title,
            footprint: 100 * 1024 * 1024,
            isSystem: true
        )
        let systemRecommendations = RecommendationEngine().evaluate(
            RecommendationContext(
                current: makeMonitorSnapshot(
                    timestamp: timestamp,
                    system: nil,
                    groups: [systemGroup],
                    processes: [monitor]
                ),
                previousGroups: [previousSystemGroup],
                previousProcessStatus: .available(at: previousTimestamp),
                previousProcessInventoryIsComplete: true
            )
        )
        XCTAssertFalse(systemRecommendations.contains { $0.id == "growth-vendor-daemon" })
    }

    func testRecommendationEngineReportsProcessQualityWithoutSystemSample() {
        let timestamp = Date(timeIntervalSince1970: 1_700_060_000)
        let process = makeProcess(pid: 1224, name: "node", footprint: 100)
        let current = makeMonitorSnapshot(
            timestamp: timestamp,
            system: nil,
            groups: [],
            processes: [process],
            processStatus: .estimated(at: timestamp, message: "部分进程不可读"),
            listedCount: 2
        )

        XCTAssertEqual(
            RecommendationEngine().evaluate(RecommendationContext(current: current)).first?.id,
            "data-quality-processes"
        )
    }

    func testAdaptiveSamplingPolicyUsesPanelCadenceFirst() {
        let policy = AdaptiveSamplingPolicy(
            backgroundIntervalSeconds: 20,
            panelIntervalSeconds: 3,
            pressureIntervalSeconds: 5
        )

        XCTAssertEqual(policy.intervalSeconds(panelPresented: true, pressureActive: false), 3)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: true, pressureActive: true), 3)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: false, pressureActive: true), 5)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: false, pressureActive: false), 20)
    }

    func testAdaptiveSamplingPolicyPreventsNonPositiveIntervals() {
        let policy = AdaptiveSamplingPolicy(
            backgroundIntervalSeconds: 0,
            panelIntervalSeconds: -2,
            pressureIntervalSeconds: .nan
        )

        XCTAssertEqual(policy.intervalSeconds(panelPresented: false, pressureActive: false), 0.1)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: true, pressureActive: false), 0.1)
        XCTAssertEqual(policy.intervalSeconds(panelPresented: false, pressureActive: true), 0.1)

        let infinitePolicy = AdaptiveSamplingPolicy(pressureIntervalSeconds: .infinity)
        XCTAssertEqual(infinitePolicy.intervalSeconds(panelPresented: false, pressureActive: true), 0.1)
    }

    func testMemoryPressureEvaluatorDebouncesTransientTransitions() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var evaluator = MemoryPressureEvaluator(transitionIntervalSeconds: 30)

        XCTAssertEqual(evaluator.update(observed: .normal, at: start), .normal)
        XCTAssertEqual(
            evaluator.update(observed: .attention, at: start.addingTimeInterval(10)),
            .normal
        )
        XCTAssertEqual(evaluator.pendingLevel, .attention)
        XCTAssertTrue(evaluator.pressureActiveForSampling)

        XCTAssertEqual(
            evaluator.update(observed: .normal, at: start.addingTimeInterval(20)),
            .normal
        )
        XCTAssertNil(evaluator.pendingLevel)
        XCTAssertFalse(evaluator.pressureActiveForSampling)
    }

    func testMemoryPressureEvaluatorCommitsSustainedUpgradeAndRecovery() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var evaluator = MemoryPressureEvaluator(transitionIntervalSeconds: 30)

        XCTAssertEqual(evaluator.update(observed: .normal, at: start), .normal)
        XCTAssertEqual(
            evaluator.update(observed: .critical, at: start.addingTimeInterval(1)),
            .normal
        )
        XCTAssertEqual(
            evaluator.update(observed: .critical, at: start.addingTimeInterval(30)),
            .normal
        )
        XCTAssertEqual(
            evaluator.update(observed: .critical, at: start.addingTimeInterval(31)),
            .critical
        )

        XCTAssertEqual(
            evaluator.update(observed: .normal, at: start.addingTimeInterval(60)),
            .critical
        )
        XCTAssertEqual(
            evaluator.update(observed: .normal, at: start.addingTimeInterval(61)),
            .critical
        )
        XCTAssertEqual(
            evaluator.update(observed: .normal, at: start.addingTimeInterval(91)),
            .normal
        )
    }

    func testMemoryPressureEvaluatorIgnoresNonFiniteTimestamps() {
        let invalidDates = [
            Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: -.infinity)
        ]

        for invalidDate in invalidDates {
            var uninitialized = MemoryPressureEvaluator(transitionIntervalSeconds: 30)
            XCTAssertEqual(uninitialized.update(observed: .critical, at: invalidDate), .critical)
            XCTAssertNil(uninitialized.stableLevel)
            XCTAssertNil(uninitialized.pendingLevel)

            var initialized = MemoryPressureEvaluator(transitionIntervalSeconds: 30)
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            XCTAssertEqual(initialized.update(observed: .normal, at: start), .normal)
            XCTAssertEqual(initialized.update(observed: .critical, at: invalidDate), .normal)
            XCTAssertEqual(initialized.stableLevel, .normal)
            XCTAssertNil(initialized.pendingLevel)
        }
    }

    func testMemoryPressureEvaluatorIgnoresStructurallyInvalidSnapshot() {
        let valid = makePressureSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.40
        )
        let invalid = SystemMemorySnapshot(
            timestamp: valid.timestamp.addingTimeInterval(1),
            totalBytes: 100,
            pageSize: 1,
            freeBytes: UInt64.max,
            activeBytes: 0,
            inactiveBytes: 1,
            speculativeBytes: 0,
            wiredBytes: 0,
            purgeableBytes: 0,
            compressedBytes: 0,
            throttledPages: 0,
            swapTotalBytes: 0,
            swapUsedBytes: 0,
            swapFreeBytes: 0
        )

        var evaluator = MemoryPressureEvaluator(transitionIntervalSeconds: 0)
        XCTAssertEqual(evaluator.update(snapshot: valid), .normal)
        XCTAssertEqual(evaluator.update(snapshot: invalid), .normal)
        XCTAssertEqual(evaluator.stableLevel, .normal)
        XCTAssertNil(evaluator.pendingLevel)
    }

    func testProcessSnapshotSanitizesDisplayName() {
        let process = makeProcess(
            pid: 99,
            name: "worker\u{001B}[31m\n\u{202E}",
            footprint: 100
        )

        XCTAssertEqual(process.name, "worker[31m")
        XCTAssertFalse(process.name.unicodeScalars.contains { scalar in
            scalar.value < 0x20
                || (0x7F...0x9F).contains(scalar.value)
                || (0x202A...0x202E).contains(scalar.value)
        })
    }

    func testMemoryPressureEvaluatorClassifiesCriticalBeforeAttention() {
        let snapshot = makePressureSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.05,
            compressedBytes: 8 * 1024 * 1024 * 1024
        )

        XCTAssertEqual(MemoryPressureEvaluator.observedLevel(for: snapshot), .critical)
    }

    func testMemoryPressureEvaluatorUsesSwapThreshold() {
        let snapshot = makePressureSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.30,
            swapTotalBytes: 8 * 1024 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )

        XCTAssertEqual(MemoryPressureEvaluator.observedLevel(for: snapshot), .critical)
    }

    func testMemoryPressureEvaluatorDoesNotTreatUnusedSmallSwapAsCritical() {
        let snapshot = makePressureSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.30,
            swapTotalBytes: 512 * 1024 * 1024,
            swapFreeBytes: 512 * 1024 * 1024
        )

        XCTAssertEqual(MemoryPressureEvaluator.observedLevel(for: snapshot), .normal)
    }

    func testMemoryHistoryBufferKeepsNewestEntries() {
        let first = makeSystemSnapshot(timestamp: Date(timeIntervalSince1970: 1), compressed: 10, swap: 20)
        let second = makeSystemSnapshot(timestamp: Date(timeIntervalSince1970: 2), compressed: 11, swap: 21)
        let third = makeSystemSnapshot(timestamp: Date(timeIntervalSince1970: 3), compressed: 12, swap: 22)
        var history = MemoryHistoryBuffer(capacity: 2)

        history.append(snapshot: first)
        history.append(snapshot: second)
        history.append(snapshot: third)

        XCTAssertEqual(history.entries.map(\.timestamp), [second.timestamp, third.timestamp])
        XCTAssertEqual(history.entries.map(\.compressedBytes), [11, 12])
    }

    func testMemoryHistoryAnalyzerSummarizesWindowAndPeaks() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeHistoryRecord(timestamp: base, availableFraction: 0.60, swapUsedBytes: 100),
            makeHistoryRecord(timestamp: base.addingTimeInterval(60), availableFraction: 0.25, swapUsedBytes: 200),
            makeHistoryRecord(timestamp: base.addingTimeInterval(120), availableFraction: 0.40, swapUsedBytes: 300)
        ]

        let analysis = MemoryHistoryAnalyzer().analyze(records)

        XCTAssertEqual(analysis.sampleCount, 3)
        XCTAssertEqual(analysis.firstTimestamp, base)
        XCTAssertEqual(analysis.lastTimestamp, base.addingTimeInterval(120))
        XCTAssertEqual(try! XCTUnwrap(analysis.latestUsedFraction), 0.60, accuracy: 0.0001)
        XCTAssertEqual(try! XCTUnwrap(analysis.peakUsedFraction), 0.75, accuracy: 0.0001)
        XCTAssertEqual(analysis.latestSwapUsedBytes, 300)
        XCTAssertEqual(analysis.peakSwapUsedBytes, 300)
        XCTAssertEqual(analysis.windowDuration, 120, accuracy: 0.001)
        XCTAssertTrue(analysis.events.isEmpty)
    }

    func testMemoryHistoryAnalyzerEmitsPressureAndSwapThresholdEvents() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeHistoryRecord(timestamp: base, availableFraction: 0.30, swapUsedBytes: 0),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.15,
                swapUsedBytes: 2 * 1024 * 1024 * 1024
            ),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(120),
                availableFraction: 0.08,
                swapUsedBytes: 5 * 1024 * 1024 * 1024
            ),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(180),
                availableFraction: 0.25,
                swapUsedBytes: 3 * 1024 * 1024 * 1024
            ),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(240),
                availableFraction: 0.30,
                swapUsedBytes: 512 * 1024 * 1024
            )
        ]

        let analysis = MemoryHistoryAnalyzer().analyze(records)

        XCTAssertEqual(analysis.pressureTransitionCount, 3)
        XCTAssertEqual(
            analysis.events.filter { $0.kind == .pressureTransition }.count,
            3
        )
        XCTAssertTrue(analysis.events.contains { $0.title == "内存压力进入注意" })
        XCTAssertTrue(analysis.events.contains { $0.title == "内存压力进入严重" })
        XCTAssertTrue(analysis.events.contains { $0.title == "内存压力恢复正常" })
        XCTAssertTrue(analysis.events.contains { $0.title == "Swap 超过 1.0 GiB" })
        XCTAssertTrue(analysis.events.contains { $0.title == "Swap 超过 4.0 GiB" })
        XCTAssertTrue(analysis.events.contains { $0.title == "Swap 回落至 1.0 GiB 以下" })
    }

    func testMemoryHistoryAnalyzerDescribesWorkloadRankingChanges() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let api = makePersistedWorkload(id: "runtime-node-api", title: "Node · api", footprint: 200 * 1024 * 1024)
        let worker = makePersistedWorkload(id: "runtime-python-worker", title: "Python · worker", footprint: 128 * 1024 * 1024)
        let largerAPI = makePersistedWorkload(id: api.id, title: api.title, footprint: 800 * 1024 * 1024)

        let records = [
            makeHistoryRecord(timestamp: base, availableFraction: 0.40, swapUsedBytes: 0, workloads: [api]),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.40,
                swapUsedBytes: 0,
                workloads: [largerAPI, worker]
            ),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(120),
                availableFraction: 0.40,
                swapUsedBytes: 0,
                workloads: [worker]
            )
        ]

        let analysis = MemoryHistoryAnalyzer().analyze(records)

        XCTAssertTrue(analysis.events.contains {
            $0.kind == .workloadAppeared && $0.targetID == worker.id
        })
        XCTAssertTrue(analysis.events.contains {
            $0.kind == .workloadGrowth && $0.targetID == api.id
        })
        XCTAssertTrue(analysis.events.contains {
            $0.kind == .workloadDisappeared && $0.targetID == api.id
        })
        XCTAssertFalse(analysis.events.contains { $0.targetID == "other-processes" })
    }

    func testMemoryHistoryAnalyzerHandlesDuplicateWorkloadIDs() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024
        )
        let replacement = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 300 * 1024 * 1024
        )
        let records = [
            makeHistoryRecord(timestamp: base, availableFraction: 0.40, swapUsedBytes: 0, workloads: [first]),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.40,
                swapUsedBytes: 0,
                workloads: [first, replacement]
            )
        ]

        let analysis = MemoryHistoryAnalyzer().analyze(records)

        XCTAssertEqual(analysis.sampleCount, 2)
        XCTAssertFalse(analysis.events.contains { $0.kind == .workloadAppeared })
        XCTAssertFalse(analysis.events.contains { $0.kind == .workloadDisappeared })

        let sensitiveAnalyzer = MemoryHistoryAnalyzer(
            workloadEventThresholdBytes: 1,
            workloadGrowthThresholdBytes: 150
        )
        let orderedGrowth = sensitiveAnalyzer.analyze(records).events.first {
            $0.kind == .workloadGrowth
        }
        let reversedRecords = [
            records[0],
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.40,
                swapUsedBytes: 0,
                workloads: [replacement, first]
            )
        ]
        let reversedGrowth = sensitiveAnalyzer.analyze(reversedRecords).events.first {
            $0.kind == .workloadGrowth
        }
        XCTAssertEqual(orderedGrowth, reversedGrowth)
        XCTAssertTrue(orderedGrowth?.detail.contains("当前 300.0 MiB") == true)
    }

    func testMemoryHistoryEventIDsUseStableDecimalTimestamp() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = makeHistoryRecord(
            timestamp: base,
            availableFraction: 0.25,
            swapUsedBytes: 0
        )
        let current = makeHistoryRecord(
            timestamp: base.addingTimeInterval(60),
            availableFraction: 0.05,
            swapUsedBytes: 0
        )

        let events = MemoryHistoryAnalyzer().analyze([previous, current]).events
        let pressureEvent = try! XCTUnwrap(events.first { $0.kind == .pressureTransition })

        XCTAssertEqual(pressureEvent.id, "pressureTransition-1700000060-critical")
        XCTAssertFalse(pressureEvent.id.contains(","))
        XCTAssertFalse(pressureEvent.id.contains("."))
    }

    func testMemoryHistoryAnalyzerKeepsFreshWorkloadsForDuplicateTimestamp() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100 * 1024 * 1024
        )
        let stale = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 200 * 1024 * 1024
        )
        let fresh = makePersistedWorkload(
            id: "runtime-python-worker",
            title: "Python · worker",
            footprint: 300 * 1024 * 1024
        )
        let records = [
            MemoryHistoryRecord(
                timestamp: base,
                availableFraction: 0.40,
                compressedBytes: 0,
                swapUsedBytes: 0,
                workloads: [previous],
                workloadsSampledAt: base
            ),
            MemoryHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.40,
                compressedBytes: 0,
                swapUsedBytes: 0,
                workloads: [stale],
                workloadsSampledAt: base.addingTimeInterval(60)
            ),
            MemoryHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.40,
                compressedBytes: 0,
                swapUsedBytes: 0,
                workloads: [fresh],
                workloadsSampledAt: base.addingTimeInterval(61)
            )
        ]

        let analysis = MemoryHistoryAnalyzer().analyze(records)

        XCTAssertTrue(analysis.events.contains {
            $0.kind == .workloadAppeared && $0.targetID == fresh.id
        })
        XCTAssertFalse(analysis.events.contains {
            $0.kind == .workloadAppeared && $0.targetID == stale.id
        })
    }

    func testMemoryHistoryWorkloadTieBreakIsIndependentOfInputOrder() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let smaller = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100
        )
        let larger = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 300
        )
        let existing = MemoryHistoryRecord(
            timestamp: base,
            availableFraction: 0.40,
            compressedBytes: 0,
            swapUsedBytes: 0,
            workloads: [smaller],
            workloadsSampledAt: base
        )
        let candidate = MemoryHistoryRecord(
            timestamp: base,
            availableFraction: 0.40,
            compressedBytes: 0,
            swapUsedBytes: 0,
            workloads: [larger],
            workloadsSampledAt: base
        )

        let forward = HistoryStore.preferredWorkloadPayload(
            existing: existing,
            candidate: candidate
        )
        let reverse = HistoryStore.preferredWorkloadPayload(
            existing: candidate,
            candidate: existing
        )

        XCTAssertEqual(forward.workloads, reverse.workloads)
        XCTAssertEqual(forward.sampledAt, reverse.sampledAt)
        XCTAssertEqual(forward.workloads, [larger])

        let first = makePersistedWorkload(id: "a", title: "A", footprint: 1)
        let second = makePersistedWorkload(id: "b", title: "B", footprint: 1)
        let unsorted = MemoryHistoryRecord(
            timestamp: base,
            availableFraction: 0.40,
            compressedBytes: 0,
            swapUsedBytes: 0,
            workloads: [second, first],
            workloadsSampledAt: nil
        )
        let canonical = HistoryStore.preferredWorkloadPayload(
            existing: unsorted,
            candidate: unsorted
        )
        XCTAssertEqual(canonical.workloads.map(\.id), ["a", "b"])
    }

    func testMemoryHistoryAnalyzerTieBreakIsIndependentOfInputOrder() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let baseline = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 50
        )
        let smaller = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 100
        )
        let larger = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 300
        )
        let previous = MemoryHistoryRecord(
            timestamp: base,
            availableFraction: 0.40,
            compressedBytes: 0,
            swapUsedBytes: 0,
            workloads: [baseline],
            workloadsSampledAt: base
        )
        func duplicate(_ workload: PersistedWorkloadRecord) -> MemoryHistoryRecord {
            MemoryHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.40,
                compressedBytes: 0,
                swapUsedBytes: 0,
                workloads: [workload],
                workloadsSampledAt: base.addingTimeInterval(60)
            )
        }

        let analyzer = MemoryHistoryAnalyzer(
            workloadEventThresholdBytes: 1,
            workloadGrowthThresholdBytes: 150
        )
        let forward = analyzer.analyze([previous, duplicate(smaller), duplicate(larger)])
        let reverse = analyzer.analyze([previous, duplicate(larger), duplicate(smaller)])

        XCTAssertEqual(forward.events, reverse.events)
        XCTAssertTrue(forward.events.contains { $0.detail.contains("当前 300") })
    }

    func testHistoryRecordWithoutWorkloadSampleTimestampDoesNotEmitWorkloadEvents() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let workload = makePersistedWorkload(
            id: "runtime-node-api",
            title: "Node · api",
            footprint: 200 * 1024 * 1024
        )
        let legacyRecord = MemoryHistoryRecord(
            timestamp: base,
            availableFraction: 0.40,
            compressedBytes: 0,
            swapUsedBytes: 0,
            workloads: [workload],
            workloadsSampledAt: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(MemoryHistoryFile(records: [legacyRecord]))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("workloadsSampledAt"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedFile = try decoder.decode(MemoryHistoryFile.self, from: encoded)
        XCTAssertNil(decodedFile.records[0].workloadsSampledAt)

        let current = MemoryHistoryRecord(
            timestamp: base.addingTimeInterval(60),
            availableFraction: 0.40,
            compressedBytes: 0,
            swapUsedBytes: 0,
            workloads: [workload],
            workloadsSampledAt: base.addingTimeInterval(60)
        )
        let analysis = MemoryHistoryAnalyzer().analyze([decodedFile.records[0], current])
        XCTAssertFalse(analysis.events.contains { $0.targetID == workload.id })
    }

    func testHistoryStoreStartsEmptyWhenFileIsMissing() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(fileURL: url)
        let records = try await store.load(now: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testHistoryStoreMergeOfOnlyExpiredRecordsDoesNotCreateSnapshot() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(fileURL: url, retentionInterval: 120)
        let expired = makeHistoryRecord(
            timestamp: now.addingTimeInterval(-600),
            availableFraction: 0.40,
            swapUsedBytes: 1
        )

        let merged = try await store.merge(records: [expired], now: now)

        XCTAssertTrue(merged.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalURL.path))
    }

    func testHistoryStoreCoalescesMinuteAndReloadsFromDisk() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let group = makeGroup(id: "chrome", title: "Chrome", footprint: 300)
        let store = HistoryStore(fileURL: url)

        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base.addingTimeInterval(5), compressed: 10, swap: 20),
            groups: [group],
            now: base.addingTimeInterval(5)
        )
        let firstDiskData = try Data(contentsOf: url)
        let records = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base.addingTimeInterval(55), compressed: 20, swap: 30),
            groups: [group],
            now: base.addingTimeInterval(55)
        )
        XCTAssertEqual(try Data(contentsOf: url), firstDiskData)
        try await store.flush()

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].compressedBytes, 20)
        XCTAssertNotEqual(try Data(contentsOf: url), firstDiskData)
        XCTAssertEqual(records[0].workloads.first?.attributedFootprintBytes, 300)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let reloaded = HistoryStore(fileURL: url)
        let loadedRecords = try await reloaded.load(now: base.addingTimeInterval(60))
        XCTAssertEqual(loadedRecords, records)
    }

    func testHistoryStoreSerializesConcurrentActorAppends() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_900_000)
        let seed = HistoryStore(fileURL: url, compactionRecordThreshold: 10_000)
        _ = try await seed.append(
            makeHistoryRecord(timestamp: base, availableFraction: 0.5, swapUsedBytes: 0),
            now: base
        )

        let records = (1...24).map { index in
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(Double(index) * 60),
                availableFraction: 0.5,
                swapUsedBytes: UInt64(index)
            )
        }
        let stores = records.map { _ in
            HistoryStore(fileURL: url, compactionRecordThreshold: 10_000)
        }
        await withTaskGroup(of: Void.self) { group in
            for (record, store) in zip(records, stores) {
                group.addTask {
                    _ = try? await store.append(record, now: record.timestamp)
                }
            }
        }

        let loaded = try await HistoryStore(fileURL: url, compactionRecordThreshold: 10_000)
            .load(now: base.addingTimeInterval(25 * 60))
        XCTAssertEqual(loaded.count, 25)
        XCTAssertEqual(Set(loaded.map(\.swapUsedBytes)), Set((0...24).map(UInt64.init)))
    }

    func testHistoryStoreMergesSameMinutePendingRecordsAcrossActors() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let minute = Date(timeIntervalSince1970: 1_699_999_980)
        let firstStore = HistoryStore(fileURL: url)
        let secondStore = HistoryStore(fileURL: url)
        _ = try await firstStore.append(
            snapshot: makeSystemSnapshot(
                timestamp: minute.addingTimeInterval(5),
                compressed: 1,
                swap: 1
            ),
            now: minute.addingTimeInterval(5)
        )
        _ = try await secondStore.load(now: minute.addingTimeInterval(5))

        _ = try await firstStore.append(
            snapshot: makeSystemSnapshot(
                timestamp: minute.addingTimeInterval(20),
                compressed: 2,
                swap: 2
            ),
            now: minute.addingTimeInterval(20)
        )
        _ = try await secondStore.append(
            snapshot: makeSystemSnapshot(
                timestamp: minute.addingTimeInterval(40),
                compressed: 3,
                swap: 3
            ),
            now: minute.addingTimeInterval(40)
        )

        // Flush the older pending value last. Freshness-aware merging must
        // still keep the sample captured at +40 seconds.
        try await secondStore.flush(now: minute.addingTimeInterval(40))
        try await firstStore.flush(now: minute.addingTimeInterval(40))

        let loaded = try await HistoryStore(fileURL: url)
            .load(now: minute.addingTimeInterval(40))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].compressedBytes, 3)
        XCTAssertEqual(loaded[0].swapUsedBytes, 3)
        XCTAssertEqual(loaded[0].sourceSampledAt, minute.addingTimeInterval(40))
    }

    func testHistoryStoreIgnoresOrphanClockAnchorAfterDataReset() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let future = Date(timeIntervalSince1970: 1_700_000_600)
        let original = HistoryStore(fileURL: url, retentionInterval: 300)
        _ = try await original.append(
            snapshot: makeSystemSnapshot(timestamp: future, compressed: 1, swap: 1),
            now: future
        )

        try FileManager.default.removeItem(at: url)
        let resetNow = future.addingTimeInterval(-600)
        let resetStore = HistoryStore(fileURL: url, retentionInterval: 300)
        let records = try await resetStore.append(
            snapshot: makeSystemSnapshot(timestamp: resetNow, compressed: 2, swap: 2),
            now: resetNow
        )

        XCTAssertEqual(records.map(\.compressedBytes), [2])
        let reloaded = try await HistoryStore(fileURL: url, retentionInterval: 300)
            .load(now: resetNow)
        XCTAssertEqual(reloaded.map(\.compressedBytes), [2])
    }

    func testHistoryStoreWorkloadMergeIsOrderIndependentWithinMinute() async throws {
        let (firstURL, firstDirectory) = makeTemporaryHistoryURL()
        let (secondURL, secondDirectory) = makeTemporaryHistoryURL()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let smaller = makePersistedWorkload(id: "runtime-node-api", title: "Node · api", footprint: 100)
        let larger = makePersistedWorkload(id: "runtime-node-api", title: "Node · api", footprint: 300)
        let firstRecord = MemoryHistoryRecord(
            timestamp: base.addingTimeInterval(5),
            availableFraction: 0.40,
            compressedBytes: 10,
            swapUsedBytes: 20,
            workloads: [smaller],
            workloadsSampledAt: base.addingTimeInterval(5)
        )
        let secondRecord = MemoryHistoryRecord(
            timestamp: base.addingTimeInterval(55),
            availableFraction: 0.40,
            compressedBytes: 20,
            swapUsedBytes: 30,
            workloads: [larger],
            // Equal source markers exercise the deterministic content tie-break
            // rather than the normal freshness path.
            workloadsSampledAt: base.addingTimeInterval(5)
        )

        let forwardStore = HistoryStore(fileURL: firstURL)
        _ = try await forwardStore.append(firstRecord, now: base.addingTimeInterval(5))
        let forward = try await forwardStore.append(secondRecord, now: base.addingTimeInterval(55))

        let reverseStore = HistoryStore(fileURL: secondURL)
        _ = try await reverseStore.append(secondRecord, now: base.addingTimeInterval(55))
        let reverse = try await reverseStore.append(firstRecord, now: base.addingTimeInterval(5))

        XCTAssertEqual(forward.first?.workloads, reverse.first?.workloads)
        XCTAssertEqual(forward.first?.workloadsSampledAt, reverse.first?.workloadsSampledAt)
        XCTAssertEqual(forward.first?.workloads, [larger])
    }

    func testHistoryStoreAppendsJournalBeforeCompaction() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let store = HistoryStore(
            fileURL: url,
            compactionRecordThreshold: 100,
            compactionByteThreshold: 1_000_000
        )
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 10, swap: 20),
            now: base
        )
        let snapshotBeforeJournal = try Data(contentsOf: url)

        _ = try await store.append(
            snapshot: makeSystemSnapshot(
                timestamp: base.addingTimeInterval(60),
                compressed: 20,
                swap: 30
            ),
            now: base.addingTimeInterval(60)
        )

        XCTAssertEqual(try Data(contentsOf: url), snapshotBeforeJournal)
        let diagnostics = await store.diagnostics()
        XCTAssertGreaterThan(diagnostics.journalBytes, 0)
        XCTAssertEqual(diagnostics.journalRecordCount, 1)

        let reloaded = HistoryStore(
            fileURL: url,
            compactionRecordThreshold: 100,
            compactionByteThreshold: 1_000_000
        )
        let loaded = try await reloaded.load(now: base.addingTimeInterval(60))
        XCTAssertEqual(loaded.map(\.compressedBytes), [10, 20])

        try await store.flush()
        let afterFlush = await store.diagnostics()
        XCTAssertEqual(afterFlush.journalBytes, 0)
        XCTAssertEqual(afterFlush.journalRecordCount, 0)
    }

    func testHistoryStoreRepairsIncompleteJournalTail() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let store = HistoryStore(fileURL: url)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 10, swap: 20),
            now: base
        )

        let next = makeHistoryRecord(
            timestamp: base.addingTimeInterval(60),
            availableFraction: 0.40,
            swapUsedBytes: 30
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var journalData = try encoder.encode(next)
        journalData.append(0x0A)
        journalData.append(contentsOf: Data("{\"timestamp\":".utf8))
        try journalData.write(to: store.journalURL, options: [.atomic])

        let reloaded = HistoryStore(fileURL: url)
        let loaded = try await reloaded.load(now: base.addingTimeInterval(60))
        XCTAssertEqual(loaded.map(\.swapUsedBytes), [20, 30])

        let repaired = try Data(contentsOf: store.journalURL)
        XCTAssertTrue(repaired.last == 0x0A)
    }

    func testHistoryStoreRecoversJournalWithoutSnapshot() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let record = makeHistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.35,
            swapUsedBytes: 42
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var journalData = try encoder.encode(record)
        journalData.append(0x0A)
        let journalURL = URL(fileURLWithPath: url.path + ".journal")
        try journalData.write(to: journalURL, options: [.atomic])

        let store = HistoryStore(fileURL: url)
        let loaded = try await store.load(now: record.timestamp)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].swapUsedBytes, record.swapUsedBytes)
        XCTAssertEqual(loaded[0].availableFraction, record.availableFraction, accuracy: 0.0001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let diagnostics = await store.diagnostics()
        XCTAssertEqual(diagnostics.journalBytes, 0)
    }

    func testHistoryStoreRebuildsCorruptSnapshotFromValidJournal() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url, options: [.atomic])

        let record = makeHistoryRecord(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            availableFraction: 0.35,
            swapUsedBytes: 42
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var journalData = try encoder.encode(record)
        journalData.append(0x0A)
        let journalURL = URL(fileURLWithPath: url.path + ".journal")
        try journalData.write(to: journalURL, options: [.atomic])

        let store = HistoryStore(fileURL: url)
        let loaded = try await store.load(now: record.timestamp)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].swapUsedBytes, record.swapUsedBytes)
        XCTAssertNotEqual(try Data(contentsOf: url), Data("not-json".utf8))
        XCTAssertEqual((try Data(contentsOf: journalURL)).count, 0)
    }

    func testHistoryStoreRetainsPendingRecordAfterJournalAppendFailure() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let store = HistoryStore(fileURL: url)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )

        try FileManager.default.createDirectory(at: store.journalURL, withIntermediateDirectories: true)
        let next = makeSystemSnapshot(
            timestamp: base.addingTimeInterval(60),
            compressed: 2,
            swap: 2
        )
        do {
            _ = try await store.append(snapshot: next, now: next.timestamp)
            XCTFail("Expected journal append to fail")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .writeFailed)
        }

        try FileManager.default.removeItem(at: store.journalURL)
        try await store.flush()
        let reloaded = HistoryStore(fileURL: url)
        let records = try await reloaded.load(now: next.timestamp)
        XCTAssertEqual(records.map(\.compressedBytes), [1, 2])
    }

    func testHistoryStoreDoesNotJournalBackfillOutsideRetentionWindow() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let store = HistoryStore(fileURL: url, retentionInterval: 120)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )

        _ = try await store.append(
            snapshot: makeSystemSnapshot(
                timestamp: base.addingTimeInterval(-600),
                compressed: 99,
                swap: 99
            ),
            now: base
        )

        let diagnostics = await store.diagnostics()
        XCTAssertEqual(diagnostics.pendingRecordCount, 0)
        XCTAssertEqual(diagnostics.journalBytes, 0)
        let records = try await store.currentRecords(now: base)
        XCTAssertEqual(records.map(\.compressedBytes), [1])
    }

    func testHistoryStoreIgnoresExpiredBackfillWithoutDirtyWrite() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(fileURL: url, retentionInterval: 120)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )
        let beforeData = try Data(contentsOf: url)
        let beforeDiagnostics = await store.diagnostics()

        _ = try await store.append(
            snapshot: makeSystemSnapshot(
                timestamp: base.addingTimeInterval(-600),
                compressed: 99,
                swap: 99
            ),
            now: base
        )
        try await store.flush()

        XCTAssertEqual(try Data(contentsOf: url), beforeData)
        let afterDiagnostics = await store.diagnostics()
        XCTAssertEqual(afterDiagnostics.compactionCount, beforeDiagnostics.compactionCount)
        XCTAssertEqual(afterDiagnostics.pendingRecordCount, 0)
    }

    func testHistoryStoreCompactionRemovesExpiredRowsFromDisk() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let store = HistoryStore(fileURL: url, retentionInterval: 120)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )
        _ = try await store.append(
            snapshot: makeSystemSnapshot(
                timestamp: base.addingTimeInterval(60),
                compressed: 2,
                swap: 2
            ),
            now: base.addingTimeInterval(60)
        )
        _ = try await store.append(
            snapshot: makeSystemSnapshot(
                timestamp: base.addingTimeInterval(180),
                compressed: 3,
                swap: 3
            ),
            now: base.addingTimeInterval(180)
        )

        let reloaded = HistoryStore(fileURL: url, retentionInterval: 120)
        let persisted = try await reloaded.load(now: base.addingTimeInterval(180))
        XCTAssertEqual(persisted.map(\.compressedBytes), [2, 3])
    }

    func testHistoryStoreRetriesCompactionAfterWriteFailure() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(fileURL: url, retentionInterval: 120)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            _ = try await store.append(
                snapshot: makeSystemSnapshot(
                    timestamp: base.addingTimeInterval(180),
                    compressed: 3,
                    swap: 3
                ),
                now: base.addingTimeInterval(180)
            )
            XCTFail("Expected compaction to fail")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .writeFailed)
        }

        try? FileManager.default.removeItem(at: url)
        try await store.flush()
        let reloaded = HistoryStore(fileURL: url, retentionInterval: 120)
        let persisted = try await reloaded.load(now: base.addingTimeInterval(180))
        XCTAssertEqual(persisted.map(\.compressedBytes), [3])
    }

    func testHistoryStoreMergesRecoveredRecordsInOneCompaction() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(
            fileURL: url,
            compactionRecordThreshold: 100,
            compactionByteThreshold: 1_000_000
        )
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )
        let before = await store.diagnostics()
        let recovered = [
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(60),
                availableFraction: 0.30,
                swapUsedBytes: 2
            ),
            makeHistoryRecord(
                timestamp: base.addingTimeInterval(120),
                availableFraction: 0.20,
                swapUsedBytes: 3
            )
        ]

        let merged = try await store.merge(records: recovered, now: base.addingTimeInterval(120))
        XCTAssertEqual(merged.map(\.swapUsedBytes), [1, 2, 3])
        let after = await store.diagnostics()
        XCTAssertEqual(after.journalBytes, 0)
        XCTAssertEqual(after.journalRecordCount, 0)
        XCTAssertEqual(after.compactionCount, before.compactionCount + 1)
        XCTAssertEqual(after.lastCompactionAt, base.addingTimeInterval(120))

        let reloaded = HistoryStore(fileURL: url)
        let reloadedRecords = try await reloaded.load(now: base.addingTimeInterval(120))
        XCTAssertEqual(reloadedRecords.map(\.swapUsedBytes), [1, 2, 3])
    }

    func testHistoryStoreMergeRejectsInvalidInputAndFlushTime() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(fileURL: url)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )
        let valid = makeHistoryRecord(
            timestamp: base.addingTimeInterval(60),
            availableFraction: 0.3,
            swapUsedBytes: 2
        )
        for seconds in [Double.nan, Double.infinity, -Double.infinity] {
            let invalidNow = Date(timeIntervalSince1970: seconds)
            do {
                try await store.flush(now: invalidNow)
                XCTFail("Expected invalid flush time to fail")
            } catch let error as HistoryStoreError {
                XCTAssertEqual(error, .invalidData)
            }
            do {
                _ = try await store.merge(records: [valid], now: invalidNow)
                XCTFail("Expected invalid merge time to fail")
            } catch let error as HistoryStoreError {
                XCTAssertEqual(error, .invalidData)
            }
        }

        let invalidRecord = MemoryHistoryRecord(
            timestamp: base.addingTimeInterval(60),
            availableFraction: .nan,
            compressedBytes: 0,
            swapUsedBytes: 0
        )
        do {
            _ = try await store.merge(records: [invalidRecord], now: base)
            XCTFail("Expected invalid history record to fail")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .invalidData)
        }
        let retained = try await store.currentRecords(now: base)
        XCTAssertEqual(retained.map(\.swapUsedBytes), [1])
    }

    func testHistoryStoreRejectsInvalidFreshnessMarkerFromNonThrowingInitializer() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let invalid = MemoryHistoryRecord(
            timestamp: now,
            availableFraction: 0.4,
            compressedBytes: 0,
            swapUsedBytes: 0,
            workloadsSampledAt: nil,
            sourceSampledAt: Date(timeIntervalSince1970: .nan)
        )
        do {
            _ = try await HistoryStore(fileURL: url).append(invalid, now: now)
            XCTFail("Expected invalid freshness marker to fail")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .invalidData)
        }
    }

    func testHistoryRecordPreservesWorkloadSampleFreshnessAcrossSystemOnlyPass() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let group = makeGroup(id: "worker", title: "Worker", footprint: 100)
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(fileURL: url)

        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            groups: [group],
            workloadsSampledAt: base,
            now: base
        )
        let records = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base.addingTimeInterval(20), compressed: 2, swap: 2),
            groups: [],
            now: base.addingTimeInterval(20)
        )
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].workloads.map(\.id), ["worker"])
        XCTAssertEqual(records[0].workloadsSampledAt, base)
    }

    func testHistoryStoreDropsRecordsOlderThanRetentionWindow() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let store = HistoryStore(fileURL: url, retentionInterval: 120)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base.addingTimeInterval(60), compressed: 2, swap: 2),
            now: base.addingTimeInterval(60)
        )
        let records = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base.addingTimeInterval(180), compressed: 3, swap: 3),
            now: base.addingTimeInterval(180)
        )

        XCTAssertEqual(records.map(\.compressedBytes), [2, 3])
    }

    func testHistoryStoreKeepsRecordsAcrossClockRollback() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let store = HistoryStore(fileURL: url, retentionInterval: 1_000)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            now: base
        )
        _ = try await store.append(
            snapshot: makeSystemSnapshot(
                timestamp: base.addingTimeInterval(60),
                compressed: 2,
                swap: 2
            ),
            now: base.addingTimeInterval(60)
        )

        let rolledBack = base.addingTimeInterval(-600)
        let inMemory = try await store.currentRecords(now: rolledBack)
        XCTAssertEqual(inMemory.map(\.compressedBytes), [1, 2])
        let reloaded = HistoryStore(fileURL: url, retentionInterval: 1_000)
        let persisted = try await reloaded.load(now: rolledBack)
        XCTAssertEqual(persisted.map(\.compressedBytes), [1, 2])
    }

    func testHistoryStoreCompactsLowPriorityWorkloadsIntoAttributionAggregate() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = Date(timeIntervalSince1970: 1_699_999_980)
        let groups = [
            makeGroup(id: "one", title: "One", footprint: 100),
            makeGroup(id: "two", title: "Two", footprint: 200),
            makeGroup(id: "three", title: "Three", footprint: 300),
            makeGroup(id: "four", title: "Four", footprint: 400),
            makeGroup(id: "five", title: "Five", footprint: 500)
        ]
        let store = HistoryStore(fileURL: url, maxPersistedWorkloads: 2)
        let records = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: base, compressed: 1, swap: 1),
            groups: groups,
            now: base
        )

        XCTAssertEqual(records[0].workloads.count, 3)
        XCTAssertEqual(Set(records[0].workloads.map(\.id)), Set(["five", "four", "other-processes"]))
        let aggregate = try XCTUnwrap(records[0].workloads.first { $0.id == "other-processes" })
        XCTAssertEqual(aggregate.processCount, 3)
        XCTAssertEqual(aggregate.attributedFootprintBytes, 600)
    }

    func testHistoryStoreCompactsMoreThanFortyWorkloadsIntoAggregate() {
        let workloads = (0..<45).map { index in
            PersistedWorkloadRecord(
                id: "workload-\(index)",
                title: "Workload \(index)",
                processCount: 1,
                attributedFootprintBytes: UInt64(index + 1),
                attributedResidentBytes: UInt64(index + 1),
                isSystem: false
            )
        }

        let compacted = HistoryStore.compactedWorkloads(workloads, limit: 40)
        let aggregate = compacted.first { $0.id == "other-processes" }

        XCTAssertEqual(compacted.count, 41)
        XCTAssertEqual(aggregate?.processCount, 5)
        XCTAssertEqual(aggregate?.attributedFootprintBytes, 1 + 2 + 3 + 4 + 5)
    }

    func testHistoryStorePersistsOnlySanitizedRuntimeIdentity() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let processes = [
            makeProcess(
                pid: 70,
                name: "node",
                footprint: 100,
                workingDirectoryLabel: "api"
            )
        ]
        let groups = WorkloadGrouper().group(processes)
        let store = HistoryStore(fileURL: url)
        _ = try await store.append(
            snapshot: makeSystemSnapshot(timestamp: Date(timeIntervalSince1970: 1_700_000_000), compressed: 1, swap: 1),
            groups: groups,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(persisted.contains("runtime-node-api"))
        XCTAssertFalse(persisted.contains("/Users/"))
        XCTAssertFalse(persisted.contains("commandLine"))
    }

    func testHistoryStoreRejectsCorruptFile() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: url, options: [.atomic])

        let store = HistoryStore(fileURL: url)
        do {
            _ = try await store.load(now: Date(timeIntervalSince1970: 1_700_000_000))
            XCTFail("Expected corrupt history file to be rejected")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .invalidData)
        }
    }

    func testHistoryStoreRejectsUnsupportedVersion() async throws {
        let (url, directory) = makeTemporaryHistoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(MemoryHistoryFile(version: 99, records: []))
        try data.write(to: url, options: [.atomic])

        let store = HistoryStore(fileURL: url)
        do {
            _ = try await store.load(now: Date(timeIntervalSince1970: 1_700_000_000))
            XCTFail("Expected unsupported history version to be rejected")
        } catch let error as HistoryStoreError {
            XCTAssertEqual(error, .unsupportedVersion(99))
        }
    }

    func testWorkloadGrouperRetainsLiveMemberIdentities() {
        let first = makeProcess(pid: 801, name: "node", footprint: 100, workingDirectoryLabel: "api")
        let second = makeProcess(pid: 802, name: "node", footprint: 200, workingDirectoryLabel: "api")

        let group = try! XCTUnwrap(
            WorkloadGrouper().group([first, second]).first { $0.id == "runtime-node-api" }
        )

        XCTAssertEqual(Set(group.memberProcessIdentities), Set([first.identity, second.identity]))
        XCTAssertEqual(group.processCount, group.memberProcessIdentities.count)
    }

    func testWorkloadGrouperUsesStableHighestConfidenceReasonWithinBucket() {
        let parent = makeProcess(
            pid: 901,
            name: "node",
            parentPID: 0,
            footprint: 100,
            workingDirectoryLabel: "api"
        )
        let child = makeProcess(
            pid: 902,
            name: "node",
            parentPID: parent.identity.pid,
            footprint: 200
        )

        let grouper = WorkloadGrouper()
        let forward = grouper.group([parent, child])
        let reverse = grouper.group([child, parent])
        let forwardGroup = try! XCTUnwrap(forward.first { $0.id == "runtime-node-api" })
        let reverseGroup = try! XCTUnwrap(reverse.first { $0.id == "runtime-node-api" })

        XCTAssertEqual(forwardGroup.attributionReason, .runtimeWorkingDirectory)
        XCTAssertEqual(reverseGroup.attributionReason, .runtimeWorkingDirectory)
        XCTAssertEqual(forwardGroup, reverseGroup)
    }

    private func makeGroup(
        id: String,
        title: String,
        footprint: UInt64,
        containsEstimatedFootprint: Bool = false,
        isSystem: Bool = false,
        memberProcessIdentities: [ProcessIdentity] = []
    ) -> WorkloadGroupSnapshot {
        WorkloadGroupSnapshot(
            id: id,
            title: title,
            processCount: 1,
            physicalFootprintBytes: footprint,
            residentBytes: footprint,
            containsEstimatedFootprint: containsEstimatedFootprint,
            isSystem: isSystem,
            representativeProcess: title,
            memberProcessIdentities: memberProcessIdentities
        )
    }

    private func makeHistoryRecord(
        timestamp: Date,
        availableFraction: Double,
        swapUsedBytes: UInt64,
        workloads: [PersistedWorkloadRecord] = []
    ) -> MemoryHistoryRecord {
        MemoryHistoryRecord(
            timestamp: timestamp,
            availableFraction: availableFraction,
            compressedBytes: 0,
            swapUsedBytes: swapUsedBytes,
            workloads: workloads
        )
    }

    private func makePersistedWorkload(
        id: String,
        title: String,
        footprint: UInt64,
        isSystem: Bool = false
    ) -> PersistedWorkloadRecord {
        PersistedWorkloadRecord(
            id: id,
            title: title,
            processCount: 1,
            attributedFootprintBytes: footprint,
            attributedResidentBytes: footprint,
            isSystem: isSystem
        )
    }

    private func makeMonitorSnapshot(
        timestamp: Date,
        system: SystemMemorySnapshot?,
        groups: [WorkloadGroupSnapshot],
        processes: [ProcessSnapshot] = [],
        processStatus: SampleStatus? = nil,
        didSampleProcesses: Bool = true,
        listedCount: Int? = nil
    ) -> MonitorSnapshot {
        let systemStatus = system.map {
            SampleStatus.estimated(at: $0.timestamp, message: "内存使用率按可回收内存估算")
        } ?? .unavailable(message: "系统数据不可用")
        let resolvedProcessStatus = processStatus
            ?? (didSampleProcesses
                ? .available(at: timestamp)
                : .unavailable(message: "本轮未执行进程扫描"))
        let normalizedListedCount = max(listedCount ?? processes.count, processes.count)
        let diagnostics = SamplingDiagnostics(
            mode: didSampleProcesses ? .panel : .background,
            totalDurationMilliseconds: 1,
            processDurationMilliseconds: didSampleProcesses ? 1 : nil,
            processSamplingPerformed: didSampleProcesses,
            processCount: processes.count,
            listedProcessCount: normalizedListedCount
        )
        return MonitorSnapshot(
            timestamp: timestamp,
            system: system,
            systemStatus: systemStatus,
            cpuTime: nil,
            cpuStatus: .unavailable(message: "测试未提供 CPU 数据"),
            gpuUsageFraction: nil,
            gpuStatus: .unavailable(message: "测试未提供 GPU 数据"),
            processes: processes,
            processStatus: resolvedProcessStatus,
            listedProcessCount: normalizedListedCount,
            sampledProcessCount: processes.count,
            groups: groups,
            samplingMode: diagnostics.mode,
            diagnostics: diagnostics
        )
    }

    private func makeSystemSnapshot(timestamp: Date, compressed: UInt64, swap: UInt64) -> SystemMemorySnapshot {
        SystemMemorySnapshot(
            timestamp: timestamp,
            totalBytes: 1_000,
            pageSize: 1,
            freeBytes: 100,
            activeBytes: 500,
            inactiveBytes: 0,
            speculativeBytes: 0,
            wiredBytes: 400,
            purgeableBytes: 0,
            compressedBytes: compressed,
            throttledPages: 0,
            swapTotalBytes: 100,
            swapUsedBytes: swap,
            swapFreeBytes: 100 - swap
        )
    }

    private func makePressureSnapshot(
        timestamp: Date,
        availableFraction: Double,
        compressedBytes: UInt64 = 0,
        throttledPages: UInt64 = 0,
        swapTotalBytes: UInt64 = 0,
        swapFreeBytes: UInt64 = 0
    ) -> SystemMemorySnapshot {
        let totalBytes: UInt64 = 16 * 1024 * 1024 * 1024
        let freeBytes = UInt64(Double(totalBytes) * availableFraction)
        return SystemMemorySnapshot(
            timestamp: timestamp,
            totalBytes: totalBytes,
            pageSize: 4096,
            freeBytes: freeBytes,
            activeBytes: totalBytes - freeBytes,
            inactiveBytes: 0,
            speculativeBytes: 0,
            wiredBytes: 0,
            purgeableBytes: 0,
            compressedBytes: compressedBytes,
            throttledPages: throttledPages,
            swapTotalBytes: swapTotalBytes,
            swapUsedBytes: swapTotalBytes >= swapFreeBytes
                ? swapTotalBytes - swapFreeBytes
                : 0,
            swapFreeBytes: swapFreeBytes
        )
    }

    private func makeProcess(
        pid: Int32,
        name: String,
        parentPID: Int32 = 1,
        footprint: UInt64,
        isSystem: Bool = false,
        workingDirectoryLabel: String? = nil,
        userID: UInt32 = 501,
        startTimeSeconds: UInt64 = 1,
        startTimeMicroseconds: UInt64? = nil,
        executablePath: String? = nil,
        omitExecutablePath: Bool = false,
        physicalFootprintIsEstimated: Bool = false
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            identity: ProcessIdentity(
                pid: pid,
                startTimeSeconds: startTimeSeconds,
                startTimeMicroseconds: startTimeMicroseconds ?? UInt64(max(pid, 0))
            ),
            parentPID: parentPID,
            userID: userID,
            isSystem: isSystem,
            name: name,
            executablePath: omitExecutablePath ? nil : (executablePath ?? "/usr/bin/\(name)"),
            residentBytes: footprint,
            physicalFootprintBytes: footprint,
            physicalFootprintIsEstimated: physicalFootprintIsEstimated,
            workingDirectoryLabel: workingDirectoryLabel,
            virtualBytes: footprint,
            userTimeNanos: 0,
            systemTimeNanos: 0,
            threadCount: 1
        )
    }

    private func makeAuditEvent(id: String, timestamp: Date) -> ProcessActionAuditEvent {
        ProcessActionAuditEvent(
            id: id,
            timestamp: timestamp,
            action: .gracefulExit,
            outcome: .completed,
            processLabel: "worker",
            detail: "请求已完成"
        )
    }

    private func makeTemporaryHistoryURL() -> (file: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMonitorTests-" + UUID().uuidString, isDirectory: true)
        return (directory.appendingPathComponent("history.json"), directory)
    }

    private func makeTemporaryActionURL() -> (file: URL, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryMonitorActionTests-" + UUID().uuidString, isDirectory: true)
        return (directory.appendingPathComponent("actions.jsonl"), directory)
    }
}
