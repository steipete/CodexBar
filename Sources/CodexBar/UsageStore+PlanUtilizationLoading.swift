import CodexBarCore
import Foundation

extension UsageStore {
    static func resolvedPlanHistoryStore(
        _ store: PlanUtilizationHistoryStore?,
        startup: StartupBehavior) -> PlanUtilizationHistoryStore
    {
        store ?? (startup.automaticallyStartsBackgroundWork
            ? .defaultAppSupport()
            : PlanUtilizationHistoryStore(directoryURL: nil))
    }

    /// Returns the utility worker itself so cancellation owns the gate, decode,
    /// and publication path instead of only cancelling an outer awaiting task.
    static func makePlanUtilizationHistoryLoadTask(
        owner: UsageStore,
        store: PlanUtilizationHistoryStore,
        gate: PlanUtilizationHistoryLoadGate?) -> Task<Void, Never>
    {
        Task.detached(priority: .utility) { [weak owner] in
            if let gate {
                guard await gate.wait() else { return }
            }
            guard !Task.isCancelled else { return }
            let loaded = store.load()
            guard !Task.isCancelled else { return }
            await owner?.publishLoadedPlanUtilizationHistory(loaded)
        }
    }

    private func publishLoadedPlanUtilizationHistory(
        _ loaded: [UsageProvider: PlanUtilizationHistoryBuckets])
    {
        guard !Task.isCancelled, !self.planUtilizationHistoryLoaded else { return }
        self.planUtilizationHistory = loaded
        self.planUtilizationHistoryLoaded = true
        self.planUtilizationHistoryRevision &+= 1
    }
}
