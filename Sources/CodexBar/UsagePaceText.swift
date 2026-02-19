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

    static func weeklySummary(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> String? {
        guard let detail = weeklyDetail(provider: provider, window: window, now: now) else { return nil }
        if let rightLabel = detail.rightLabel {
            return L10n.format("Pace: %@ · %@", detail.leftLabel, rightLabel)
        }
        return L10n.format("Pace: %@", detail.leftLabel)
    }

    static func weeklyDetail(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> WeeklyDetail? {
        guard let pace = weeklyPace(provider: provider, window: window, now: now) else { return nil }
        return WeeklyDetail(
            leftLabel: Self.detailLeftLabel(for: pace),
            rightLabel: Self.detailRightLabel(for: pace, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    private static func detailLeftLabel(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        switch pace.stage {
        case .onTrack:
            return L10n.tr("On pace")
        case .slightlyAhead, .ahead, .farAhead:
            return L10n.format("%d%% in deficit", deltaValue)
        case .slightlyBehind, .behind, .farBehind:
            return L10n.format("%d%% in reserve", deltaValue)
        }
    }

    private static func detailRightLabel(for pace: UsagePace, now: Date) -> String? {
        if pace.willLastToReset { return L10n.tr("Lasts until reset") }
        guard let etaSeconds = pace.etaSeconds else { return nil }
        let etaText = Self.durationText(seconds: etaSeconds, now: now)
        if etaText == L10n.tr("now") { return L10n.tr("Runs out now") }
        return L10n.format("Runs out in %@", etaText)
    }

    private static func durationText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        if countdown == "now" { return L10n.tr("now") }
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
