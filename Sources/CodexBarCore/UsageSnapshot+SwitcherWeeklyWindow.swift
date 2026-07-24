extension UsageSnapshot {
    public func switcherWeeklyWindow(for provider: UsageProvider, showUsed: Bool) -> RateWindow? {
        // This surface is labelled "Weekly progress", so prefer a real 7-day lane when one is
        // available. Some providers publish model-specific weekly lanes in extraRateWindows.
        if let weekly = self.mostConstrainedSwitcherWeeklyWindow(for: provider) {
            return weekly
        }

        // Keep the existing provider-specific fallback for providers without a weekly allowance.
        switch provider {
        case .factory:
            // Factory prefers secondary window
            return self.secondary ?? self.primary
        case .perplexity:
            return self.automaticPerplexityWindow()
        case .cursor:
            // Cursor: fall back to on-demand budget when the included plan is exhausted (only in
            // "show remaining" mode). The secondary/tertiary lanes are Total/Auto/API breakdowns,
            // not extra capacity, so they should not replace the remaining paid quota indicator.
            if !showUsed,
               let primary = self.primary,
               primary.remainingPercent <= 0,
               let providerCost = self.providerCost,
               providerCost.limit > 0
            {
                let usedPercent = max(0, min(100, (providerCost.used / providerCost.limit) * 100))
                return RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: providerCost.resetsAt,
                    resetDescription: nil)
            }
            return self.primary ?? self.secondary
        default:
            return self.primary ?? self.secondary
        }
    }

    private func mostConstrainedSwitcherWeeklyWindow(for provider: UsageProvider) -> RateWindow? {
        // Claude's Sonnet/Opus tertiary and model-scoped extras (Fable, Daily Routines) belong on
        // the detail card. The overview switcher should track account Weekly so an exhausted
        // carve-out does not empty the bar while Weekly still has quota left.
        let standardWindows: [RateWindow] = switch provider {
        case .claude:
            [self.primary, self.secondary].compactMap(\.self)
        default:
            [self.primary, self.secondary, self.tertiary].compactMap(\.self)
        }
        let namedWindows = (self.extraRateWindows ?? [])
            .filter(\.usageKnown)
            .filter { named in
                guard provider == .claude else { return true }
                return !named.id.hasPrefix("claude-weekly-scoped-") && named.id != "claude-routines"
            }
            .map(\.window)
        return (standardWindows + namedWindows)
            .filter { $0.windowMinutes == 7 * 24 * 60 }
            .max { $0.usedPercent < $1.usedPercent }
    }
}
