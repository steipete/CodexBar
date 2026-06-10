import CodexBarCore
import SwiftUI

extension UsageMenuCardView.Model {
    struct PaceDetail {
        let leftLabel: String
        let rightLabel: String?
        let pacePercent: Double?
        let paceOnTop: Bool
    }

    var isOverviewErrorOnly: Bool {
        self.subtitleStyle == .error &&
            self.metrics.isEmpty &&
            self.usageNotes.isEmpty &&
            self.openAIAPIUsage == nil &&
            self.inlineUsageDashboard == nil &&
            self.creditsRemaining == nil &&
            self.providerCost == nil &&
            self.tokenUsage == nil &&
            self.placeholder == nil
    }

    var hasUsageContent: Bool {
        !self.metrics.isEmpty ||
            !self.usageNotes.isEmpty ||
            self.openAIAPIUsage != nil ||
            self.inlineUsageDashboard != nil ||
            self.placeholder != nil
    }

    var usesStackedDetailLayout: Bool {
        !self.metrics.isEmpty ||
            self.creditsText != nil ||
            self.providerCost != nil ||
            self.tokenUsage != nil
    }

    static func progressColor(for provider: UsageProvider) -> Color {
        if provider == .elevenlabs {
            return Color(nsColor: .labelColor)
        }

        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    static func resetText(
        for window: RateWindow,
        style: ResetTimeDisplayStyle,
        now: Date) -> String?
    {
        UsageFormatter.resetLine(for: window, style: style, now: now)
    }

    static func placeholder(input: Input) -> String? {
        if self.shouldShowRateLimitsUnavailablePlaceholder(input: input) {
            return L("Limits not available")
        }

        if input.snapshot == nil, !input.isRefreshing, input.lastError == nil {
            return self.hasLocalCodexTokenUsage(input) ? nil : L("No usage yet")
        }

        return nil
    }

    static func lastError(input: Input) -> String? {
        guard let lastError = input.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lastError.isEmpty
        else {
            return nil
        }
        if self.shouldShowRateLimitsUnavailablePlaceholder(input: input, lastError: lastError) {
            return nil
        }
        return lastError
    }

    private static func hasLocalCodexTokenUsage(_ input: Input) -> Bool {
        input.provider == .codex &&
            input.tokenCostUsageEnabled &&
            self.tokenUsageSnapshot(input: input) != nil
    }

    private static func shouldShowRateLimitsUnavailablePlaceholder(input: Input, lastError: String? = nil) -> Bool {
        let currentError = lastError ?? input.lastError
        if let currentError = currentError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentError.isEmpty,
           !UsageError.isNoRateLimitsFoundDescription(currentError)
        {
            return false
        }
        return self.rateLimitsUnavailable(input: input, lastError: currentError)
    }

    private static func rateLimitsUnavailable(input: Input, lastError: String? = nil) -> Bool {
        UsageLimitsAvailability.resolve(
            provider: input.provider,
            snapshot: input.snapshot,
            account: input.account,
            lastErrorDescription: lastError ?? input.lastError)
            .isUnavailable
    }

    static func sessionPaceDetail(
        provider: UsageProvider,
        window: RateWindow,
        now: Date,
        showUsed: Bool) -> PaceDetail?
    {
        guard let detail = UsagePaceText.sessionDetail(provider: provider, window: window, now: now) else { return nil }
        let expectedUsed = detail.expectedUsedPercent
        let actualUsed = window.usedPercent
        let expectedPercent = showUsed ? expectedUsed : (100 - expectedUsed)
        let actualPercent = showUsed ? actualUsed : (100 - actualUsed)
        if expectedPercent.isFinite == false || actualPercent.isFinite == false { return nil }
        let paceOnTop = actualUsed <= expectedUsed
        let pacePercent: Double? = if detail.stage == .onTrack { nil } else { expectedPercent }
        return PaceDetail(
            leftLabel: detail.leftLabel,
            rightLabel: detail.rightLabel,
            pacePercent: pacePercent,
            paceOnTop: paceOnTop)
    }

    static func weeklyPaceDetail(
        window: RateWindow,
        now: Date,
        pace: UsagePace?,
        showUsed: Bool) -> PaceDetail?
    {
        guard let pace else { return nil }
        let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)
        let expectedUsed = detail.expectedUsedPercent
        let actualUsed = window.usedPercent
        let expectedPercent = showUsed ? expectedUsed : (100 - expectedUsed)
        let actualPercent = showUsed ? actualUsed : (100 - actualUsed)
        if expectedPercent.isFinite == false || actualPercent.isFinite == false { return nil }
        let paceOnTop = actualUsed <= expectedUsed
        let pacePercent: Double? = if detail.stage == .onTrack { nil } else { expectedPercent }
        return PaceDetail(
            leftLabel: detail.leftLabel,
            rightLabel: detail.rightLabel,
            pacePercent: pacePercent,
            paceOnTop: paceOnTop)
    }

    static func cursorBillingCyclePaceDetail(
        window: RateWindow,
        input: Input,
        pace: UsagePace? = nil) -> PaceDetail?
    {
        guard input.provider == .cursor,
              window.windowMinutes != nil
        else { return nil }
        let resolved = pace ?? UsagePace.weekly(window: window, now: input.now, defaultWindowMinutes: 10080)
        guard let resolved,
              resolved.expectedUsedPercent >= 3
        else { return nil }
        return Self.weeklyPaceDetail(
            window: window,
            now: input.now,
            pace: resolved,
            showUsed: input.usageBarsShowUsed)
    }

    static func antigravityMetrics(input: Input, snapshot: UsageSnapshot) -> [Metric] {
        let percentStyle: PercentStyle = input.usageBarsShowUsed ? .used : .left
        var metrics = [
            Self.antigravityMetric(
                id: "primary",
                title: L(input.metadata.sessionLabel),
                window: snapshot.primary,
                input: input,
                percentStyle: percentStyle),
            Self.antigravityMetric(
                id: "secondary",
                title: L(input.metadata.weeklyLabel),
                window: snapshot.secondary,
                input: input,
                percentStyle: percentStyle),
            Self.antigravityMetric(
                id: "tertiary",
                title: input.metadata.opusLabel.map(L) ?? L("Gemini Flash"),
                window: snapshot.tertiary,
                input: input,
                percentStyle: percentStyle),
        ]
        metrics.append(contentsOf: Self.extraRateWindowMetrics(
            snapshot: snapshot,
            input: input,
            percentStyle: percentStyle))
        return metrics
    }

    static func extraRateWindowMetrics(
        snapshot: UsageSnapshot,
        input: Input,
        percentStyle: PercentStyle) -> [Metric]
    {
        guard let extraRateWindows = snapshot.extraRateWindows else { return [] }
        // Codex additional limits (e.g. Codex Spark) are optional extra usage and follow the
        // "optional credits and extra usage" setting. Other providers' extra windows (Antigravity
        // per-model quotas, Factory core windows, etc.) are core data and must always render.
        if input.provider == .codex, !input.showOptionalCreditsAndExtraUsage {
            return []
        }
        return extraRateWindows.map { namedWindow in
            let paceDetail = Self.extraRateWindowPaceDetail(
                provider: input.provider,
                window: namedWindow.window,
                input: input)
            return Metric(
                id: namedWindow.id,
                title: namedWindow.title,
                percent: Self.clamped(
                    input.usageBarsShowUsed
                        ? namedWindow.window.usedPercent
                        : namedWindow.window.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(
                    for: namedWindow.window,
                    style: input.resetTimeDisplayStyle,
                    now: input.now),
                detailText: nil,
                detailLeftText: paceDetail?.leftLabel,
                detailRightText: paceDetail?.rightLabel,
                pacePercent: paceDetail?.pacePercent,
                paceOnTop: paceDetail?.paceOnTop ?? true)
        }
    }

    private static func extraRateWindowPaceDetail(
        provider: UsageProvider,
        window: RateWindow,
        input: Input) -> PaceDetail?
    {
        guard provider == .codex else { return nil }
        switch window.windowMinutes {
        case 300:
            return self.sessionPaceDetail(
                provider: provider,
                window: window,
                now: input.now,
                showUsed: input.usageBarsShowUsed)
        case 10080:
            let pace = UsagePace.weekly(window: window, now: input.now, defaultWindowMinutes: 10080)
                .flatMap { $0.expectedUsedPercent >= 3 ? $0 : nil }
            return Self.weeklyPaceDetail(
                window: window,
                now: input.now,
                pace: pace,
                showUsed: input.usageBarsShowUsed)
        default:
            return nil
        }
    }

    static func antigravityMetric(
        id: String,
        title: String,
        window: RateWindow?,
        input: Input,
        percentStyle: PercentStyle) -> Metric
    {
        guard let window else {
            let placeholderPercent = input.usageBarsShowUsed ? 100.0 : 0.0
            return Metric(
                id: id,
                title: title,
                percent: placeholderPercent,
                percentStyle: percentStyle,
                statusText: nil,
                resetText: nil,
                detailText: nil,
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true)
        }
        let percent = input.usageBarsShowUsed ? window.usedPercent : window.remainingPercent
        return Metric(
            id: id,
            title: title,
            percent: Self.clamped(percent),
            percentStyle: percentStyle,
            resetText: Self.resetText(for: window, style: input.resetTimeDisplayStyle, now: input.now),
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true)
    }

    static func zaiLimitDetailText(limit: ZaiLimitEntry?) -> String? {
        guard let limit else { return nil }

        if let currentValue = limit.currentValue,
           let usage = limit.usage,
           let remaining = limit.remaining
        {
            let currentStr = UsageFormatter.tokenCountString(currentValue)
            let usageStr = UsageFormatter.tokenCountString(usage)
            let remainingStr = UsageFormatter.tokenCountString(remaining)
            return String(format: L("%@ / %@ (%@ remaining)"), currentStr, usageStr, remainingStr)
        }

        return nil
    }

    static func openRouterQuotaDetail(provider: UsageProvider, snapshot: UsageSnapshot) -> String? {
        guard provider == .openrouter,
              let usage = snapshot.openRouterUsage,
              usage.hasValidKeyQuota,
              let keyRemaining = usage.keyRemaining,
              let keyLimit = usage.keyLimit
        else {
            return nil
        }

        let remaining = UsageFormatter.usdString(keyRemaining)
        let limit = UsageFormatter.usdString(keyLimit)
        return String(format: L("%@/%@ left"), remaining, limit)
    }

    static func syntheticRegenDetail(
        weekly: RateWindow,
        cost: ProviderCostSnapshot?,
        now: Date,
        showUsed: Bool) -> (resetText: String, pace: PaceDetail)?
    {
        guard let cost,
              cost.limit > 0,
              let nextRegenAmount = cost.nextRegenAmount,
              nextRegenAmount > 0,
              let resetsAt = weekly.resetsAt
        else { return nil }

        let countdown = UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
        let resetText = String(format: L("Regenerates %@"), countdown)

        let nextRegenPercent = (nextRegenAmount / cost.limit) * 100
        let afterNextRegenRemaining = min(100, weekly.remainingPercent + nextRegenPercent)
        let afterNextRegen = showUsed ? max(0, 100 - afterNextRegenRemaining) : afterNextRegenRemaining
        let suffix = showUsed ? L("used after next regen") : L("after next regen")
        let ticksToFull = max(0, cost.used) / nextRegenAmount
        let left = String(format: "%.0f%% %@", afterNextRegen, suffix)
        let right = if ticksToFull <= 0.1 {
            L("Near full")
        } else if ticksToFull < 1.5 {
            L("Full in ~1 regen")
        } else {
            String(format: L("Full in ~%.0f regens"), ceil(ticksToFull))
        }
        return (resetText, PaceDetail(leftLabel: left, rightLabel: right, pacePercent: nil, paceOnTop: true))
    }

    static func syntheticRollingRegenDetail(
        window: RateWindow,
        now: Date,
        showUsed: Bool) -> (resetText: String, pace: PaceDetail)?
    {
        guard let resetsAt = window.resetsAt,
              let nextRegenPercent = window.nextRegenPercent,
              nextRegenPercent > 0
        else { return nil }

        let countdown = UsageFormatter.resetCountdownDescription(from: resetsAt, now: now)
        let resetText = String(format: L("Regenerates %@"), countdown)

        let afterNextRegenRemaining = min(100, window.remainingPercent + nextRegenPercent)
        let afterNextRegen = showUsed ? max(0, 100 - afterNextRegenRemaining) : afterNextRegenRemaining
        let suffix = showUsed ? L("used after next regen") : L("after next regen")
        let left = String(format: "%.0f%% %@", afterNextRegen, suffix)

        let missingPercent = max(0, window.usedPercent)
        let ticksToFull = missingPercent / nextRegenPercent
        let right = if ticksToFull <= 0.1 {
            L("Near full")
        } else if ticksToFull < 1.5 {
            L("Full in ~1 regen")
        } else {
            String(format: L("Full in ~%.0f regens"), ceil(ticksToFull))
        }

        return (resetText, PaceDetail(leftLabel: left, rightLabel: right, pacePercent: nil, paceOnTop: true))
    }
}
