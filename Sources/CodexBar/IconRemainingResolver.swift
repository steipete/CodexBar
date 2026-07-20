import CodexBarCore
import Foundation

enum IconRemainingResolver {
    private static let visibleZeroPercent = 0.0001
    private static let antigravityQuotaSummaryWindowIDPrefix = "antigravity-quota-summary-"
    // Antigravity quota summaries expose exact 5-hour session and weekly buckets for the compact icon.
    private static let sessionWindowMinutes = 5 * 60
    private static let weeklyWindowMinutes = 7 * 24 * 60

    private static func codexProjection(snapshot: UsageSnapshot, now: Date) -> CodexConsumerProjection {
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
                now: now))
    }

    private static func codexVisibleWindows(snapshot: UsageSnapshot, now: Date) -> [RateWindow] {
        let projection = self.codexProjection(snapshot: snapshot, now: now)
        return projection.visibleRateLanes.compactMap { projection.menuBarSelectableRateWindow(for: $0) }
    }

    static func resolvedWindows(
        snapshot: UsageSnapshot,
        style: IconStyle,
        secondaryOverrideWindowID: String? = nil,
        now: Date = Date())
        -> (primary: RateWindow?, secondary: RateWindow?)
    {
        if style == .perplexity {
            let windows = snapshot.orderedPerplexityDisplayWindows()
            return (
                primary: windows.first,
                secondary: windows.dropFirst().first)
        }
        if style == .codex {
            let windows = self.codexVisibleWindows(snapshot: snapshot, now: now)
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
        secondaryOverrideWindowID: String? = nil,
        now: Date = Date())
        -> (primary: Double?, secondary: Double?)
    {
        let windows = self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID,
            now: now)
        return (
            primary: windows.primary?.remainingPercent,
            secondary: windows.secondary?.remainingPercent)
    }

    static func resolvedPercents(
        snapshot: UsageSnapshot,
        style: IconStyle,
        showUsed: Bool,
        renderingStyle: IconStyle? = nil,
        secondaryOverrideWindowID: String? = nil,
        now: Date = Date())
        -> (primary: Double?, secondary: Double?)
    {
        let windows = Self.resolvedWindows(
            snapshot: snapshot,
            style: style,
            secondaryOverrideWindowID: secondaryOverrideWindowID,
            now: now)
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
