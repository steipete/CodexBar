import CodexBarCore
import Foundation

extension UsageStore {
    /// Weekly reset timestamps already stored for quota-window cost. Read-only: menu rendering
    /// must not run `planUtilizationHistorySelection`, which can migrate account buckets and
    /// bump `planUtilizationHistoryRevision` as a side effect.
    func weeklyQuotaWindowResetDates(
        for provider: UsageProvider,
        snapshot: UsageSnapshot? = nil,
        historySelection: PlanUtilizationHistorySelection? = nil) -> [Date]
    {
        if let historySelection {
            return Self.weeklyResetDates(from: historySelection.histories)
        }
        let buckets = self.planUtilizationHistory[provider.instanceID] ?? PlanUtilizationHistoryBuckets()
        let accountKey = snapshot.flatMap {
            Self.planUtilizationIdentityAccountKey(provider: provider, snapshot: $0)
        } ?? buckets.preferredAccountKey
        let scoped = buckets.histories(for: accountKey)
        let histories = scoped.isEmpty ? buckets.histories(for: nil) : scoped
        return Self.weeklyResetDates(from: histories)
    }

    private static func weeklyResetDates(from histories: [PlanUtilizationSeriesHistory]) -> [Date] {
        histories.first { $0.name == .weekly }?.entries.compactMap(\.resetsAt) ?? []
    }
}
