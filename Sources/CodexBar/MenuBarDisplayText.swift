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
        showUsed: Bool)
        -> String?
    {
        var parts: [String] = []
        if let sessionWindow,
           let session = self.percentText(window: sessionWindow, showUsed: showUsed)
        {
            parts.append("\(self.sessionWindowLabel(window: sessionWindow)) \(session)")
        }
        if let weekly = self.percentText(window: weeklyWindow, showUsed: showUsed) {
            parts.append("W \(weekly)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        now: Date = .init()) -> String?
    {
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
            if let resetsAt = percentWindow.resetsAt {
                let description = switch resetTimeDisplayStyle {
                case .countdown:
                    UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
                case .absolute:
                    UsageFormatter.resetDescription(from: resetsAt, now: now)
                }
                return "↻ \(description)"
            }
            if let resetDescription = self.resetMetadataText(percentWindow.resetDescription) {
                return "↻ \(resetDescription)"
            }
            return self.percentText(window: percentWindow, showUsed: showUsed)
        }
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
