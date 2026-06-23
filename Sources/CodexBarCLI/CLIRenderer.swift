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
        context: RenderContext,
        now: Date = Date()) -> String
    {
        let meta = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        let labels = self.rateWindowLabels(provider: provider, metadata: meta, snapshot: snapshot)
        var lines: [String] = []
        lines.append(self.headerLine(context.header, useColor: context.useColor))
        self.appendPrimaryLines(
            provider: provider,
            snapshot: snapshot,
            labels: labels,
            context: context,
            now: now,
            lines: &lines)
        self.appendSecondaryLines(
            provider: provider,
            snapshot: snapshot,
            labels: labels,
            context: context,
            now: now,
            lines: &lines)
        self.appendTertiaryLines(snapshot: snapshot, labels: labels, context: context, now: now, lines: &lines)
        self.appendMiMoBalanceLine(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendDeepgramLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendAmpBalanceLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendLimitsUnavailableLine(
            provider: provider,
            snapshot: snapshot,
            useColor: context.useColor,
            lines: &lines)
        self.appendCreditsLine(provider: provider, credits: credits, useColor: context.useColor, lines: &lines)
        self.appendCodexResetCreditsLine(
            provider: provider,
            snapshot: snapshot,
            now: now,
            useColor: context.useColor,
            lines: &lines)
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

    static func providerPacePayload(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        weeklyWorkDays: Int? = nil,
        now: Date = Date()) -> ProviderPacePayload?
    {
        let primary = snapshot.primary.flatMap {
            self.pacePayload(provider: provider, window: $0, kind: .session, now: now)
        }
        let secondary = snapshot.secondary.flatMap {
            self.pacePayload(provider: provider, window: $0, kind: .weekly, weeklyWorkDays: weeklyWorkDays, now: now)
        }
        guard primary != nil || secondary != nil else { return nil }
        return ProviderPacePayload(primary: primary, secondary: secondary)
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
        labels: RateWindowLabels,
        context: RenderContext,
        now: Date,
        lines: inout [String])
    {
        if let primary = snapshot.primary {
            self.appendRateWindowLines(
                provider: provider,
                title: labels.primary,
                window: primary,
                paceKind: .session,
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
        labels: RateWindowLabels,
        context: RenderContext,
        now: Date,
        lines: inout [String])
    {
        guard let weekly = snapshot.secondary else { return }
        self.appendRateWindowLines(
            provider: provider,
            title: labels.secondary,
            window: weekly,
            paceKind: .weekly,
            context: context,
            now: now,
            lines: &lines)
    }

    private static func appendMiMoBalanceLine(
        snapshot: UsageSnapshot,
        useColor: Bool,
        lines: inout [String])
    {
        guard let usage = snapshot.mimoUsage else { return }
        lines.append(self.labelValueLine("Balance", value: usage.balanceDetail, useColor: useColor))
    }

    private static func appendTertiaryLines(
        snapshot: UsageSnapshot,
        labels: RateWindowLabels,
        context: RenderContext,
        now: Date,
        lines: inout [String])
    {
        guard labels.showsTertiary, let opus = snapshot.tertiary else { return }
        lines.append(self.rateLine(title: labels.tertiary, window: opus, useColor: context.useColor))
        if let reset = self.resetLine(for: opus, style: context.resetStyle, now: now) {
            lines.append(self.subtleLine(reset, useColor: context.useColor))
        }
    }

    private static func appendDeepgramLines(
        snapshot: UsageSnapshot,
        useColor: Bool,
        lines: inout [String])
    {
        guard let usage = snapshot.deepgramUsage else { return }
        for line in usage.displayLines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                lines.append(self.labelValueLine(
                    parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    value: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
                    useColor: useColor))
            } else {
                lines.append(self.labelValueLine("Usage", value: line, useColor: useColor))
            }
        }
    }

    private static func appendAmpBalanceLines(
        snapshot: UsageSnapshot,
        useColor: Bool,
        lines: inout [String])
    {
        guard let usage = snapshot.ampUsage else { return }
        if let individualCredits = usage.individualCredits {
            lines.append(self.labelValueLine(
                "Individual credits",
                value: UsageFormatter.currencyString(individualCredits, currencyCode: "USD"),
                useColor: useColor))
        }
        for workspace in usage.workspaceBalances {
            lines.append(self.labelValueLine(
                "Workspace \(workspace.name)",
                value: UsageFormatter.currencyString(workspace.remaining, currencyCode: "USD"),
                useColor: useColor))
        }
    }

    private struct RateWindowLabels {
        let primary: String
        let secondary: String
        let tertiary: String
        let showsTertiary: Bool
    }

    private static func rateWindowLabels(
        provider: UsageProvider,
        metadata: ProviderMetadata,
        snapshot: UsageSnapshot) -> RateWindowLabels
    {
        if provider == .factory, snapshot.tertiary != nil {
            return RateWindowLabels(
                primary: "5-hour",
                secondary: "Weekly",
                tertiary: "Monthly",
                showsTertiary: true)
        }
        let primaryLabel = provider == .grok
            ? GrokProviderDescriptor.primaryLabel(window: snapshot.primary) ?? metadata.sessionLabel
            : metadata.sessionLabel
        return RateWindowLabels(
            primary: primaryLabel,
            secondary: metadata.weeklyLabel,
            tertiary: metadata.opusLabel ?? "Sonnet",
            showsTertiary: metadata.supportsOpus)
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

    private static func appendCodexResetCreditsLine(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        now: Date,
        useColor: Bool,
        lines: inout [String])
    {
        guard provider == .codex, let resetCredits = snapshot.codexResetCredits else { return }
        let value = if resetCredits.availableCount == 1 {
            "1 available"
        } else {
            "\(resetCredits.availableCount) available"
        }
        lines.append(self.labelValueLine("Limit Reset Credits", value: value, useColor: useColor))
        guard resetCredits.availableCount > 0,
              let expiresAt = resetCredits.nextExpiringAvailableCredit?.expiresAt
        else {
            return
        }
        let expiry = UsageFormatter.resetCountdownDescription(from: expiresAt, now: now)
        lines.append(self.subtleLine("Next reset credit expires \(expiry)", useColor: useColor))
    }

    private static func appendLimitsUnavailableLine(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        useColor: Bool,
        lines: inout [String])
    {
        guard snapshot.rateLimitsUnavailable(for: provider) else { return }
        lines.append(self.labelValueLine("Limits", value: "not available", useColor: useColor))
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
        } else if let plan = snapshot.loginMethod(for: provider),
                  !plan.isEmpty,
                  provider != .mimo || !plan.localizedCaseInsensitiveContains("balance:")
        {
            let displayPlan = if provider == .codex {
                CodexPlanFormatting.displayName(plan) ?? plan
            } else {
                plan.capitalized
            }
            lines.append(self.labelValueLine("Plan", value: displayPlan, useColor: context.useColor))
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
        paceKind: PaceKind?,
        context: RenderContext,
        now: Date,
        lines: inout [String])
    {
        lines.append(self.rateLine(title: title, window: window, useColor: context.useColor))
        if let paceKind,
           let pace = self.paceLine(
               provider: provider,
               window: window,
               kind: paceKind,
               weeklyWorkDays: context.weeklyWorkDays,
               useColor: context.useColor,
               now: now)
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
        if provider == .warp || provider == .kilo || provider == .mistral || provider == .deepseek ||
            provider == .crof
        {
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
        // Some provider snapshots use resetDescription for non-reset detail.
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

    /// .session mirrors the GUI's session pace (5h window, real session windows only); .weekly reads
    /// weeklyProgressWorkDays from the GUI's UserDefaults (same key) and passes it to UsagePace.weekly,
    /// so the baseline matches the menu bar when the setting is configured. Codex historical refinement
    /// is not applied (fixed allowlist only), so it can still differ from the menu for Codex accounts.
    private enum PaceKind {
        case session
        case weekly

        var defaultWindowMinutes: Int {
            switch self {
            case .session: 300
            case .weekly: 10080
            }
        }

        func supports(provider: UsageProvider) -> Bool {
            switch self {
            case .session:
                provider == .codex || provider == .claude || provider == .ollama
            case .weekly:
                provider == .codex || provider == .claude || provider == .opencode || provider == .ollama
            }
        }
    }

    private static func computePace(
        provider: UsageProvider,
        window: RateWindow,
        kind: PaceKind,
        weeklyWorkDays: Int? = nil,
        now: Date) -> UsagePace?
    {
        guard kind.supports(provider: provider) else { return nil }
        // Only pace a real session window here; Claude w/o 5-hour data falls a 7-day window into primary.
        if case .session = kind, let minutes = window.windowMinutes, minutes > 300 { return nil }
        if provider == .ollama, window.windowMinutes == nil { return nil }
        guard window.remainingPercent > 0 else { return nil }
        // workDays applies only to the weekly (10 080-min) window; UsagePace.weekly ignores it for other durations.
        let workDays = kind == .weekly ? weeklyWorkDays : nil
        guard let pace = UsagePace.weekly(
            window: window,
            now: now,
            defaultWindowMinutes: kind.defaultWindowMinutes,
            workDays: workDays) else { return nil }
        guard pace.expectedUsedPercent >= Self.paceMinimumExpectedPercent else { return nil }
        return pace
    }

    private static func paceSummary(for pace: UsagePace, kind: PaceKind, now: Date) -> String {
        let expected = Int(pace.expectedUsedPercent.rounded())
        var parts: [String] = []
        parts.append(Self.paceLeftLabel(for: pace))
        parts.append("Expected \(expected)% used")
        if let rightLabel = Self.paceRightLabel(for: pace, kind: kind, now: now) {
            parts.append(rightLabel)
        }
        return parts.joined(separator: " | ")
    }

    private static func paceLine(
        provider: UsageProvider,
        window: RateWindow,
        kind: PaceKind,
        weeklyWorkDays: Int? = nil,
        useColor: Bool,
        now: Date) -> String?
    {
        guard let pace = self.computePace(
            provider: provider,
            window: window,
            kind: kind,
            weeklyWorkDays: weeklyWorkDays,
            now: now) else { return nil }
        let label = self.label("Pace", useColor: useColor)
        return "\(label): \(self.paceSummary(for: pace, kind: kind, now: now))"
    }

    private static func pacePayload(
        provider: UsageProvider,
        window: RateWindow,
        kind: PaceKind,
        weeklyWorkDays: Int? = nil,
        now: Date) -> PacePayload?
    {
        guard let pace = self.computePace(
            provider: provider,
            window: window,
            kind: kind,
            weeklyWorkDays: weeklyWorkDays,
            now: now) else { return nil }
        return PacePayload(
            stage: Self.stageString(pace.stage),
            deltaPercent: pace.deltaPercent.rounded(),
            expectedUsedPercent: pace.expectedUsedPercent.rounded(),
            willLastToReset: pace.willLastToReset,
            etaSeconds: pace.etaSeconds.map { $0.rounded() },
            runOutProbability: pace.runOutProbability,
            summary: self.paceSummary(for: pace, kind: kind, now: now))
    }

    private static func stageString(_ stage: UsagePace.Stage) -> String {
        switch stage {
        case .farAhead: "farAhead"
        case .ahead: "ahead"
        case .slightlyAhead: "slightlyAhead"
        case .onTrack: "onTrack"
        case .slightlyBehind: "slightlyBehind"
        case .behind: "behind"
        case .farBehind: "farBehind"
        }
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

    private static func paceRightLabel(for pace: UsagePace, kind: PaceKind, now: Date) -> String? {
        if pace.willLastToReset { return "Lasts until reset" }
        guard let etaSeconds = pace.etaSeconds else { return nil }
        let etaText = Self.paceDurationText(seconds: etaSeconds, now: now)
        switch kind {
        case .session:
            return etaText == "now" ? "Projected empty now" : "Projected empty in \(etaText)"
        case .weekly:
            return etaText == "now" ? "Runs out now" : "Runs out in \(etaText)"
        }
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
    let weeklyWorkDays: Int?
    let notes: [String]

    init(
        header: String,
        status: ProviderStatusPayload?,
        useColor: Bool,
        resetStyle: ResetTimeDisplayStyle,
        weeklyWorkDays: Int? = nil,
        notes: [String] = [])
    {
        self.header = header
        self.status = status
        self.useColor = useColor
        self.resetStyle = resetStyle
        self.weeklyWorkDays = weeklyWorkDays
        self.notes = notes
    }
}
