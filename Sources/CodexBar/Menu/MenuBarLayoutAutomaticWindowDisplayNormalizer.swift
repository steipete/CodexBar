import CodexBarCore

enum MenuBarLayoutAutomaticWindowDisplayNormalizer {
    static func normalized(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        window: RateWindow?)
        -> RateWindow?
    {
        // Provider-specific by design: DeepSeek embeds overflow-prone paid/granted detail in its balance text.
        guard provider == .deepseek,
              let window,
              let balance = MenuBarDisplayText.deepSeekBalanceText(snapshot: snapshot)
        else {
            return window
        }
        return RateWindow(
            usedPercent: window.usedPercent,
            windowMinutes: window.windowMinutes,
            resetsAt: window.resetsAt,
            resetDescription: balance,
            nextRegenPercent: window.nextRegenPercent,
            isSyntheticPlaceholder: window.isSyntheticPlaceholder)
    }
}
