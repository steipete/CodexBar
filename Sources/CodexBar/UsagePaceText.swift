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
            return String(localized: "Pace: \(detail.leftLabel) · \(rightLabel)")
        }
        return String(localized: "Pace: \(detail.leftLabel)")
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
            return String(localized: "On pace")
        case .slightlyAhead, .ahead, .farAhead:
            return String(localized: "\(deltaValue)% in deficit")
        case .slightlyBehind, .behind, .farBehind:
            return String(localized: "\(deltaValue)% in reserve")
        }
    }

    private static func detailRightLabel(for pace: UsagePace, now: Date) -> String? {
        let etaLabel: String?
        if pace.willLastToReset {
            etaLabel = String(localized: "Lasts until reset")
        } else if let etaSeconds = pace.etaSeconds {
            let etaText = Self.durationText(seconds: etaSeconds, now: now)
            etaLabel = etaText == "now" ? String(localized: "Runs out now") :
                String(localized: "Runs out in \(etaText)")
        } else {
            etaLabel = nil
        }

        guard let runOutProbability = pace.runOutProbability else { return etaLabel }
        let roundedRisk = self.roundedRiskPercent(runOutProbability)
        let riskLabel = String(localized: "≈ \(roundedRisk)% run-out risk")
        if let etaLabel {
            return "\(etaLabel) · \(riskLabel)"
        }
        return riskLabel
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
}
