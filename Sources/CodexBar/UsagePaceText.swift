import CodexBarCore
import Foundation

enum UsagePaceText {
    struct WeeklyDetail {
        let leftLabel: String
        let rightLabel: String?
        let expectedUsedPercent: Double
        let stage: UsagePace.Stage
    }

    static func weeklySummary(pace: UsagePace, now: Date = .init()) -> String {
        let detail = self.weeklyDetail(pace: pace, now: now)
        if let rightLabel = detail.rightLabel {
            return String(format: L("Pace: %@ · %@"), detail.leftLabel, rightLabel)
        }
        return String(format: L("Pace: %@"), detail.leftLabel)
    }

    static func weeklyDetail(pace: UsagePace, now: Date = .init()) -> WeeklyDetail {
        WeeklyDetail(
            leftLabel: self.detailLeftLabel(for: pace),
            rightLabel: self.detailRightLabel(for: pace, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    private static func detailLeftLabel(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        switch pace.stage {
        case .onTrack:
            return L("On pace")
        case .slightlyAhead, .ahead, .farAhead:
            return String(format: L("%d%% in deficit"), deltaValue)
        case .slightlyBehind, .behind, .farBehind:
            return String(format: L("%d%% in reserve"), deltaValue)
        }
    }

    private static func detailRightLabel(for pace: UsagePace, now: Date) -> String? {
        let etaLabel: String?
        if pace.willLastToReset {
            etaLabel = L("Lasts until reset")
        } else if let etaSeconds = pace.etaSeconds {
            let etaText = Self.durationText(seconds: etaSeconds, now: now)
            etaLabel = etaText == L("now") ? L("Runs out now") : String(format: L("Runs out in %@"), etaText)
        } else {
            etaLabel = nil
        }

        guard let runOutProbability = pace.runOutProbability else { return etaLabel }
        let roundedRisk = self.roundedRiskPercent(runOutProbability)
        let riskLabel = String(format: L("≈ %d%% run-out risk"), roundedRisk)
        if let etaLabel {
            return String(format: L("%@ · %@"), etaLabel, riskLabel)
        }
        return riskLabel
    }

    private static func durationText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = LocalizedUsageText.resetCountdownDescription(from: date, now: now)
        if countdown == L("now") { return L("now") }
        if countdown.hasPrefix("in ") { return String(countdown.dropFirst(3)) }
        return countdown
    }

    private static func roundedRiskPercent(_ probability: Double) -> Int {
        let percent = probability.clamped(to: 0...1) * 100
        let rounded = (percent / 5).rounded() * 5
        return Int(rounded)
    }

    static func sessionPace(provider: UsageProvider, window: RateWindow, now: Date) -> UsagePace? {
        guard provider == .codex || provider == .claude else { return nil }
        guard window.remainingPercent > 0 else { return nil }
        guard let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300) else { return nil }
        guard pace.expectedUsedPercent >= 3 else { return nil }
        return pace
    }

    static func sessionDetail(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> WeeklyDetail? {
        guard let pace = sessionPace(provider: provider, window: window, now: now) else { return nil }
        return WeeklyDetail(
            leftLabel: Self.detailLeftLabel(for: pace),
            rightLabel: Self.detailRightLabel(for: pace, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    static func sessionSummary(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> String? {
        guard let detail = sessionDetail(provider: provider, window: window, now: now) else { return nil }
        if let rightLabel = detail.rightLabel {
            return String(format: L("Pace: %@ · %@"), detail.leftLabel, rightLabel)
        }
        return String(format: L("Pace: %@"), detail.leftLabel)
    }
}
