import AppKit
import CodexBarCore
import Foundation

extension StatusItemController {
    func addOverviewEmptyState(to menu: NSMenu, enabledProviders: [UsageProvider]) {
        let resolvedProviders = self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit)
        let message = resolvedProviders.isEmpty
            ? L("No providers selected for Overview.")
            : L("No overview data available.")
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.representedObject = "overviewEmptyState"
        menu.addItem(item)
    }

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
