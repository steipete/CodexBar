import CodexBarCore
import Foundation

enum MenuBarDisplayText {
    static func percentText(window: RateWindow?, showUsed: Bool) -> String? {
        guard let window else { return nil }
        let percent = showUsed ? window.usedPercent : window.remainingPercent
        let clamped = min(100, max(0, percent))
        return String(format: "%.0f%%", clamped)
    }

    static func paceText(pace: UsagePace?) -> String? {
        guard let pace else { return nil }
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        let sign = pace.deltaPercent >= 0 ? "+" : "-"
        return "\(sign)\(deltaValue)%"
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
            return self.paceText(pace: pace)
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
