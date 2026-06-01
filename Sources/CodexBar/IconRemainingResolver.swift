import CodexBarCore

enum IconRemainingResolver {
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
            let windows = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
            return (
                primary: windows.first,
                secondary: windows.dropFirst().first)
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
        if style == .perplexity {
            let windows = snapshot.orderedPerplexityDisplayWindows()
            return (
                primary: windows.first?.remainingPercent,
                secondary: windows.dropFirst().first?.remainingPercent)
        }
        if style == .antigravity {
            let windows = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
            return (
                primary: windows.first?.remainingPercent,
                secondary: windows.dropFirst().first?.remainingPercent)
        }
        if style == .codex {
            let windows = self.codexVisibleWindows(snapshot: snapshot)
            return (
                primary: windows.first?.remainingPercent,
                secondary: windows.dropFirst().first?.remainingPercent)
        }
        if style == .copilot,
           let secondaryOverrideWindowID,
           let extraWindow = snapshot.extraRateWindows?.first(where: { $0.id == secondaryOverrideWindowID })?.window
        {
            return (
                primary: snapshot.primary?.remainingPercent,
                secondary: extraWindow.remainingPercent)
        }
        return (
            primary: snapshot.primary?.remainingPercent,
            secondary: snapshot.secondary?.remainingPercent)
    }

    static func resolvedPercents(
        snapshot: UsageSnapshot,
        style: IconStyle,
        showUsed: Bool,
        secondaryOverrideWindowID: String? = nil)
        -> (primary: Double?, secondary: Double?)
    {
        let windows = Self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID)
        return (
            primary: showUsed ? windows.primary?.usedPercent : windows.primary?.remainingPercent,
            secondary: showUsed ? windows.secondary?.usedPercent : windows.secondary?.remainingPercent)
    }
}
