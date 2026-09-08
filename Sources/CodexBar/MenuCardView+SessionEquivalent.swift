import CodexBarCore

extension UsageMenuCardView.Model {
    static func sessionEquivalentDetail(
        input: Input,
        weeklyWindow: RateWindow,
        weeklyWindowID: String?) -> UsagePaceText.SessionEquivalentDetail?
    {
        guard let forecast = input.sessionEquivalentForecast,
              forecast.applies(to: weeklyWindow, windowID: weeklyWindowID)
        else {
            return nil
        }
        return UsagePaceText.sessionEquivalentDetail(forecast: forecast)
    }

    static func codexRateMetrics(
        input: Input,
        projection: CodexConsumerProjection,
        percentStyle: PercentStyle) -> [Metric]
    {
        projection.displayedRateLanes(
            showOptionalCreditsAndExtraUsage: input.showOptionalCreditsAndExtraUsage).compactMap { lane in
            guard let window = projection.rateWindow(for: lane) else { return nil }

            let title = CodexConsumerProjection.rateTitle(
                lane: lane,
                windowMinutes: window.windowMinutes,
                sessionLabel: input.metadata.sessionLabel,
                weeklyLabel: input.metadata.weeklyLabel)
            let id: String
            let paceDetail: PaceDetail?
            switch lane {
            case .session:
                id = "primary"
                // UsagePaceText.sessionPace suppresses weekly/monthly durations centrally;
                // unknown durations in the session lane keep their existing pace.
                paceDetail = Self.sessionPaceDetail(
                    provider: input.provider,
                    window: window,
                    now: input.now,
                    showUsed: input.usageBarsShowUsed)
            case .weekly:
                id = "secondary"
                paceDetail = Self.weeklyPaceDetail(
                    provider: input.provider,
                    window: window,
                    now: input.now,
                    pace: Self.standardWeeklyPace(input: input, window: window),
                    showUsed: input.usageBarsShowUsed)
            case .monthly:
                id = "monthly"
                paceDetail = nil
            }
            let monthlyDetail = Self.codexMonthlyCreditDetail(lane: lane, window: window, input: input)
            let workdayMarkerPercents: [Double] = if lane == .weekly, input.workdayTickAppearance != .hidden {
                workDayMarkerPercents(
                    workDays: input.workDaysPerWeek,
                    windowMinutes: window.windowMinutes)
            } else {
                []
            }

            return Metric(
                id: id,
                title: title,
                percent: Self.clamped(input.usageBarsShowUsed ? window.usedPercent : window.remainingPercent),
                percentStyle: percentStyle,
                resetText: Self.resetText(for: window, style: input.resetTimeDisplayStyle, now: input.now),
                detailText: monthlyDetail,
                detailLeftText: paceDetail?.leftLabel,
                detailRightText: paceDetail?.rightLabel,
                pacePercent: paceDetail?.pacePercent,
                detailIsPaceDerived: paceDetail?.isPaceDerived ?? false,
                paceOnTop: paceDetail?.paceOnTop ?? true,
                warningMarkerPercents: Self.warningMarkerPercents(
                    thresholds: lane.quotaWarningWindow.flatMap { input.quotaWarningThresholds[$0] },
                    showUsed: input.usageBarsShowUsed),
                workdayMarkerPercents: workdayMarkerPercents,
                workdayTickAppearance: input.workdayTickAppearance,
                sessionEquivalentDetail: lane == .weekly
                    ? Self.sessionEquivalentDetail(input: input, weeklyWindow: window, weeklyWindowID: nil)
                    : nil)
        }
    }

    private static func codexMonthlyCreditDetail(
        lane: CodexConsumerProjection.RateLane, window: RateWindow, input: Input) -> String?
    {
        guard lane == .monthly, window.windowMinutes == nil else { return nil }
        let cost = input.codexProjection?.extraUsageCost ?? CodexExtraUsageCost.providerCost(from: input.credits)
        guard let cost, cost.limit > 0 else { return nil }
        let used = UsageFormatter.creditsNumberString(from: cost.used)
        let limit = UsageFormatter.creditsNumberString(from: cost.limit)
        return "\(used) / \(limit)"
    }
}
