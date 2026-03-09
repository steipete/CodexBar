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
        self.appendPrimaryLines(
            provider: provider,
            snapshot: snapshot,
            metadata: meta,
            context: context,
            now: now,
            lines: &lines)
        self.appendSecondaryLines(
            provider: provider,
            snapshot: snapshot,
            metadata: meta,
            context: context,
            now: now,
            lines: &lines)
        self.appendTertiaryLines(snapshot: snapshot, metadata: meta, context: context, now: now, lines: &lines)
        self.appendCreditsLine(provider: provider, credits: credits, useColor: context.useColor, lines: &lines)
        self.appendIdentityAndNotes(
            provider: provider,
            snapshot: snapshot,
            context: context,
            lines: &lines)

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

    // swiftlint:disable:next function_parameter_count
    private static func appendPrimaryLines(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        metadata: ProviderMetadata,
        context: RenderContext,
        now: Date,
        lines: inout [String])
    {
        if let primary = snapshot.primary {
            self.appendRateWindowLines(
                provider: provider,
                title: metadata.sessionLabel,
                window: primary,
                includePace: false,
                context: context,
                now: now,
                lines: &lines)
            return
        }

        guard let cost = snapshot.providerCost else { return }
        // Fallback to cost/quota display if no primary rate window.
        let label = cost.currencyCode == "Quota" ? "Quota" : "Cost"
        let value = "\(String(format: "%.1f", cost.used)) / \(String(format: "%.1f", cost.limit))"
        lines.append(self.labelValueLine(label, value: value, useColor: context.useColor))
    }

    // swiftlint:disable:next function_parameter_count
    private static func appendSecondaryLines(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        metadata: ProviderMetadata,
        context: RenderContext,
        now: Date,
        lines: inout [String])
    {
        guard let weekly = snapshot.secondary else { return }
        self.appendRateWindowLines(
            provider: provider,
            title: metadata.weeklyLabel,
            window: weekly,
            includePace: true,
            context: context,
            now: now,
            lines: &lines)
    }

    private static func appendTertiaryLines(
        snapshot: UsageSnapshot,
        metadata: ProviderMetadata,
        context: RenderContext,
        now: Date,
        lines: inout [String])
    {
        guard metadata.supportsOpus, let opus = snapshot.tertiary else { return }
        lines.append(self.rateLine(title: metadata.opusLabel ?? "Sonnet", window: opus, useColor: context.useColor))
        if let reset = self.resetLine(for: opus, style: context.resetStyle, now: now) {
            lines.append(self.subtleLine(reset, useColor: context.useColor))
        }
    }

    private static func appendCreditsLine(
        provider: UsageProvider,
        credits: CreditsSnapshot?,
        useColor: Bool,
        lines: inout [String])
    {
        guard provider == .codex, let credits else { return }
        lines.append(self.labelValueLine(
            "Credits",
            value: UsageFormatter.creditsString(from: credits.remaining),
            useColor: useColor))
    }

    private static func appendIdentityAndNotes(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        context: RenderContext,
        lines: inout [String])
    {
        if let email = snapshot.accountEmail(for: provider), !email.isEmpty {
            lines.append(self.labelValueLine("Account", value: email, useColor: context.useColor))
        }

        if provider == .kilo {
            let kiloLogin = self.kiloLoginParts(snapshot: snapshot)
            if let pass = kiloLogin.pass {
                let cleaned = UsageFormatter.cleanPlanName(pass)
                lines.append(self.labelValueLine("Plan", value: cleaned, useColor: context.useColor))
            }
            for detail in kiloLogin.details {
                lines.append(self.labelValueLine("Activity", value: detail, useColor: context.useColor))
            }
        } else if let plan = snapshot.loginMethod(for: provider), !plan.isEmpty {
            lines.append(self.labelValueLine("Plan", value: plan.capitalized, useColor: context.useColor))
        }

        for note in context.notes {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(self.labelValueLine("Note", value: trimmed, useColor: context.useColor))
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func appendRateWindowLines(
        provider: UsageProvider,
        title: String,
        window: RateWindow,
        includePace: Bool,
        context: RenderContext,
        now: Date,
        lines: inout [String])
    {
        lines.append(self.rateLine(title: title, window: window, useColor: context.useColor))
        if includePace,
           let pace = self.paceLine(provider: provider, window: window, useColor: context.useColor, now: now)
        {
            lines.append(pace)
        }
        self.appendResetAndDetailLines(
            provider: provider,
            window: window,
            context: context,
            now: now,
            lines: &lines)
    }

    private static func appendResetAndDetailLines(
        provider: UsageProvider,
        window: RateWindow,
        context: RenderContext,
        now: Date,
        lines: inout [String])
    {
        if provider == .warp || provider == .kilo {
            if let reset = self.resetLineForDetailBackedWindow(window: window, style: context.resetStyle, now: now) {
                lines.append(self.subtleLine(reset, useColor: context.useColor))
            }
            if let detail = self.detailLineForDetailBackedWindow(window: window) {
                lines.append(self.subtleLine(detail, useColor: context.useColor))
            }
            return
        }

        if let reset = self.resetLine(for: window, style: context.resetStyle, now: now) {
            lines.append(self.subtleLine(reset, useColor: context.useColor))
        }
    }

    private static func resetLine(for window: RateWindow, style: ResetTimeDisplayStyle, now: Date) -> String? {
        UsageFormatter.resetLine(for: window, style: style, now: now)
    }

    private static func resetLineForDetailBackedWindow(
        window: RateWindow,
        style: ResetTimeDisplayStyle,
        now: Date) -> String?
    {
        // Warp/Kilo use resetDescription for non-reset detail.
        // Only render "Resets ..." when a concrete reset date exists.
        guard window.resetsAt != nil else { return nil }
        let resetOnlyWindow = RateWindow(
            usedPercent: window.usedPercent,
            windowMinutes: window.windowMinutes,
            resetsAt: window.resetsAt,
            resetDescription: nil)
        return UsageFormatter.resetLine(for: resetOnlyWindow, style: style, now: now)
    }

    private static func detailLineForDetailBackedWindow(window: RateWindow) -> String? {
        guard let desc = window.resetDescription else { return nil }
        let trimmed = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func kiloLoginParts(snapshot: UsageSnapshot) -> (pass: String?, details: [String]) {
        guard let loginMethod = snapshot.loginMethod(for: .kilo) else {
            return (nil, [])
        }
        let parts = loginMethod
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else {
            return (nil, [])
        }
        let first = parts[0]
        if self.isKiloActivitySegment(first) {
            return (nil, parts)
        }
        return (first, Array(parts.dropFirst()))
    }

    private static func isKiloActivitySegment(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("auto top-up:")
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
    let notes: [String]

    init(
        header: String,
        status: ProviderStatusPayload?,
        useColor: Bool,
        resetStyle: ResetTimeDisplayStyle,
        notes: [String] = [])
    {
        self.header = header
        self.status = status
        self.useColor = useColor
        self.resetStyle = resetStyle
        self.notes = notes
    }
}
