import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Returns the enabled candidate closest to depletion, using the same forecast as Auto.
    /// Excludes providers that are fully rate-limited.
    func providerWithHighestUsage(
        candidateProviders: [UsageProvider]? = nil,
        usageSource: (@MainActor (UsageProvider) -> MenuBarUsageSource)? = nil,
        now: Date = Date())
        -> (provider: UsageProvider, usedPercent: Double)?
    {
        let candidateSet = candidateProviders.map(Set.init)
        var highest: (provider: UsageProvider, selection: AutomaticQuotaSelection.Selection)?
        for provider in self.enabledFirstPartyProvidersForDisplay() {
            guard candidateSet?.contains(provider) ?? true else { continue }
            let source = usageSource?(provider) ?? .local(self.menuBarSnapshot(for: provider.instanceID))
            guard self.isEnabled(provider) || source.isFleet,
                  let snapshot = source.snapshot else { continue }
            let automatic = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .automatic
            // Provider-specific by design: Codex projection retains source pace slots after lane reclassification.
            let selection: AutomaticQuotaSelection.Selection? = if provider == .codex, automatic, !source.isFleet {
                self.codexConsumerProjection(
                    surface: .menuBar,
                    snapshotOverride: snapshot,
                    now: now).automaticMenuBarSelection()
            } else if let window = self.menuBarMetricWindowForHighestUsage(
                provider: provider,
                snapshot: snapshot,
                includeLocalDerivedData: !source.isFleet,
                now: now)
            {
                AutomaticQuotaSelection.selection(
                    candidate: .init(
                        window: window,
                        paceSlot: automatic ? AutomaticQuotaSelection.paceSlot(for: window, in: snapshot) : nil),
                    provider: provider,
                    now: now,
                    dataConfidence: snapshot.dataConfidence)
            } else {
                nil
            }
            guard let selection else { continue }
            let window = selection.window
            let percent = window.usedPercent
            guard !self.shouldExcludeFromHighestUsage(
                provider: provider,
                snapshot: snapshot,
                metricPercent: percent,
                includeLocalDerivedData: !source.isFleet,
                now: now)
            else {
                continue
            }
            let priority = automatic
                ? selection
                : AutomaticQuotaSelection.Selection(candidate: selection.candidate, eta: nil)
            if highest.map({ AutomaticQuotaSelection.precedes($0.selection, priority) }) ?? true {
                highest = (provider, priority)
            }
        }
        return highest.map { ($0.provider, $0.selection.window.usedPercent) }
    }

    private func menuBarMetricWindowForHighestUsage(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        includeLocalDerivedData: Bool,
        now: Date) -> RateWindow?
    {
        let effectivePreference = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
        // Provider-specific by design: these paths depend on live Codex projection and Antigravity user policy.
        if provider == .antigravity,
           effectivePreference == .automatic,
           !self.settings.antigravityPrioritizeExhaustedQuotas
        {
            return Self.mostConstrainedAntigravityQuotaSummaryWindow(snapshot: snapshot)
        }
        if includeLocalDerivedData, provider == .codex {
            return self.codexMenuBarMetricWindow(snapshot: snapshot, now: now)
        }
        return MenuBarMetricWindowResolver.rateWindow(
            preference: effectivePreference,
            provider: provider,
            snapshot: snapshot,
            supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider),
            antigravityPrioritizeExhaustedQuotas: self.settings.antigravityPrioritizeExhaustedQuotas,
            now: now)
    }

    private func shouldExcludeFromHighestUsage(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        metricPercent: Double,
        includeLocalDerivedData: Bool,
        now: Date)
        -> Bool
    {
        let effectivePreference = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
        guard metricPercent >= 100 else { return false }
        // Provider-specific by design: exclusion mirrors each provider's multi-lane resolver and optional quotas.
        if provider == .codex || provider == .claude, effectivePreference == .primaryAndSecondary {
            if provider == .codex,
               self.codexConsumerProjection(
                   surface: includeLocalDerivedData ? .menuBar : .overrideCard,
                   snapshotOverride: snapshot,
                   now: now).hasBindingWeeklyCap
            {
                return true
            }
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
            if self.settings.antigravityPrioritizeExhaustedQuotas {
                return MenuBarMetricWindowResolver.antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: snapshot)
            }
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
        if effectivePreference == .automatic,
           MenuBarMetricWindowResolver.automaticSelectionPrioritizesExhaustedWindow(for: provider)
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
