import CodexBarCore

extension StatusItemController {
    nonisolated static func switcherWeeklyMetricPercent(
        for provider: UsageProvider,
        snapshot: UsageSnapshot?,
        showUsed: Bool,
        preference: MenuBarMetricPreference = .automatic) -> Double?
    {
        let window: RateWindow? = if preference == .monthlyPlan {
            MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: false)
        } else if provider == .mistral {
            nil
        } else {
            snapshot?.switcherWeeklyWindow(for: provider, showUsed: showUsed)
        }
        guard let window else { return nil }
        return showUsed ? window.usedPercent : window.remainingPercent
    }
}
