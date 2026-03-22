import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Returns the enabled provider with the highest usage percentage (closest to rate limit).
    /// Excludes providers that are fully rate-limited.
    func providerWithHighestUsage() -> (provider: UsageProvider, usedPercent: Double)? {
        var highest: (provider: UsageProvider, usedPercent: Double)?
        for provider in self.enabledProviders() {
            guard let snapshot = self.snapshots[provider] else { continue }
            let window = self.menuBarMetricWindowForHighestUsage(provider: provider, snapshot: snapshot)
            let percent = window?.usedPercent ?? 0
            guard !self.shouldExcludeFromHighestUsage(
                provider: provider,
                snapshot: snapshot,
                metricPercent: percent)
            else {
                continue
            }
            if highest == nil || percent > highest!.usedPercent {
                highest = (provider, percent)
            }
        }
        return highest
    }

    private func menuBarMetricWindowForHighestUsage(provider: UsageProvider, snapshot: UsageSnapshot) -> RateWindow? {
        MenuBarMetricWindowResolver.rateWindow(
            preference: self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot),
            provider: provider,
            snapshot: snapshot,
            supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider))
    }

    private func shouldExcludeFromHighestUsage(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        metricPercent: Double)
        -> Bool
    {
        let effectivePreference = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
        guard metricPercent >= 100 else { return false }
        if provider == .copilot,
           effectivePreference == .automatic,
           let primary = snapshot.primary,
           let secondary = snapshot.secondary
        {
            // In automatic mode Copilot can have one depleted lane while another still has quota.
            return primary.usedPercent >= 100 && secondary.usedPercent >= 100
        }
        if provider == .cursor,
           effectivePreference == .automatic
        {
            let percents = [
                snapshot.primary?.usedPercent,
                snapshot.secondary?.usedPercent,
                snapshot.tertiary?.usedPercent,
            ].compactMap(\.self)
            guard !percents.isEmpty else { return true }
            return percents.allSatisfy { $0 >= 100 }
        }
        return true
    }
}
