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
            await MainActor.run {
                guard !Task.isCancelled,
                      let owner,
                      !owner.planUtilizationHistoryLoaded
                else { return }
                owner.planUtilizationHistory = loaded
                owner.planUtilizationHistoryLoaded = true
                owner.planUtilizationHistoryRevision &+= 1
            }
        }
    }
}
