import CodexBarCore
import Foundation

extension StatusItemController {
    nonisolated static func pluginMeterPercents(snapshot: UsageSnapshot?, showUsed: Bool)
        -> (primary: Double?, secondary: Double?)
    {
        guard let snapshot, snapshot.primary != nil || snapshot.secondary != nil else {
            return (self.pluginSwitcherMetricPercent(snapshot: snapshot, showUsed: showUsed), nil)
        }
        let lanes = IconRemainingResolver.resolvedPercents(snapshot: snapshot, style: .combined, showUsed: showUsed)
        return (
            lanes.primary.map { min(100, max(0, $0)) },
            lanes.secondary.map { min(100, max(0, $0)) })
    }

    nonisolated static func pluginSwitcherMetricPercent(snapshot: UsageSnapshot?, showUsed: Bool) -> Double? {
        guard let window = self.pluginSwitcherMetricWindow(snapshot: snapshot) else { return nil }
        let used = min(100, max(0, window.usedPercent))
        return showUsed ? used : 100 - used
    }

    /// The most-used reported seven-day window, otherwise the first available window.
    nonisolated static func pluginSwitcherMetricWindow(snapshot: UsageSnapshot?) -> RateWindow? {
        let windows = ([snapshot?.primary, snapshot?.secondary, snapshot?.tertiary].compactMap(\.self) +
            (snapshot?.extraRateWindows ?? []).filter(\.usageKnown).map(\.window))
            .filter(\.usedPercent.isFinite)
        let weekly = windows.filter { $0.windowMinutes == 7 * 24 * 60 }
            .max { $0.usedPercent < $1.usedPercent }
        return weekly ?? windows.first
    }

    /// The stored layout's first automatic reset token. Plugins do not render the full layout, so the merged
    /// icon appends only this reset after the percent.
    nonisolated static func pluginMenuBarResetToken(layout: MenuBarLayout) -> MenuBarLayoutToken? {
        layout.lines.joined().first { $0 == .resetCountdown || $0 == .resetAbsolute }
    }

    /// Reset text for the plugin's switcher window, formatted by the layout's reset token.
    nonisolated static func pluginMenuBarResetText(
        layout: MenuBarLayout,
        snapshot: UsageSnapshot?,
        now: Date) -> String?
    {
        guard let token = self.pluginMenuBarResetToken(layout: layout),
              let window = self.pluginSwitcherMetricWindow(snapshot: snapshot)
        else { return nil }
        guard let resetsAt = window.resetsAt else { return window.resetDescription }
        return token == .resetAbsolute
            ? UsageFormatter.resetDescription(from: resetsAt, now: now)
            : UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
    }

    nonisolated static func switcherWeeklyMetricPercent(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        showUsed: Bool,
        preference: MenuBarMetricPreference = .automatic) -> Double?
    {
        let metric = preference == .automatic || preference == .monthlyPlan
            ? MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: false)
            : nil
        let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation
        let window: RateWindow? = if preference == .monthlyPlan {
            metric
        } else if provider == .mistral {
            nil
        } else if preference == .automatic,
                  let metric,
                  presentation.switcherUsesAutomaticMenuBarWindow
                  || (presentation.automaticSelectionPrioritizesExhaustedWindow && metric.usedPercent >= 100)
        {
            metric
        } else {
            snapshot?.switcherWeeklyWindow(for: provider, showUsed: showUsed)
        }
        if let window {
            return showUsed ? window.usedPercent : window.remainingPercent
        }
        guard preference == .automatic,
              let snapshot,
              let usedPercent = presentation.fallbackSwitcherUsedPercent(snapshot: snapshot),
              usedPercent.isFinite else { return nil }
        return showUsed ? usedPercent : max(0, 100 - usedPercent)
    }
}
