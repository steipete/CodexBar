import CodexBarCore

enum IconRemainingResolver {
    private static let visibleZeroPercent = 0.0001
    private static let antigravityQuotaSummaryWindowIDPrefix = "antigravity-quota-summary-"
    // Antigravity quota summaries expose exact 5-hour session and weekly buckets for the compact icon.
    private static let sessionWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60

    private static func codexProjection(snapshot: UsageSnapshot) -> CodexConsumerProjection {
        CodexConsumerProjection.make(
            surface: .menuBar,
            context: CodexConsumerProjection.Context(
                snapshot: snapshot,
                rawUsageError: nil,
                liveCredits: nil,
                rawCreditsError: nil,
                liveDashboard: nil,
                rawDashboardError: nil,
                dashboardAttachmentAuthorized: false,
                dashboardRequiresLogin: false,
                now: snapshot.updatedAt))
    }

    private static func codexVisibleWindows(snapshot: UsageSnapshot) -> [RateWindow] {
        let projection = self.codexProjection(snapshot: snapshot)
        return projection.visibleRateLanes.compactMap { projection.rateWindow(for: $0) }
    }

    private static func antigravityQuotaSummaryWindows(
        snapshot: UsageSnapshot)
        -> (primary: RateWindow?, secondary: RateWindow?)?
    {
        let quotaSummaryWindows = snapshot.extraRateWindows?
            .filter {
                $0.id.hasPrefix(Self.antigravityQuotaSummaryWindowIDPrefix)
            } ?? []
        guard !quotaSummaryWindows.isEmpty else { return nil }

        return self.antigravityQuotaSummaryPair(in: quotaSummaryWindows.filter(\.usageKnown))
    }

    private static func antigravityQuotaSummaryPair(
        in windows: [NamedRateWindow])
        -> (primary: RateWindow?, secondary: RateWindow?)?
    {
        let session = self.mostConstrainedWindow(in: windows, windowMinutes: Self.sessionWindowMinutes)
        let weekly = self.mostConstrainedWindow(in: windows, windowMinutes: Self.weeklyWindowMinutes)
        guard session != nil || weekly != nil else { return nil }
        return (primary: session, secondary: weekly)
    }

    /// Returns the highest-usage window for an exact Antigravity compact-icon cadence.
    private static func mostConstrainedWindow(in windows: [NamedRateWindow], windowMinutes: Int) -> RateWindow? {
        windows
            .filter { $0.window.windowMinutes == windowMinutes }
            .max { lhs, rhs in
                if lhs.window.usedPercent != rhs.window.usedPercent {
                    return lhs.window.usedPercent < rhs.window.usedPercent
                }
                // max(by:) keeps the right-hand element when this returns true; use `>` so the smallest id wins ties.
                return lhs.id > rhs.id
            }?
            .window
    }

    static func resolvedWindows(
        snapshot: UsageSnapshot,
        style: IconStyle,
        secondaryOverrideWindowID: String? = nil)
        -> (primary: RateWindow?, secondary: RateWindow?)
    {
        if style == .perplexity {
            let windows = snapshot.orderedPerplexityDisplayWindows()
            return (
                primary: windows.first,
                secondary: windows.dropFirst().first)
        }
        if style == .antigravity {
            // Only current quota-summary buckets define the fixed session/weekly icon lanes.
            return self.antigravityQuotaSummaryWindows(snapshot: snapshot)
                ?? (primary: nil, secondary: nil)
        }
        if style == .codex {
            let windows = self.codexVisibleWindows(snapshot: snapshot)
            return (
                primary: windows.first,
                secondary: windows.dropFirst().first)
        }
        if style == .copilot,
           let secondaryOverrideWindowID,
           let extraWindow = snapshot.extraRateWindows?.first(where: { $0.id == secondaryOverrideWindowID })?.window
        {
            return (
                primary: snapshot.primary,
                secondary: extraWindow)
        }
        return (
            primary: snapshot.primary,
            secondary: snapshot.secondary)
    }

    static func resolvedRemaining(
        snapshot: UsageSnapshot,
        style: IconStyle,
        secondaryOverrideWindowID: String? = nil)
        -> (primary: Double?, secondary: Double?)
    {
        let windows = self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID)
        return (
            primary: windows.primary?.remainingPercent,
            secondary: windows.secondary?.remainingPercent)
    }

    static func resolvedPercents(
        snapshot: UsageSnapshot,
        style: IconStyle,
        showUsed: Bool,
        renderingStyle: IconStyle? = nil,
        secondaryOverrideWindowID: String? = nil)
        -> (primary: Double?, secondary: Double?)
    {
        let windows = Self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID)
        var percents = (
            primary: showUsed ? windows.primary?.usedPercent : windows.primary?.remainingPercent,
            secondary: showUsed ? windows.secondary?.usedPercent : windows.secondary?.remainingPercent)
        // Provider style chooses the usage lanes; rendering style controls renderer-specific layout sentinels.
        // Merged icons still resolve Warp's lanes, but render as `.combined` and must keep the real percentage.
        if showUsed, style == .warp, (renderingStyle ?? style) == .warp, let secondary = windows.secondary {
            if secondary.remainingPercent <= 0 {
                // Preserve Warp's exhausted/no-bonus layout even though used percent is 100.
                percents.secondary = 0
            } else if percents.secondary == 0 {
                // A zero fill means "lane absent" to IconRenderer; keep an unused bonus lane visible.
                percents.secondary = self.visibleZeroPercent
            }
        }
        return percents
    }
}
