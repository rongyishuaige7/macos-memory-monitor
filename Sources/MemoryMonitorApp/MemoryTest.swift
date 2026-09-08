import Combine
import Darwin
import Foundation
import MemoryMonitorCore

enum MemoryTestIntensity: Int, CaseIterable, Identifiable {
    case light = 128, medium = 256, heavy = 512
    var id: Self { self }
    var title: String {
        switch self {
        case .light: "轻度"
        case .medium: "中度"
        case .heavy: "重度"
        }
    }
    var bytes: Int { rawValue * 1024 * 1024 }
}

enum MemoryTestPolicy {
    static func refusal(system: SystemMemorySnapshot?, usable: Bool, pressure: MemoryPressureLevel?, requested: Int) -> String? {
        guard usable, let system, pressure == .normal else { return "当前内存紧张或状态未知，暂不能开始测试。" }
        guard requested > 0, requested <= MemoryTestIntensity.heavy.bytes,
              UInt64(requested) <= system.availableEstimateBytes / 4,
              system.availableEstimateBytes >= 1024 * 1024 * 1024 else {
            return "可用内存不足，请先退出部分应用。"
        }
        return nil
    }
}

struct MemoryTestResult: Sendable, Equatable {
    let completed: Bool
    let message: String
}

enum MemoryTestWorker {
    static func run(
        bytes: Int, seconds: Int = 30,
        check: @Sendable () -> Bool,
        progress: @Sendable (Int, Int) async -> Void
    ) async -> MemoryTestResult {
        guard bytes > 0, bytes <= MemoryTestIntensity.heavy.bytes, seconds > 0, seconds <= 30 else {
            return .init(completed: false, message: "测试参数无效")
        }
        var blocks: [UnsafeMutableRawPointer] = []
        defer { blocks.forEach { free($0) } }
        var allocated = 0
        while allocated < bytes {
            guard !Task.isCancelled else { return .init(completed: false, message: "已停止，测试内存已释放") }
            guard check() else { return .init(completed: false, message: "内存压力上升，已停止并释放测试内存") }
            let count = min(8 * 1024 * 1024, bytes - allocated)
            guard let pointer = malloc(count) else { return .init(completed: false, message: "无法分配内存，测试已停止") }
            // Random bytes ensure the test is backed by touched, nontrivially compressible pages.
            arc4random_buf(pointer, count)
            blocks.append(pointer)
            allocated += count
            await progress(allocated, 0)
        }
        for elapsed in 1...seconds {
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return .init(completed: false, message: "已停止，测试内存已释放") }
            guard check() else { return .init(completed: false, message: "内存压力上升，已停止并释放测试内存") }
            await progress(allocated, elapsed)
        }
        return .init(completed: true, message: "测试完成，测试内存已全部释放")
    }
}

@MainActor
final class MemoryTestController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var allocatedBytes = 0
    @Published private(set) var elapsed = 0
    @Published private(set) var message: String?
    private var task: Task<MemoryTestResult, Never>?
    private let operationGate: MonitorOperationGate
    private let manualActionIsBusy: @MainActor () -> Bool

    init(operationGate: MonitorOperationGate = MonitorOperationGate(),
         manualActionIsBusy: @escaping @MainActor () -> Bool = { false }) {
        self.operationGate = operationGate
        self.manualActionIsBusy = manualActionIsBusy
    }

    func start(system: SystemMemorySnapshot?, usable: Bool, pressure: MemoryPressureLevel?, intensity: MemoryTestIntensity) {
        guard !isRunning else { return }
        guard !manualActionIsBusy(), operationGate.owner == nil else {
            message = "请等待清理或进程操作结束。"
            return
        }
        if let refusal = MemoryTestPolicy.refusal(system: system, usable: usable, pressure: pressure, requested: intensity.bytes) {
            message = refusal
            return
        }
        guard operationGate.acquire(.memoryTest) else { return }
        isRunning = true
        allocatedBytes = 0
        elapsed = 0
        message = nil
        let task = Task.detached(priority: .utility) { [weak self] in
            await MemoryTestWorker.run(bytes: intensity.bytes, check: {
                guard let system = try? SystemMemorySampler().sample() else { return false }
                return system.availableFraction > 0.15 && system.availableEstimateBytes >= 512 * 1024 * 1024
            }, progress: { [weak self] bytes, elapsed in
                await self?.update(bytes: bytes, elapsed: elapsed)
            })
        }
        self.task = task
        let operationGate = operationGate
        Task { [weak self] in
            let result = await task.value
            operationGate.release(.memoryTest)
            guard let self else { return }
            self.message = result.message
            self.allocatedBytes = 0
            self.isRunning = false
            self.task = nil
        }
    }

    private func update(bytes: Int, elapsed: Int) {
        allocatedBytes = bytes
        self.elapsed = elapsed
    }

    func stop() { task?.cancel() }
    deinit { task?.cancel() }
}
