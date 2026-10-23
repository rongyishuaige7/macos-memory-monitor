import Combine
import Foundation
import MemoryMonitorCore

@MainActor
final class LocalDataDiagnosticsController: ObservableObject {
    let root: URL
    @Published private(set) var report: HistoryInspectionReport?
    @Published private(set) var error: String?
    @Published private(set) var isInspecting = false

    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    var hasPendingRecovery: Bool {
        MaintenanceTransaction.exists(root: root)
    }

    init(root: URL = MemoryMonitorStoragePaths.currentRootURL) {
        self.root = root
    }

    func inspect() {
        guard task == nil else { return }
        generation &+= 1
        let requestGeneration = generation
        isInspecting = true
        error = nil
        let root = self.root
        task = Task { [weak self] in
            let report = await Task.detached(priority: .utility) {
                HistoryInspector.inspect(root: root)
            }.value
            guard let self else { return }
            guard requestGeneration == self.generation else { return }
            self.report = report
            self.isInspecting = false
            self.task = nil
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isInspecting = false
    }

    func makeSummary(
        generatedAt: Date = Date(),
        productVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        productBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    ) -> SupportSummary? {
        guard let report else { return nil }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return SupportSummary(
            generatedAt: generatedAt,
            productVersion: productVersion,
            productBuild: productBuild,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            report: report
        )
    }
}
