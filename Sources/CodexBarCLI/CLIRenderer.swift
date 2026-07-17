import CodexBarCore
import Foundation

// swiftlint:disable:next type_body_length
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
        self.appendClawRouterUsageLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendSub2APIUsageLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendWayfinderUsageLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendDeepgramLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendAmpBalanceLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendDevinOverageBalanceLine(
            provider: provider,
            snapshot: snapshot,
            useColor: context.useColor,
            lines: &lines)
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

    static func renderCardBodyLines(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot?,
        context: RenderContext,
        includeIdentity: Bool,
        now: Date = Date()) -> [String]
    {
        let meta = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        let labels = self.rateWindowLabels(provider: provider, metadata: meta, snapshot: snapshot)
        var lines: [String] = []
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
        self.appendClawRouterUsageLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendSub2APIUsageLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendWayfinderUsageLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendDeepgramLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendAmpBalanceLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendDevinOverageBalanceLine(
            provider: provider,
            snapshot: snapshot,
            useColor: context.useColor,
            lines: &lines)
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
        if includeIdentity {
            self.appendIdentityAndNotes(
                provider: provider,
                snapshot: snapshot,
                context: context,
                lines: &lines)
        } else {
            for note in context.notes {
                let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                lines.append(self.labelValueLine("Note", value: trimmed, useColor: context.useColor))
            }
        }
        return lines
    }

    static func planBadgeText(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        if let usage = snapshot.mimoUsage {
            return usage.balanceDetail
        }
        if provider == .kilo {
            let kiloLogin = self.kiloLoginParts(snapshot: snapshot)
            if let pass = kiloLogin.pass {
                return UsageFormatter.cleanPlanName(pass)
            }
            return nil
        }
        guard let plan = snapshot.loginMethod(for: provider),
              !plan.isEmpty,
              provider != .mimo || !plan.localizedCaseInsensitiveContains("balance:")
        else {
            return nil
        }
        if provider == .codex {
            return CodexPlanFormatting.displayName(plan) ?? plan
        }
        return self.nonCodexPlanDisplay(provider: provider, plan: plan)
    }

    static func colorizeAccentBold(_ text: String) -> String {
        self.ansi(self.accentBoldColor, text)
    }

    static func colorizeAccent(_ text: String) -> String {
        self.ansi(self.accentColor, text)
    }

    static func colorizeSubtle(_ text: String) -> String {
        self.ansi(self.subtleColor, text)
    }

    static func colorizeCardBorder(_ text: String) -> String {
        self.ansi("90", text)
    }

    static func colorizeCardBadge(_ source: String) -> String {
        self.ansi("97;44", " \(source) ")
    }

    static func colorizeCardPlanBox(_ text: String) -> String {
        self.ansi("37", text)
    }

    static func colorizeCardPercent(_ text: String, remainingPercent: Double, useColor: Bool) -> String {
        guard useColor else { return text }
        let code = switch remainingPercent {
        case ..<10: "31"
        case ..<50: "33"
        default: "36"
        }
        return self.ansi(code, text)
    }

    static func colorizeCardUsedPercent(_ text: String, usedPercent: Double, useColor: Bool) -> String {
        guard useColor else { return text }
        let code = switch usedPercent {
        case 90...: "31"
        case 60...: "33"
        default: "36"
        }
        return self.ansi(code, text)
    }

    static func cardUsedBar(usedPercent: Double, width: Int, useColor: Bool) -> String {
        let clamped = max(0, min(100, usedPercent))
        let barWidth = max(4, width)
        let rawFilled = Int((clamped / 100) * Double(barWidth))
        let filled = max(0, min(barWidth, rawFilled))
        let empty = max(0, barWidth - filled)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        guard useColor else { return bar }
        return self.colorizeCardUsedPercent(bar, usedPercent: clamped, useColor: true)
    }

    static func colorizeWarning(_ text: String) -> String {
        self.ansi("33", text)
    }

    static func ansiTrueColor(red: Int, green: Int, blue: Int, _ text: String) -> String {
        let r = max(0, min(255, red))
        let g = max(0, min(255, green))
        let b = max(0, min(255, blue))
        return "\u{001B}[38;2;\(r);\(g);\(b)m\(text)\u{001B}[0m"
    }

    static func ansiTrueColorBackground(red: Int, green: Int, blue: Int, _ text: String) -> String {
        let r = max(0, min(255, red))
        let g = max(0, min(255, green))
        let b = max(0, min(255, blue))
        return "\u{001B}[48;2;\(r);\(g);\(b)m\(text)\u{001B}[0m"
    }

    static func remainingGradientRGB(remainingPercent: Double) -> (dark: (Int, Int, Int), light: (Int, Int, Int)) {
        switch remainingPercent {
        case ..<10:
            ((180, 55, 55), (255, 95, 95))
        case ..<50:
            ((200, 120, 40), (255, 190, 90))
        default:
            ((40, 150, 140), (90, 220, 200))
        }
    }

    static func gradientRemainingBar(remainingPercent: Double, width: Int) -> String {
        let clamped = max(0, min(100, remainingPercent))
        let barWidth = max(4, width)
        let rawFilled = Int((clamped / 100) * Double(barWidth))
        let filled = max(0, min(barWidth, rawFilled))
        let empty = max(0, barWidth - filled)
        let colors = self.remainingGradientRGB(remainingPercent: clamped)
        var bar = ""
        if filled > 0 {
            for index in 0..<filled {
                let t = filled == 1 ? 1.0 : Double(index) / Double(filled - 1)
                let red = Int(Double(colors.dark.0) * (1 - t) + Double(colors.light.0) * t)
                let green = Int(Double(colors.dark.1) * (1 - t) + Double(colors.light.1) * t)
                let blue = Int(Double(colors.dark.2) * (1 - t) + Double(colors.light.2) * t)
                bar += self.ansiTrueColor(red: red, green: green, blue: blue, "█")
            }
        }
        if empty > 0 {
            let emptyCell = self.ansiTrueColor(red: 48, green: 50, blue: 62, "░")
            bar += String(repeating: emptyCell, count: empty)
        }
        return bar
    }

    static func gradientRemainingTrackBar(remainingPercent: Double, width: Int) -> String {
        let clamped = max(0, min(100, remainingPercent))
        let barWidth = max(4, width)
        let rawFilled = Int((clamped / 100) * Double(barWidth))
        let filled = max(0, min(barWidth, rawFilled))
        let empty = max(0, barWidth - filled)
        let colors = self.remainingGradientRGB(remainingPercent: clamped)
        var bar = ""
        if filled > 0 {
            for index in 0..<filled {
                let t = filled == 1 ? 1.0 : Double(index) / Double(filled - 1)
                let red = Int(Double(colors.dark.0) * (1 - t) + Double(colors.light.0) * t)
                let green = Int(Double(colors.dark.1) * (1 - t) + Double(colors.light.1) * t)
                let blue = Int(Double(colors.dark.2) * (1 - t) + Double(colors.light.2) * t)
                bar += self.ansiTrueColorBackground(red: red, green: green, blue: blue, " ")
            }
        }
        if empty > 0 {
            let emptyCell = self.ansiTrueColorBackground(red: 17, green: 30, blue: 50, " ")
            bar += String(repeating: emptyCell, count: empty)
        }
        return bar
    }

    static func gradientUsedBar(usedPercent: Double, width: Int) -> String {
        let clamped = max(0, min(100, usedPercent))
        let barWidth = max(4, width)
        let rawFilled = Int((clamped / 100) * Double(barWidth))
        let filled = max(0, min(barWidth, rawFilled))
        let empty = max(0, barWidth - filled)
        let colors = self.remainingGradientRGB(remainingPercent: 100 - clamped)
        var bar = ""
        if filled > 0 {
            for index in 0..<filled {
                let t = filled == 1 ? 1.0 : Double(index) / Double(filled - 1)
                let red = Int(Double(colors.dark.0) * (1 - t) + Double(colors.light.0) * t)
                let green = Int(Double(colors.dark.1) * (1 - t) + Double(colors.light.1) * t)
                let blue = Int(Double(colors.dark.2) * (1 - t) + Double(colors.light.2) * t)
                bar += self.ansiTrueColor(red: red, green: green, blue: blue, "█")
            }
        }
        if empty > 0 {
            let emptyCell = self.ansiTrueColor(red: 48, green: 50, blue: 62, "░")
            bar += String(repeating: emptyCell, count: empty)
        }
        return bar
    }

    static func colorizeEnhancedAccentBold(_ text: String) -> String {
        self.ansiTrueColor(red: 198, green: 146, blue: 255, text)
    }

    static func colorizeEnhancedAccent(_ text: String) -> String {
        self.ansiTrueColor(red: 176, green: 132, blue: 232, text)
    }

    static func colorizeEnhancedSubtle(_ text: String) -> String {
        self.ansiTrueColor(red: 130, green: 135, blue: 150, text)
    }

    static func colorizeEnhancedBorder(_ text: String) -> String {
        self.ansiTrueColor(red: 90, green: 95, blue: 110, text)
    }

    static func colorizeEnhancedBadge(_ source: String) -> String {
        let r = max(0, min(255, 66))
        let g = max(0, min(255, 133))
        let b = max(0, min(255, 244))
        return "\u{001B}[38;2;245;248;255;48;2;\(r);\(g);\(b)m \(source) \u{001B}[0m"
    }

    static func colorizeEnhancedPlanBox(_ text: String) -> String {
        self.ansiTrueColor(red: 220, green: 222, blue: 230, text)
    }

    static func colorizeEnhancedPlanLabel(_ text: String) -> String {
        self.ansiTrueColor(red: 104, green: 111, blue: 135, text)
    }

    static func colorizeEnhancedPlanValue(_ text: String) -> String {
        self.ansiTrueColor(red: 238, green: 184, blue: 92, text)
    }

    static func colorizeEnhancedRemainingPercent(_ text: String, remainingPercent: Double) -> String {
        let colors = self.remainingGradientRGB(remainingPercent: remainingPercent)
        return self.ansiTrueColor(red: colors.light.0, green: colors.light.1, blue: colors.light.2, text)
    }

    static func colorizeEnhancedUsedPercent(_ text: String, usedPercent: Double) -> String {
        self.colorizeEnhancedRemainingPercent(text, remainingPercent: 100 - usedPercent)
    }

    static func colorizeEnhancedReadable(_ text: String) -> String {
        self.ansiTrueColor(red: 235, green: 238, blue: 245, text)
    }

    static func colorizeEnhancedReadableMuted(_ text: String) -> String {
        self.ansiTrueColor(red: 170, green: 178, blue: 195, text)
    }

    static func colorizeEnhancedGood(_ text: String) -> String {
        self.ansiTrueColor(red: 116, green: 220, blue: 195, text)
    }

    static func colorizeReadable(_ text: String) -> String {
        self.ansi("97", text)
    }

    static func colorizeReadableMuted(_ text: String) -> String {
        self.ansi("37", text)
    }

    static func cardBlockBar(remainingPercent: Double, width: Int, useColor: Bool) -> String {
        let clamped = max(0, min(100, remainingPercent))
        let barWidth = max(8, width)
        let rawFilled = Int((clamped / 100) * Double(barWidth))
        let filled = max(0, min(barWidth, rawFilled))
        let empty = max(0, barWidth - filled)
        let filledBar = String(repeating: "━", count: filled)
        let emptyBar = String(repeating: " ", count: empty)
        guard useColor else { return filledBar + emptyBar }
        return self.colorizeCardPercent(filledBar, remainingPercent: remainingPercent, useColor: true)
            + self.colorizeSubtle(String(repeating: "─", count: empty))
    }

    static func collectCardMetrics(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        resetStyle: ResetTimeDisplayStyle,
        now: Date = Date()) -> [CLICardMetric]
    {
        let meta = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        let labels = self.rateWindowLabels(provider: provider, metadata: meta, snapshot: snapshot)
        var metrics: [CLICardMetric] = []
        if let primary = snapshot.primary, !primary.isSyntheticPlaceholder {
            metrics.append(self.makeCardMetric(
                provider: provider,
                label: labels.primary,
                window: primary,
                resetStyle: resetStyle,
                now: now))
        }
        if let secondary = snapshot.secondary, !secondary.isSyntheticPlaceholder {
            metrics.append(self.makeCardMetric(
                provider: provider,
                label: labels.secondary,
                window: secondary,
                resetStyle: resetStyle,
                now: now))
        }
        if labels.showsTertiary, let tertiary = snapshot.tertiary, !tertiary.isSyntheticPlaceholder {
            metrics.append(self.makeCardMetric(
                provider: provider,
                label: labels.tertiary,
                window: tertiary,
                resetStyle: resetStyle,
                now: now))
        }
        return metrics
    }

    static func collectCardInfoLines(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot?,
        notes: [String],
        useColor: Bool,
        now: Date = Date()) -> [String]
    {
        var lines: [String] = []
        if provider == .codex, let resetCredits = snapshot.codexResetCredits {
            let inventory = resetCredits.availableInventory(at: now)
            let value = inventory.count == 1 ? "1 available" : "\(inventory.count) available"
            lines.append(self.labelValueLine("Limit Reset Credits", value: value, useColor: useColor))
        }
        if provider == .codex, let credits {
            let remaining = credits.codexCreditLimit?.remaining ?? credits.remaining
            lines.append(self.labelValueLine(
                "Credits",
                value: UsageFormatter.creditsString(from: remaining),
                useColor: useColor))
        }
        for note in notes {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(self.labelValueLine("Note", value: trimmed, useColor: useColor))
        }
        return lines
    }

    static func collectCardExtraLines(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        credits: CreditsSnapshot?,
        context: RenderContext,
        now: Date = Date()) -> [String]
    {
        var lines: [String] = []
        if snapshot.primary == nil {
            self.appendPrimaryLines(
                provider: provider,
                snapshot: snapshot,
                labels: self.rateWindowLabels(
                    provider: provider,
                    metadata: ProviderDescriptorRegistry.descriptor(for: provider).metadata,
                    snapshot: snapshot),
                context: context,
                now: now,
                lines: &lines)
        }
        if snapshot.mimoUsage != nil {
            self.appendMiMoBalanceLine(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        }
        self.appendClawRouterUsageLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendSub2APIUsageLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendWayfinderUsageLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendDeepgramLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendAmpBalanceLines(snapshot: snapshot, useColor: context.useColor, lines: &lines)
        self.appendDevinOverageBalanceLine(
            provider: provider,
            snapshot: snapshot,
            useColor: context.useColor,
            lines: &lines)
        self.appendLimitsUnavailableLine(
            provider: provider,
            snapshot: snapshot,
            useColor: context.useColor,
            lines: &lines)
        if provider == .kilo {
            let kiloLogin = self.kiloLoginParts(snapshot: snapshot)
            for detail in kiloLogin.details {
                lines.append(self.labelValueLine("Activity", value: detail, useColor: context.useColor))
            }
        }
        return lines
    }

    private static func makeCardMetric(
        provider: UsageProvider,
        label: String,
        window: RateWindow,
        resetStyle: ResetTimeDisplayStyle,
        now: Date) -> CLICardMetric
    {
        let detailBacked = self.usesDetailBackedWindow(provider: provider)
        let reset = detailBacked
            ? self.resetLineForDetailBackedWindow(window: window, style: resetStyle, now: now)
            : self.resetLine(for: window, style: resetStyle, now: now)
        let detailText = detailBacked ? self.detailLineForDetailBackedWindow(window: window) : nil
        return CLICardMetric(
            label: label,
            remainingPercent: window.remainingPercent,
            resetText: reset.map { "⏳ \($0)" },
            resetAt: window.resetsAt,
            detailText: detailText)
    }

    static func colorizeError(_ text: String) -> String {
        self.ansi("31", text)
    }

    static func colorizeStatusLine(
        _ text: String,
        indicator: ProviderStatusPayload.ProviderStatusIndicator,
        useColor: Bool) -> String
    {
        self.colorize(text, indicator: indicator, useColor: useColor)
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

        guard
            provider != .clawrouter,
            let cost = snapshot.providerCost,
            !(provider == .devin && cost.period == "Extra usage balance")
        else { return }
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

    private static func appendDevinOverageBalanceLine(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        useColor: Bool,
        lines: inout [String])
    {
        guard provider == .devin,
              let cost = snapshot.providerCost,
              cost.period == "Extra usage balance"
        else { return }
        let balance = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
        lines.append(self.labelValueLine("Extra usage", value: balance, useColor: useColor))
    }

    private static func appendClawRouterUsageLines(
        snapshot: UsageSnapshot,
        useColor: Bool,
        lines: inout [String])
    {
        guard let usage = snapshot.clawRouterUsage else { return }

        let spend = usage.budgetSpentUSD ?? usage.actualCostUSD
        let spendValue = UsageFormatter.currencyString(spend, currencyCode: "USD")
        if let limit = usage.budgetLimitUSD, limit > 0 {
            let limitValue = UsageFormatter.currencyString(limit, currencyCode: "USD")
            lines.append(self.labelValueLine("Spend", value: "\(spendValue) / \(limitValue)", useColor: useColor))
        } else {
            lines.append(self.labelValueLine("Spend", value: spendValue, useColor: useColor))
        }

        let requests = UsageFormatter.tokenCountString(usage.requestCount)
        let tokens = UsageFormatter.tokenCountString(usage.totalTokens)
        lines.append(self.labelValueLine("Usage", value: "\(requests) requests · \(tokens) tokens", useColor: useColor))

        if usage.errorCount > 0 {
            lines.append(self.labelValueLine(
                "Results",
                value: "\(usage.successCount) succeeded · \(usage.errorCount) failed",
                useColor: useColor))
        }

        if !usage.providers.isEmpty {
            let providerMix = usage.providers.prefix(5)
                .map { "\($0.provider): \(UsageFormatter.tokenCountString($0.requestCount))" }
                .joined(separator: " · ")
            lines.append(self.labelValueLine("Routed providers", value: providerMix, useColor: useColor))
        }
    }

    private static func appendSub2APIUsageLines(
        snapshot: UsageSnapshot,
        useColor: Bool,
        lines: inout [String])
    {
        guard let usage = snapshot.sub2APIUsage else { return }
        if let balance = usage.balance {
            lines.append(self.labelValueLine(
                "Balance",
                value: UsageFormatter.currencyString(balance, currencyCode: usage.unit),
                useColor: useColor))
        }
        if let today = usage.today {
            lines.append(self.labelValueLine(
                "Today",
                value: self.sub2APITotalsText(today, unit: usage.unit),
                useColor: useColor))
        }
        if let total = usage.total {
            lines.append(self.labelValueLine(
                "Total",
                value: self.sub2APITotalsText(total, unit: usage.unit),
                useColor: useColor))
        }
    }

    private static func sub2APITotalsText(_ totals: Sub2APIUsageDetails.Totals, unit: String) -> String {
        "\(UsageFormatter.tokenCountString(totals.requests)) requests · " +
            "\(UsageFormatter.tokenCountString(totals.totalTokens)) tokens · " +
            UsageFormatter.currencyString(totals.actualCostUSD, currencyCode: unit)
    }

    private static func appendWayfinderUsageLines(
        snapshot: UsageSnapshot,
        useColor: Bool,
        lines: inout [String])
    {
        guard let usage = snapshot.wayfinderUsage else { return }

        lines.append(self.labelValueLine("Gateway", value: usage.gatewaySummary, useColor: useColor))

        if let routed = usage.routedSummary {
            lines.append(self.labelValueLine("Routed", value: routed, useColor: useColor))
        }
        if let saved = usage.savedSummary {
            lines.append(self.labelValueLine("Saved", value: saved, useColor: useColor))
        }
        if let avgDecision = usage.avgDecisionSummary {
            lines.append(self.labelValueLine("Avg decision", value: avgDecision, useColor: useColor))
        }
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
        let primaryLabel = if provider == .grok {
            GrokProviderDescriptor.primaryLabel(window: snapshot.primary) ?? metadata.sessionLabel
        } else if provider == .sub2api {
            Sub2APIProviderDescriptor.primaryLabel(details: snapshot.sub2APIUsage) ?? metadata.sessionLabel
        } else {
            metadata.sessionLabel
        }
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
        let remaining = credits.codexCreditLimit?.remaining ?? credits.remaining
        lines.append(self.labelValueLine(
            "Credits",
            value: UsageFormatter.creditsString(from: remaining),
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
        let inventory = resetCredits.availableInventory(at: now)
        let value = if inventory.count == 1 {
            "1 available"
        } else {
            "\(inventory.count) available"
        }
        lines.append(self.labelValueLine("Limit Reset Credits", value: value, useColor: useColor))
        guard let expiresAt = inventory.nextExpiringCredit?.expiresAt
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
            } else if provider == .claude,
                      plan.hasPrefix("Claude "),
                      ClaudePlan.fromCompatibilityLoginMethod(plan) != nil
            {
                plan
            } else {
                self.nonCodexPlanDisplay(provider: provider, plan: plan)
            }
            lines.append(self.labelValueLine("Plan", value: displayPlan, useColor: context.useColor))
        }

        for note in context.notes {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            lines.append(self.labelValueLine("Note", value: trimmed, useColor: context.useColor))
        }
    }

    private static func nonCodexPlanDisplay(provider: UsageProvider, plan: String) -> String {
        if provider == .gemini || provider == .mimo {
            return UsageFormatter.cleanPlanName(plan)
        }
        return plan.capitalized
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
        if self.usesDetailBackedWindow(provider: provider) {
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

    private static func usesDetailBackedWindow(provider: UsageProvider) -> Bool {
        switch provider {
        case .warp, .kilo, .mistral, .deepseek, .qoder, .crof:
            true
        default:
            false
        }
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
        if case .session = kind, let minutes = window.windowMinutes, minutes > 300 {
            return nil
        }
        if provider == .ollama, window.windowMinutes == nil {
            return nil
        }
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

    private static func paceSummary(
        provider: UsageProvider,
        for pace: UsagePace,
        kind: PaceKind,
        now: Date) -> String
    {
        let expected = Int(pace.expectedUsedPercent.rounded())
        var parts: [String] = []
        parts.append(Self.paceLeftLabel(for: pace))
        parts.append("Expected \(expected)% used")
        if let rightLabel = Self.paceRightLabel(provider: provider, for: pace, kind: kind, now: now) {
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
        return "\(label): \(self.paceSummary(provider: provider, for: pace, kind: kind, now: now))"
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
            summary: self.paceSummary(provider: provider, for: pace, kind: kind, now: now))
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

    private static func paceRightLabel(
        provider: UsageProvider,
        for pace: UsagePace,
        kind: PaceKind,
        now: Date) -> String?
    {
        if pace.willLastToReset {
            return self.combinedLastsLabel(for: pace, provider: provider)
        }
        guard let etaSeconds = pace.etaSeconds else { return nil }
        let etaText = Self.paceDurationText(seconds: etaSeconds, now: now)
        switch kind {
        case .session:
            return etaText == "now" ? "Projected empty now" : "Projected empty in \(etaText)"
        case .weekly:
            return etaText == "now" ? "Runs out now" : "Runs out in \(etaText)"
        }
    }

    private static func combinedLastsLabel(for pace: UsagePace, provider: UsageProvider) -> String {
        guard provider == .codex else { return "Lasts until reset" }
        guard let speedLabel = speedHintLabel(for: pace) else {
            return "Lasts until reset"
        }
        return "Lasts until reset | \(speedLabel)"
    }

    private static func speedHintLabel(for pace: UsagePace) -> String? {
        guard pace.deltaPercent < -15,
              let multiplier = pace.speedMultiplierToReset,
              multiplier >= 1.5
        else { return nil }
        return "1.5× headroom"
    }

    private static func paceDurationText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        if countdown == "now" {
            return "now"
        }
        if countdown.hasPrefix("in ") {
            return String(countdown.dropFirst(3))
        }
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
