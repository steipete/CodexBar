import CodexBarCore
import Foundation

enum UsagePaceText {
    struct WeeklyDetail {
        let leftLabel: String
        let rightLabel: String?
        let expectedUsedPercent: Double
        let stage: UsagePace.Stage
    }

    private enum DetailContext {
        case session
        case weekly
    }

    static func weeklySummary(provider: UsageProvider, pace: UsagePace, now: Date = .init()) -> String {
        let detail = self.weeklyDetail(provider: provider, pace: pace, now: now)
        if let rightLabel = detail.rightLabel {
            return L("Pace: %@ · %@", detail.leftLabel, rightLabel)
        }
        return L("Pace: %@", detail.leftLabel)
    }

    static func weeklyDetail(provider: UsageProvider, pace: UsagePace, now: Date = .init()) -> WeeklyDetail {
        WeeklyDetail(
            leftLabel: self.detailLeftLabel(for: pace),
            rightLabel: self.detailRightLabel(for: pace, provider: provider, context: .weekly, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    private static func detailLeftLabel(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        if deltaValue == 0 {
            return L("On pace")
        }
        switch pace.stage {
        case .onTrack:
            return L("On pace")
        case .slightlyAhead, .ahead, .farAhead:
            return L("%d%% in deficit", deltaValue)
        case .slightlyBehind, .behind, .farBehind:
            return L("%d%% in reserve", deltaValue)
        }
    }

    private static func detailRightLabel(
        for pace: UsagePace,
        provider: UsageProvider,
        context: DetailContext,
        now: Date) -> String?
    {
        let etaLabel: String?
        if pace.willLastToReset {
            etaLabel = self.combinedLastsLabel(for: pace, provider: provider)
        } else if let etaSeconds = pace.etaSeconds {
            let etaText = Self.durationText(seconds: etaSeconds, now: now)
            if context == .session {
                etaLabel = etaText == "now" ? L("Projected empty now") : L("Projected empty in %@", etaText)
            } else {
                etaLabel = etaText == "now" ? L("Runs out now") : L("Runs out in %@", etaText)
            }
        } else {
            etaLabel = nil
        }

        guard let runOutProbability = pace.runOutProbability else { return etaLabel }
        let roundedRisk = self.roundedRiskPercent(runOutProbability)
        let riskLabel = L("≈ %d%% run-out risk", roundedRisk)
        if pace.willLastToReset, roundedRisk > 0 {
            return riskLabel
        }
        if let etaLabel {
            return L("%@ · %@", etaLabel, riskLabel)
        }
        return riskLabel
    }

    private static func combinedLastsLabel(for pace: UsagePace, provider: UsageProvider) -> String {
        guard provider == .codex else { return L("Lasts until reset") }
        guard let speedLabel = self.speedHintLabel(for: pace) else {
            return L("Lasts until reset")
        }
        return L("%@ · %@", L("Lasts until reset"), speedLabel)
    }

    private static func speedHintLabel(for pace: UsagePace) -> String? {
        guard pace.deltaPercent < -15,
              let multiplier = pace.speedMultiplierToReset,
              multiplier >= 1.5
        else { return nil }
        return L("1.5× headroom")
    }

    private static func durationText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        if countdown == "now" { return "now" }
        if countdown.hasPrefix("in ") { return String(countdown.dropFirst(3)) }
        return countdown
    }

    private static func roundedRiskPercent(_ probability: Double) -> Int {
        let percent = probability.clamped(to: 0...1) * 100
        let rounded = (percent / 5).rounded() * 5
        return Int(rounded)
    }

    static func sessionPace(provider: UsageProvider, window: RateWindow, now: Date) -> UsagePace? {
        guard provider == .codex || provider == .claude || provider == .ollama || provider == .antigravity
        else { return nil }
        if provider == .ollama, window.windowMinutes == nil { return nil }
        if provider == .antigravity, let windowMinutes = window.windowMinutes, windowMinutes != 300 { return nil }
        guard window.remainingPercent > 0 else { return nil }
        guard let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300) else { return nil }
        guard pace.expectedUsedPercent >= 3 else { return nil }
        return pace
    }

    static func sessionDetail(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> WeeklyDetail? {
        guard let pace = sessionPace(provider: provider, window: window, now: now) else { return nil }
        return WeeklyDetail(
            leftLabel: Self.detailLeftLabel(for: pace),
            rightLabel: Self.detailRightLabel(for: pace, provider: provider, context: .session, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    static func sessionSummary(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> String? {
        guard let detail = sessionDetail(provider: provider, window: window, now: now) else { return nil }
        if let rightLabel = detail.rightLabel {
            return L("Pace: %@ · %@", detail.leftLabel, rightLabel)
        }
        return L("Pace: %@", detail.leftLabel)
    }
}
