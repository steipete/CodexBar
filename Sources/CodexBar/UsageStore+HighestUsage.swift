import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Returns the enabled candidate provider with the highest usage percentage (closest to rate limit).
    /// Excludes providers that are fully rate-limited.
    func providerWithHighestUsage(candidateProviders: [UsageProvider]? = nil)
        -> (provider: UsageProvider, usedPercent: Double)?
    {
        let candidateSet = candidateProviders.map(Set.init)
        var highest: (provider: UsageProvider, usedPercent: Double)?
        for provider in self.enabledProviders()
            where candidateSet?.contains(provider) ?? true
        {
            guard let snapshot = self.snapshots[provider] else { continue }
            guard let window = self.menuBarMetricWindowForHighestUsage(provider: provider, snapshot: snapshot) else {
                continue
            }
            let percent = window.usedPercent
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
        let effectivePreference = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
        if provider == .antigravity, effectivePreference == .automatic {
            return Self.mostConstrainedAntigravityQuotaSummaryWindow(snapshot: snapshot)
        }
        return MenuBarMetricWindowResolver.rateWindow(
            preference: effectivePreference,
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
        if provider == .codex || provider == .claude, effectivePreference == .primaryAndSecondary {
            // A Claude spend-limit-only snapshot has no real session/weekly lanes; the metric resolves to
            // the spend-limit window, so reaching here (metricPercent >= 100) means the spend limit itself
            // is exhausted. Mirror that resolver fallback and exclude, instead of inspecting the raw 0%
            // placeholder primary that would otherwise keep it eligible.
            if provider == .claude, MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot) != nil {
                return true
            }
            // Ignore synthesized placeholder lanes (e.g. Claude web's null `five_hour` 0% session) so a
            // fully exhausted weekly-only account is excluded rather than kept eligible by a phantom 0%.
            let percents = [snapshot.primary, snapshot.secondary]
                .compactMap(\.self)
                .filter { !$0.isSyntheticPlaceholder }
                .map(\.usedPercent)
            guard !percents.isEmpty else { return true }
            return percents.allSatisfy { $0 >= 100 }
        }
        if provider == .antigravity, effectivePreference == .automatic {
            let windows = Self.antigravityRenderedQuotaSummaryWindows(snapshot: snapshot)
            guard !windows.isEmpty else { return true }
            return windows.allSatisfy { $0.usedPercent >= 100 }
        }
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

    private nonisolated static func mostConstrainedAntigravityQuotaSummaryWindow(
        snapshot: UsageSnapshot)
        -> RateWindow?
    {
        let windows = self.antigravityRenderedQuotaSummaryWindows(snapshot: snapshot)
        guard !windows.isEmpty else { return nil }

        let usableWindows = windows.filter { $0.usedPercent < 100 }
        if let maxUsable = usableWindows.max(by: { $0.usedPercent < $1.usedPercent }) {
            return maxUsable
        }
        return windows.max(by: { $0.usedPercent < $1.usedPercent })
    }

    private nonisolated static func antigravityRenderedQuotaSummaryWindows(
        snapshot: UsageSnapshot)
        -> [RateWindow]
    {
        let windows = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .antigravity)
        return [windows.primary, windows.secondary].compactMap(\.self)
    }
}
