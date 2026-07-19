import CodexBarCore
import Foundation

enum MenuBarDisplayText {
    static func percentText(window: RateWindow?, showUsed: Bool) -> String? {
        guard let window else { return nil }
        let percent = showUsed ? window.usedPercent : window.remainingPercent
        return UsageFormatter.percentString(percent)
    }

    static func paceText(pace: UsagePace?) -> String? {
        guard let pace else { return nil }
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        if deltaValue == 0 { return "0%" }
        let sign = pace.deltaPercent >= 0 ? "+" : "-"
        return "\(sign)\(deltaValue)%"
    }

    /// Combined "session · weekly" menu-bar text shared by providers that expose both a
    /// session (5h) and weekly (7d) lane, e.g. Codex and Claude.
    static func combinedSessionWeeklyPercentText(
        sessionWindow: RateWindow?,
        weeklyWindow: RateWindow?,
        showUsed: Bool,
        resetTimeDisplayStyle: ResetTimeDisplayStyle = .countdown,
        showsResetTimeWhenExhausted: Bool = false,
        now: Date = .init())
        -> String?
    {
        var parts: [String] = []
        if let sessionWindow,
           let session = self.laneValueText(
               window: sessionWindow,
               showUsed: showUsed,
               resetTimeDisplayStyle: resetTimeDisplayStyle,
               showsResetTimeWhenExhausted: showsResetTimeWhenExhausted,
               now: now)
        {
            parts.append("\(self.sessionWindowLabel(window: sessionWindow)) \(session)")
        }
        if let weeklyWindow,
           let weekly = self.laneValueText(
               window: weeklyWindow,
               showUsed: showUsed,
               resetTimeDisplayStyle: resetTimeDisplayStyle,
               showsResetTimeWhenExhausted: showsResetTimeWhenExhausted,
               now: now)
        {
            parts.append("W \(weekly)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func laneValueText(
        window: RateWindow,
        showUsed: Bool,
        resetTimeDisplayStyle: ResetTimeDisplayStyle,
        showsResetTimeWhenExhausted: Bool,
        now: Date) -> String?
    {
        if let resetText = self.exhaustedResetText(
            window: window,
            enabled: showsResetTimeWhenExhausted,
            style: resetTimeDisplayStyle,
            now: now)
        {
            return resetText
        }
        return self.percentText(window: window, showUsed: showUsed)
    }

    private static func sessionWindowLabel(window: RateWindow) -> String {
        guard let minutes = window.windowMinutes, minutes > 0 else { return "S" }
        guard minutes.isMultiple(of: 60) else { return "\(minutes)m" }
        return "\(minutes / 60)h"
    }

    static func displayText(
        mode: MenuBarDisplayMode,
        percentWindow: RateWindow?,
        pace: UsagePace? = nil,
        showUsed: Bool,
        resetTimeDisplayStyle: ResetTimeDisplayStyle = .countdown,
        showsResetTimeWhenExhausted: Bool = false,
        now: Date = .init()) -> String?
    {
        if mode != .resetTime,
           showsResetTimeWhenExhausted,
           let percentWindow,
           percentWindow.remainingPercent <= 0
        {
            if let resetText = self.exhaustedResetText(
                window: percentWindow,
                enabled: true,
                style: resetTimeDisplayStyle,
                now: now)
            {
                return resetText
            }
            // Smart mode cannot replace an exhausted percentage unless the reset is concrete, future,
            // and schedulable. Preserve the quota signal in pace/both modes too; a pace from another
            // combined lane must not hide that this displayed lane is already exhausted.
            return self.percentText(window: percentWindow, showUsed: showUsed)
        }
        switch mode {
        case .percent:
            return self.percentText(window: percentWindow, showUsed: showUsed)
        case .pace:
            // Pace can be temporarily unavailable near a reset or when a provider omits window metadata.
            // Keep the selected quota visible instead of collapsing the status item to an icon-only state.
            return self.paceText(pace: pace)
                ?? self.percentText(window: percentWindow, showUsed: showUsed)
        case .both:
            guard let percent = percentText(window: percentWindow, showUsed: showUsed) else { return nil }
            // Fall back to percent-only when pace is unavailable (e.g. Copilot)
            guard let paceText = Self.paceText(pace: pace) else { return percent }
            return "\(percent) · \(paceText)"
        case .resetTime:
            guard let percentWindow else { return nil }
            return self.resetTimeText(window: percentWindow, style: resetTimeDisplayStyle, now: now)
                ?? self.percentText(window: percentWindow, showUsed: showUsed)
        }
    }

    /// "↻ …" reset text for a window, or nil when it carries no usable reset metadata.
    static func resetTimeText(
        window: RateWindow,
        style: ResetTimeDisplayStyle,
        now: Date) -> String?
    {
        if let resetsAt = window.resetsAt {
            let description = switch style {
            case .countdown:
                UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
            case .absolute:
                UsageFormatter.resetDescription(from: resetsAt, now: now)
            }
            return "↻ \(description)"
        }
        if let resetDescription = self.resetMetadataText(window.resetDescription) {
            return "↻ \(resetDescription)"
        }
        return nil
    }

    /// Smart-mode replacement: when enabled and the quota is exhausted (0% remaining, regardless of
    /// whether the display shows used or remaining), surface the reset time instead of a dead percent.
    ///
    /// Requires a concrete, still-future `resetsAt`. The smart option only replaces the percent when it
    /// has a reset time it can both render as a live countdown/clock AND hand to the refresh scheduler,
    /// so the lane keeps ticking and flips back to the percentage once the reset passes. Windows with
    /// only textual reset metadata (`resetDescription`, no `resetsAt`) or an already-elapsed reset can't
    /// be scheduled, so they keep showing the percent instead of freezing on stale reset text.
    private static func exhaustedResetText(
        window: RateWindow?,
        enabled: Bool,
        style: ResetTimeDisplayStyle,
        now: Date) -> String?
    {
        guard enabled, let window, window.remainingPercent <= 0 else { return nil }
        guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        return self.resetTimeText(window: window, style: style, now: now)
    }

    private static func resetMetadataText(_ description: String?) -> String? {
        guard let description else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // RateWindow.resetDescription predates provider-specific detail fields and is also used for
        // request/token summaries. Only trust phrases that explicitly describe reset timing.
        let normalized = trimmed.lowercased()
        let resetPrefixes = [
            "reset ", "resets ", "in ", "today ", "today,", "tomorrow ", "tomorrow,", "next ",
            "expire ", "expires ", "refill ", "refills ",
        ]
        let exactResetDescriptions = ["today", "tomorrow", "expired", "now", "soon"]
        return exactResetDescriptions.contains(normalized) || resetPrefixes.contains(where: normalized.hasPrefix)
            ? trimmed
            : nil
    }
}
