import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Starts the one-shot background plan-utilization history load. The decode
    /// runs on a utility-priority detached task so a mature two-year history
    /// does not block the startup main thread. The in-memory dictionary starts
    /// empty; mutation paths and sync menu accessors gate on
    /// `planUtilizationHistoryLoaded` until the load publishes exactly once.
    /// The `gate` parameter is test-only and defaults to nil in production.
    func startPlanUtilizationHistoryLoad(gate: PlanUtilizationHistoryLoadGate? = nil) {
        self.planUtilizationHistoryLoadTask = Task { @MainActor [weak self] in
            let loaded = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) {
                    await gate?.wait()
                    return self?.planUtilizationHistoryStore?.load() ?? [:]
                }.value
            } onCancel: { gate?.cancelAll() }
            guard let self, !self.planUtilizationHistoryLoaded else { return }
            self.planUtilizationHistory = loaded
            self.planUtilizationHistoryRevision &+= 1
        }
    }
}
