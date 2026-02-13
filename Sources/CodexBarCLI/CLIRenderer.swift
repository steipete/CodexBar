import CodexBarCore
import Foundation

enum CLIRenderer {
    private static let accentColor = "95"
    private static let accentBoldColor = "1;95"
    private static let subtleColor = "90"
    private static let paceMinimumExpectedPercent: Double = 3
    private static let usageBarWidth = 12

    static func renderText(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot?,
        context: RenderContext) -> String
    {
        let meta = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        let now = Date()
        var lines: [String] = []
        lines.append(self.headerLine(context.header, useColor: context.useColor))

        if let primary = snapshot.primary {
            lines.append(self.rateLine(title: meta.sessionLabel, window: primary, useColor: context.useColor))
            if provider == .warp {
                if let reset = self.resetLineForWarp(window: primary, style: context.resetStyle, now: now) {
                    lines.append(self.subtleLine(reset, useColor: context.useColor))
                }
                if let detail = self.detailLineForWarp(window: primary) {
                    lines.append(self.subtleLine(detail, useColor: context.useColor))
                }
            } else if let reset = self.resetLine(for: primary, style: context.resetStyle, now: now) {
                lines.append(self.subtleLine(reset, useColor: context.useColor))
            }
        } else if let cost = snapshot.providerCost {
            // Fallback to cost/quota display if no primary rate window
            let label = cost.currencyCode == "Quota" ? "Quota" : "Cost"
            let value = "\(String(format: "%.1f", cost.used)) / \(String(format: "%.1f", cost.limit))"
            lines.append(self.labelValueLine(label, value: value, useColor: context.useColor))
        }

        if let weekly = snapshot.secondary {
            lines.append(self.rateLine(title: meta.weeklyLabel, window: weekly, useColor: context.useColor))
            if let pace = self.paceLine(provider: provider, window: weekly, useColor: context.useColor, now: now) {
                lines.append(pace)
            }
            if provider == .warp {
                if let reset = self.resetLineForWarp(window: weekly, style: context.resetStyle, now: now) {
                    lines.append(self.subtleLine(reset, useColor: context.useColor))
                }
                if let detail = self.detailLineForWarp(window: weekly) {
                    lines.append(self.subtleLine(detail, useColor: context.useColor))
                }
            } else if let reset = self.resetLine(for: weekly, style: context.resetStyle, now: now) {
                lines.append(self.subtleLine(reset, useColor: context.useColor))
            }
        }

        if meta.supportsOpus, let opus = snapshot.tertiary {
            lines.append(self.rateLine(title: meta.opusLabel ?? "Sonnet", window: opus, useColor: context.useColor))
            if let reset = self.resetLine(for: opus, style: context.resetStyle, now: now) {
                lines.append(self.subtleLine(reset, useColor: context.useColor))
            }
        }

        if provider == .codex, let credits {
            lines.append(self.labelValueLine(
                "Credits",
                value: UsageFormatter.creditsString(from: credits.remaining),
                useColor: context.useColor))
        }

        if let email = snapshot.accountEmail(for: provider), !email.isEmpty {
            lines.append(self.labelValueLine("Account", value: email, useColor: context.useColor))
        }
        if let plan = snapshot.loginMethod(for: provider), !plan.isEmpty {
            lines.append(self.labelValueLine("Plan", value: plan.capitalized, useColor: context.useColor))
        }

        if let status = context.status {
            let statusLine = "Status: \(status.indicator.label)\(status.descriptionSuffix)"
            lines.append(self.colorize(statusLine, indicator: status.indicator, useColor: context.useColor))
        }

        return lines.joined(separator: "\n")
    }

    static func rateLine(title: String, window: RateWindow, useColor: Bool) -> String {
        let text = UsageFormatter.usageLine(
            remaining: window.remainingPercent,
            used: window.usedPercent,
            showUsed: false)
        let colored = self.colorizeUsage(text, remainingPercent: window.remainingPercent, useColor: useColor)
        let bar = self.usageBar(remainingPercent: window.remainingPercent, useColor: useColor)
        return "\(title): \(colored) \(bar)"
    }

    private static func resetLine(for window: RateWindow, style: ResetTimeDisplayStyle, now: Date) -> String? {
        UsageFormatter.resetLine(for: window, style: style, now: now)
    }

    private static func resetLineForWarp(window: RateWindow, style: ResetTimeDisplayStyle, now: Date) -> String? {
        // Warp uses resetDescription for non-reset detail. Only render "Resets ..." when a concrete reset date exists.
        guard window.resetsAt != nil else { return nil }
        let resetOnlyWindow = RateWindow(
            usedPercent: window.usedPercent,
            windowMinutes: window.windowMinutes,
            resetsAt: window.resetsAt,
            resetDescription: nil)
        return UsageFormatter.resetLine(for: resetOnlyWindow, style: style, now: now)
    }

    private static func detailLineForWarp(window: RateWindow) -> String? {
        guard let desc = window.resetDescription else { return nil }
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func headerLine(_ header: String, useColor: Bool) -> String {
        let decorated = "== \(header) =="
        guard useColor else { return decorated }
        return self.ansi(self.accentBoldColor, decorated)
    }

    private static func labelValueLine(_ label: String, value: String, useColor: Bool) -> String {
        let labelText = self.label(label, useColor: useColor)
        return "\(labelText): \(value)"
    }

    private static func label(_ text: String, useColor: Bool) -> String {
        guard useColor else { return text }
        return self.ansi(self.accentColor, text)
    }

    private static func subtleLine(_ text: String, useColor: Bool) -> String {
        guard useColor else { return text }
        return self.ansi(self.subtleColor, text)
    }

    private static func usageBar(remainingPercent: Double, useColor: Bool) -> String {
        let clamped = max(0, min(100, remainingPercent))
        let rawFilled = Int((clamped / 100) * Double(Self.usageBarWidth))
        let filled = max(0, min(Self.usageBarWidth, rawFilled))
        let empty = max(0, Self.usageBarWidth - filled)
        let bar = "[\(String(repeating: "=", count: filled))\(String(repeating: "-", count: empty))]"
        guard useColor else { return bar }
        return self.ansi(self.accentColor, bar)
    }

    private static func paceLine(
        provider: UsageProvider,
        window: RateWindow,
        useColor: Bool,
        now: Date) -> String?
    {
        guard provider == .codex || provider == .claude else { return nil }
        guard window.remainingPercent > 0 else { return nil }
        guard let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080) else { return nil }
        guard pace.expectedUsedPercent >= Self.paceMinimumExpectedPercent else { return nil }

        let expected = Int(pace.expectedUsedPercent.rounded())
        var parts: [String] = []
        parts.append(Self.paceLeftLabel(for: pace))
        parts.append("Expected \(expected)% used")
        if let rightLabel = Self.paceRightLabel(for: pace, now: now) {
            parts.append(rightLabel)
        }
        let label = self.label("Pace", useColor: useColor)
        return "\(label): \(parts.joined(separator: " | "))"
    }

    private static func paceLeftLabel(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        switch pace.stage {
        case .onTrack:
            return "On pace"
        case .slightlyAhead, .ahead, .farAhead:
            return "\(deltaValue)% in deficit"
        case .slightlyBehind, .behind, .farBehind:
            return "\(deltaValue)% in reserve"
        }
    }

    private static func paceRightLabel(for pace: UsagePace, now: Date) -> String? {
        if pace.willLastToReset { return "Lasts until reset" }
        guard let etaSeconds = pace.etaSeconds else { return nil }
        let etaText = Self.paceDurationText(seconds: etaSeconds, now: now)
        if etaText == "now" { return "Runs out now" }
        return "Runs out in \(etaText)"
    }

    private static func paceDurationText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        if countdown == "now" { return "now" }
        if countdown.hasPrefix("in ") { return String(countdown.dropFirst(3)) }
        return countdown
    }

    private static func colorizeUsage(_ text: String, remainingPercent: Double, useColor: Bool) -> String {
        guard useColor else { return text }

        let code = switch remainingPercent {
        case ..<10:
            "31" // red
        case ..<25:
            "33" // yellow
        default:
            "32" // green
        }
        return self.ansi(code, text)
    }

    private static func colorize(
        _ text: String,
        indicator: ProviderStatusPayload.ProviderStatusIndicator,
        useColor: Bool)
        -> String
    {
        guard useColor else { return text }
        let code = switch indicator {
        case .none: "32" // green
        case .minor: "33" // yellow
        case .major, .critical: "31" // red
        case .maintenance: "34" // blue
        case .unknown: "90" // gray
        }
        return self.ansi(code, text)
    }

    private static func ansi(_ code: String, _ text: String) -> String {
        "\u{001B}[\(code)m\(text)\u{001B}[0m"
    }
}

struct RenderContext {
    let header: String
    let status: ProviderStatusPayload?
    let useColor: Bool
    let resetStyle: ResetTimeDisplayStyle
}
