import CodexBarCore
import Foundation

enum UsagePaceText {
    struct WeeklyDetail: Sendable {
        let leftLabel: String
        let rightLabel: String?
        let expectedUsedPercent: Double
        let stage: UsagePace.Stage
    }

    private static let minimumExpectedPercent: Double = 3

    static func weeklySummary(
        provider: UsageProvider,
        window: RateWindow,
        resetStyle: ResetTimeDisplayStyle = .countdown,
        now: Date = .init()) -> String?
    {
        guard let detail = weeklyDetail(provider: provider, window: window, resetStyle: resetStyle, now: now)
        else { return nil }
        if let rightLabel = detail.rightLabel {
            return "Pace: \(detail.leftLabel) · \(rightLabel)"
        }
        return "Pace: \(detail.leftLabel)"
    }

    static func weeklyDetail(
        provider: UsageProvider,
        window: RateWindow,
        resetStyle: ResetTimeDisplayStyle = .countdown,
        now: Date = .init()) -> WeeklyDetail?
    {
        guard let pace = weeklyPace(provider: provider, window: window, now: now) else { return nil }
        return WeeklyDetail(
            leftLabel: Self.detailLeftLabel(for: pace),
            rightLabel: Self.detailRightLabel(for: pace, now: now, resetStyle: resetStyle),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    private static func detailLeftLabel(for pace: UsagePace) -> String {
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

    private static func detailRightLabel(for pace: UsagePace, now: Date, resetStyle: ResetTimeDisplayStyle) -> String? {
        if pace.willLastToReset { return "Lasts until reset" }
        guard let etaSeconds = pace.etaSeconds else { return nil }
        let etaText = Self.durationText(seconds: etaSeconds, now: now, resetStyle: resetStyle)
        if resetStyle == .countdown {
            if etaText == "now" { return "Runs out now" }
            return "Runs out in \(etaText)"
        }
        return "Runs out at \(etaText)"
    }

    private static func durationText(seconds: TimeInterval, now: Date, resetStyle: ResetTimeDisplayStyle) -> String {
        let date = now.addingTimeInterval(seconds)
        if resetStyle == .absolute {
            return UsageFormatter.resetAbsoluteDescription(from: date, now: now)
        }
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        if countdown == "now" { return "now" }
        if countdown.hasPrefix("in ") { return String(countdown.dropFirst(3)) }
        return countdown
    }

    static func weeklyPace(provider: UsageProvider, window: RateWindow, now: Date) -> UsagePace? {
        guard provider == .codex || provider == .claude else { return nil }
        guard window.remainingPercent > 0 else { return nil }
        guard let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080) else { return nil }
        guard pace.expectedUsedPercent >= Self.minimumExpectedPercent else { return nil }
        return pace
    }
}
