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
        switch self.settings.menuBarMetricPreference(for: provider) {
        case .primary:
            return snapshot.primary ?? snapshot.secondary
        case .secondary:
            return snapshot.secondary ?? snapshot.primary
        case .average:
            guard let primary = snapshot.primary, let secondary = snapshot.secondary else {
                return snapshot.primary ?? snapshot.secondary
            }
            let usedPercent = (primary.usedPercent + secondary.usedPercent) / 2
            return RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        case .automatic:
            if provider == .factory || provider == .kimi {
                return snapshot.secondary ?? snapshot.primary
            }
            if provider == .copilot,
               let primary = snapshot.primary,
               let secondary = snapshot.secondary
            {
                // Copilot can expose chat + completions quotas; rank by the more constrained one.
                return primary.usedPercent >= secondary.usedPercent ? primary : secondary
            }
            return snapshot.primary ?? snapshot.secondary
        }
    }

    private func shouldExcludeFromHighestUsage(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        metricPercent: Double)
        -> Bool
    {
        guard metricPercent >= 100 else { return false }
        if provider == .copilot,
           self.settings.menuBarMetricPreference(for: provider) == .automatic,
           let primary = snapshot.primary,
           let secondary = snapshot.secondary
        {
            // In automatic mode Copilot can have one depleted lane while another still has quota.
            return primary.usedPercent >= 100 && secondary.usedPercent >= 100
        }
        return true
    }
}
