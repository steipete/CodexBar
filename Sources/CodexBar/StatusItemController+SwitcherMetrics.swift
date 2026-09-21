import CodexBarCore

extension StatusItemController {
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
