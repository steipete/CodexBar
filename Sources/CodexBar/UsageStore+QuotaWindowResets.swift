import CodexBarCore
import Foundation

extension UsageStore {
    /// Read stored weekly resets using the same live ownership rules as plan history.
    /// Menu rendering must not migrate account buckets or bump the history revision.
    func weeklyQuotaWindowResetObservations(
        for provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        historySelection: PlanUtilizationHistorySelection? = nil,
        usesLiveAccount: Bool = true) -> [CostUsageQuotaResetObservation]
    {
        if let historySelection {
            return Self.weeklyResetObservations(from: historySelection.histories)
        }
        if usesLiveAccount {
            return Self.weeklyResetObservations(from: self.planUtilizationHistorySelection(
                for: provider, readOnly: true).histories)
        }
        let buckets = self.planUtilizationHistory[provider.instanceID] ?? PlanUtilizationHistoryBuckets()
        // Explicit account cards cannot borrow the live account's history when identity is missing.
        guard let accountKey = snapshot.flatMap({
            Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: $0)
        }) else { return [] }
        return Self.weeklyQuotaResetObservations(in: buckets, accountKey: accountKey)
    }

    static func weeklyQuotaResetObservations(
        in buckets: PlanUtilizationHistoryBuckets,
        accountKey: String?) -> [CostUsageQuotaResetObservation]
    {
        self.weeklyResetObservations(from: buckets.histories(for: accountKey))
    }

    static func weeklyResetObservations(from histories: [PlanUtilizationSeriesHistory])
    -> [CostUsageQuotaResetObservation] {
        histories.first { $0.name == .weekly }?.entries.compactMap { entry in
            entry.resetsAt.map { CostUsageQuotaResetObservation(capturedAt: entry.capturedAt, resetsAt: $0) }
        } ?? []
    }
}
