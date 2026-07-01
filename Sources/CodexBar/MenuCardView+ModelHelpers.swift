import CodexBarCore
import SwiftUI

extension UsageMenuCardView.Model {
    struct PaceDetail {
        let leftLabel: String
        let rightLabel: String?
        let pacePercent: Double?
        let paceOnTop: Bool
    }

    static func redactedMetricDetail(_ detail: String?, provider: UsageProvider, metricID: String) -> String? {
        guard let detail else { return nil }
        guard provider == .litellm,
              metricID == "secondary",
              detail.hasPrefix("Team "),
              let separator = detail.range(of: ": ", options: .backwards)
        else {
            return PersonalInfoRedactor.redactEmails(in: detail, isEnabled: true)
        }
        return PersonalInfoRedactor.redactEmails(in: "Team\(detail[separator.lowerBound...])", isEnabled: true)
    }

    static func redactedMetrics(
        _ metrics: [Metric],
        provider: UsageProvider,
        hidePersonalInfo: Bool) -> [Metric]
    {
        guard hidePersonalInfo else { return metrics }
        return metrics.map { metric in
            Metric(
                id: metric.id,
                title: PersonalInfoRedactor.redactEmails(in: metric.title, isEnabled: true) ?? metric.title,
                percent: metric.percent,
                percentStyle: metric.percentStyle,
                statusText: PersonalInfoRedactor.redactEmails(in: metric.statusText, isEnabled: true),
                resetText: PersonalInfoRedactor.redactEmails(in: metric.resetText, isEnabled: true),
                detailText: Self.redactedMetricDetail(
                    metric.detailText,
                    provider: provider,
                    metricID: metric.id),
                detailLeftText: PersonalInfoRedactor.redactEmails(in: metric.detailLeftText, isEnabled: true),
                detailRightText: PersonalInfoRedactor.redactEmails(in: metric.detailRightText, isEnabled: true),
                pacePercent: metric.pacePercent,
                paceOnTop: metric.paceOnTop,
                warningMarkerPercents: metric.warningMarkerPercents,
                cardStyle: metric.cardStyle)
        }
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
            self.codexResetCreditsText != nil ||
            self.placeholder != nil
    }

    var usesStackedDetailLayout: Bool {
        !self.metrics.isEmpty ||
            self.creditsText != nil ||
            self.codexResetCreditsText != nil ||
            self.providerCost != nil ||
            self.tokenUsage != nil
    }

    func hasCompatibleTrackedLayout(with candidate: Self) -> Bool {
        self.hasCompatibleTrackedLayout(with: candidate, includeMetrics: true)
    }

    func hasCompatibleTrackedLayoutIgnoringMetrics(with candidate: Self) -> Bool {
        self.hasCompatibleTrackedLayout(with: candidate, includeMetrics: false)
    }

    func hasCompatibleTrackedMetricSubset(of candidate: Self) -> Bool {
        guard self.metrics.count < candidate.metrics.count,
              self.hasCompatibleTrackedLayoutIgnoringMetrics(with: candidate)
        else {
            return false
        }
        return self.metrics.allSatisfy { metric in
            candidate.metrics.contains { Self.hasCompatibleMetricLayout(metric, $0) }
        }
    }

    private func hasCompatibleTrackedLayout(with candidate: Self, includeMetrics: Bool) -> Bool {
        guard self.provider == candidate.provider,
              !includeMetrics || self.metrics.count == candidate.metrics.count,
              self.usageNotes == candidate.usageNotes,
              (self.openAIAPIUsage == nil) == (candidate.openAIAPIUsage == nil),
              Self.hasCompatibleCreditsLayout(
                  currentText: self.creditsText,
                  currentRemaining: self.creditsRemaining,
                  candidateText: candidate.creditsText,
                  candidateRemaining: candidate.creditsRemaining),
              self.creditsHintText == candidate.creditsHintText,
              self.codexResetCreditsText == candidate.codexResetCreditsText,
              self.codexResetCreditsDetailText == candidate.codexResetCreditsDetailText,
              self.placeholder == candidate.placeholder,
              Self.hasCompatibleDashboardLayout(self.inlineUsageDashboard, candidate.inlineUsageDashboard),
              Self.hasCompatibleProviderCostLayout(self.providerCost, candidate.providerCost),
              Self.hasCompatibleTokenUsageLayout(self.tokenUsage, candidate.tokenUsage)
        else {
            return false
        }

        guard includeMetrics else { return true }
        return zip(self.metrics, candidate.metrics).allSatisfy(Self.hasCompatibleMetricLayout)
    }

    private static func hasCompatibleMetricLayout(_ current: Metric, _ candidate: Metric) -> Bool {
        current.id == candidate.id &&
            current.title == candidate.title &&
            current.percentStyle == candidate.percentStyle &&
            (current.statusText == nil) == (candidate.statusText == nil) &&
            (current.resetText == nil) == (candidate.resetText == nil) &&
            (current.detailText == nil) == (candidate.detailText == nil) &&
            (current.detailLeftText == nil) == (candidate.detailLeftText == nil) &&
            (current.detailRightText == nil) == (candidate.detailRightText == nil) &&
            current.cardStyle == candidate.cardStyle
    }

    private static func hasCompatibleCreditsLayout(
        currentText: String?,
        currentRemaining: Double?,
        candidateText: String?,
        candidateRemaining: Double?) -> Bool
    {
        switch (currentText, candidateText) {
        case (nil, nil):
            return true
        case let (currentText?, candidateText?):
            guard (currentRemaining == nil) == (candidateRemaining == nil) else { return false }
            // Numeric balances render as a fixed single line beside the full-scale label.
            // Multiline workspace balances retain their measured text until the menu reopens.
            return currentRemaining != nil || currentText == candidateText
        default:
            return false
        }
    }

    private static func hasCompatibleDashboardLayout(
        _ current: InlineUsageDashboardModel?,
        _ candidate: InlineUsageDashboardModel?) -> Bool
    {
        switch (current, candidate) {
        case (nil, nil):
            true
        case let (current?, candidate?):
            current.valueStyle == candidate.valueStyle &&
                current.kpis.count == candidate.kpis.count &&
                current.points.count == candidate.points.count &&
                current.detailLines.count == candidate.detailLines.count &&
                zip(current.kpis, candidate.kpis).allSatisfy {
                    $0.title == $1.title && $0.emphasis == $1.emphasis
                } &&
                zip(current.points, candidate.points).allSatisfy {
                    $0.id == $1.id && $0.label == $1.label
                }
        default:
            false
        }
    }

    private static func hasCompatibleProviderCostLayout(
        _ current: ProviderCostSection?,
        _ candidate: ProviderCostSection?) -> Bool
    {
        switch (current, candidate) {
        case (nil, nil):
            true
        case let (current?, candidate?):
            current.title == candidate.title &&
                (current.percentUsed == nil) == (candidate.percentUsed == nil) &&
                (current.percentLine == nil) == (candidate.percentLine == nil) &&
                (current.personalSpendLine == nil) == (candidate.personalSpendLine == nil)
        default:
            false
        }
    }

    private static func hasCompatibleTokenUsageLayout(
        _ current: TokenUsageSection?,
        _ candidate: TokenUsageSection?) -> Bool
    {
        switch (current, candidate) {
        case (nil, nil):
            true
        case let (current?, candidate?):
            current.hintLine == candidate.hintLine &&
                current.errorLine == candidate.errorLine
        default:
            false
        }
    }

    static func progressColor(for provider: UsageProvider) -> Color {
        if provider == .elevenlabs {
            return Color(nsColor: .labelColor)
        }

        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    static func rateWindowLabels(
        input: Input,
        snapshot: UsageSnapshot) -> (primary: String, secondary: String, tertiary: String, showsTertiary: Bool)
    {
        if input.provider == .factory, snapshot.tertiary != nil {
            return ("5-hour", L("Weekly"), L("Monthly"), true)
        }
        // Legacy request-based Cursor plans track a request quota, not the token-based "Total" pool.
        let primaryLabel = if input.provider == .cursor, snapshot.cursorRequests != nil {
            "Requests"
        } else if input.provider == .grok {
            GrokProviderDescriptor.primaryLabel(window: snapshot.primary) ?? input.metadata.sessionLabel
        } else {
            input.metadata.sessionLabel
        }
        return (
            L(primaryLabel),
            L(input.metadata.weeklyLabel),
            input.metadata.opusLabel.map(L) ?? L("Sonnet"),
            input.metadata.supportsOpus)
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

    static func dashboardHint(error: String?) -> String? {
        guard let error, !error.isEmpty else { return nil }
        return error
    }

    static func mimoUsageNotes(input: Input, subscriptionNotes: [String]) -> [String] {
        let source = input.sourceLabel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard source != "local" else { return [] }
        return [
            L("Balance updates in near-real time (up to 5 min lag)"),
            L("Daily billing data finalizes at 07:00 UTC"),
        ] + subscriptionNotes
    }

    static func subscriptionMetadataNotes(snapshot: UsageSnapshot?, provider: UsageProvider) -> [String] {
        guard let snapshot else { return [] }
        if let renewsAt = snapshot.subscriptionRenewsAt {
            return [String(format: L("Renews: %@"), self.subscriptionDateString(renewsAt, provider: provider))]
        }
        if let expiresAt = snapshot.subscriptionExpiresAt {
            return [String(format: L("Plan expires: %@"), self.subscriptionDateString(expiresAt, provider: provider))]
        }
        return []
    }

    private static func subscriptionDateString(_ date: Date, provider: UsageProvider) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = self.subscriptionDateTimeZone(provider: provider)
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter.string(from: date)
    }

    private static func subscriptionDateTimeZone(provider: UsageProvider) -> TimeZone {
        switch provider {
        case .minimax:
            TimeZone(identifier: "Asia/Shanghai") ?? .current
        default:
            .current
        }
    }

    static func poeBalanceDetailText(input: Input) -> String? {
        guard input.provider == .poe else { return nil }
        return StatusItemController.poeBalanceDisplayText(snapshot: input.snapshot)
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

    static func standardWeeklyPace(input: Input, window: RateWindow) -> UsagePace? {
        if let weeklyPace = input.weeklyPace {
            return weeklyPace
        }
        return Self.displayableWeeklyPace(UsagePace.weekly(
            window: window,
            now: input.now,
            defaultWindowMinutes: 10080,
            workDays: input.workDaysPerWeek))
    }

    private static func displayableWeeklyPace(_ pace: UsagePace?) -> UsagePace? {
        guard let pace else { return nil }
        return pace.expectedUsedPercent >= 3 || pace.etaSeconds == 0 ? pace : nil
    }

    static func cursorBillingCyclePaceDetail(
        window: RateWindow,
        input: Input,
        pace: UsagePace? = nil) -> PaceDetail?
    {
        guard input.provider == .cursor,
              window.windowMinutes != nil
        else { return nil }
        let resolved = pace ?? UsagePace.weekly(
            window: window,
            now: input.now,
            defaultWindowMinutes: 10080,
            workDays: input.workDaysPerWeek)
        guard let resolved = Self.displayableWeeklyPace(resolved) else { return nil }
        return Self.weeklyPaceDetail(
            window: window,
            now: input.now,
            pace: resolved,
            showUsed: input.usageBarsShowUsed)
    }

    static func antigravityMetrics(input: Input, snapshot: UsageSnapshot) -> [Metric] {
        let percentStyle: PercentStyle = input.usageBarsShowUsed ? .used : .left
        if Self.hasAntigravityQuotaSummaryWindows(snapshot) {
            return Self.extraRateWindowMetrics(
                snapshot: snapshot,
                input: input,
                percentStyle: percentStyle)
        }

        var metrics: [Metric] = []
        if let primary = snapshot.primary {
            metrics.append(Self.antigravityMetric(
                id: "primary",
                title: L(input.metadata.sessionLabel),
                window: primary,
                input: input,
                percentStyle: percentStyle))
        }
        if let secondary = snapshot.secondary {
            metrics.append(Self.antigravityMetric(
                id: "secondary",
                title: L(input.metadata.weeklyLabel),
                window: secondary,
                input: input,
                percentStyle: percentStyle))
        }
        if input.metadata.supportsOpus, let tertiary = snapshot.tertiary {
            metrics.append(Self.antigravityMetric(
                id: "tertiary",
                title: input.metadata.opusLabel.map(L) ?? L("Gemini Flash"),
                window: tertiary,
                input: input,
                percentStyle: percentStyle))
        }
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
        if input.provider == .copilot, !input.copilotBudgetExtrasEnabled {
            return []
        }
        return extraRateWindows.map { namedWindow in
            let paceDetail = Self.extraRateWindowPaceDetail(
                provider: input.provider,
                window: namedWindow.window,
                input: input)
            let usageKnown = namedWindow.usageKnown
            let resetText = Self.extraRateWindowResetText(
                namedWindow: namedWindow,
                input: input)
            let statusText: String? = if usageKnown {
                nil
            } else if let resetText {
                "\(L("Unavailable")) - \(resetText)"
            } else {
                L("Unavailable")
            }
            return Metric(
                id: namedWindow.id,
                title: namedWindow.title,
                percent: Self.clamped(
                    input.usageBarsShowUsed
                        ? namedWindow.window.usedPercent
                        : namedWindow.window.remainingPercent),
                percentStyle: percentStyle,
                statusText: statusText,
                resetText: usageKnown ? resetText : nil,
                detailText: nil,
                detailLeftText: usageKnown ? paceDetail?.leftLabel : nil,
                detailRightText: usageKnown ? paceDetail?.rightLabel : nil,
                pacePercent: usageKnown ? paceDetail?.pacePercent : nil,
                paceOnTop: paceDetail?.paceOnTop ?? true)
        }
    }

    private static let antigravityQuotaSummaryWindowIDPrefix = "antigravity-quota-summary-"

    private static func hasAntigravityQuotaSummaryWindows(_ snapshot: UsageSnapshot) -> Bool {
        snapshot.extraRateWindows?.contains(where: self.isAntigravityQuotaSummaryWindow) == true
    }

    private static func isAntigravityQuotaSummaryWindow(_ namedWindow: NamedRateWindow) -> Bool {
        namedWindow.id.hasPrefix(self.antigravityQuotaSummaryWindowIDPrefix)
    }

    private static func extraRateWindowResetText(
        namedWindow: NamedRateWindow,
        input: Input) -> String?
    {
        if namedWindow.window.resetsAt != nil {
            return self.resetText(
                for: namedWindow.window,
                style: input.resetTimeDisplayStyle,
                now: input.now)
        }
        if input.provider == .antigravity,
           self.isAntigravityQuotaSummaryWindow(namedWindow)
        {
            return self.antigravityQuotaSummaryResetText(namedWindow.window.resetDescription)
        }
        return self.resetText(
            for: namedWindow.window,
            style: input.resetTimeDisplayStyle,
            now: input.now)
    }

    private static func antigravityQuotaSummaryResetText(_ description: String?) -> String? {
        guard let description = description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty
        else { return nil }

        if let range = description.range(of: "fully refresh in ", options: .caseInsensitive) {
            var suffix = String(description[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while suffix.last == "." {
                suffix.removeLast()
            }
            guard !suffix.isEmpty else { return description }
            return String(format: L("Resets in %@"), suffix)
        }

        return description
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
            let pace = Self.displayableWeeklyPace(UsagePace.weekly(
                window: window,
                now: input.now,
                defaultWindowMinutes: 10080,
                workDays: input.workDaysPerWeek))
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
