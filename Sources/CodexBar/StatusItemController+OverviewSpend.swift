import CodexBarCore
import Foundation

extension StatusItemController {
    func overviewSpendDashboardModel(
        providers: [UsageProvider],
        now: Date = Date()) -> SpendDashboardModel
    {
        let inputs = providers.compactMap { provider -> SpendDashboardModel.ProviderInput? in
            guard let snapshot = self.store.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot else {
                return nil
            }
            return SpendDashboardModel.ProviderInput(
                provider: provider,
                displayName: ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue,
                snapshot: snapshot)
        }
        let requestedDays = self.settings.effectiveCostUsageHistoryDays
        return SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: requestedDays,
            now: now,
            preferredCurrencyCode: self.settings.preferredCurrencyCode)
    }
}
