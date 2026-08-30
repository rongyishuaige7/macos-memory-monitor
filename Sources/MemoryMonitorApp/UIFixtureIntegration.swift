import Foundation
import MemoryMonitorCore

/// A deliberately read-only sampler used only by the isolated desktop check.
/// The dataset owns stable identities, while each pass receives fresh source
/// timestamps so the normal detail freshness contract remains exercised.
@MainActor
struct MemoryMonitorUIFixtureSamplingSource: MonitorSamplingSource {
    let dataset: MemoryMonitorUIFixture.Dataset

    func sample(mode: SamplingMode, at timestamp: Date) async -> MonitorSnapshot {
        // The fixture is intended to make detail rows deterministic even when
        // the panel opens during a background cadence. Keep all process rows
        // present and report a full pass regardless of the requested mode.
        _ = mode
        return dataset.snapshot(at: timestamp)
    }
}
