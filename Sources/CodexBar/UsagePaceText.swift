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
    private static let weeklyWindowMinutes = 7 * 24 * 60
    private static let weeklyWindowToleranceMinutes = 24 * 60

    static func weeklySummary(
        provider: UsageProvider,
        window: RateWindow,
        now: Date = .init(),
        profile: UsagePaceProfile? = nil) -> String?
    {
        guard let detail = weeklyDetail(provider: provider, window: window, now: now, profile: profile) else {
            return nil
        }
        if let rightLabel = detail.rightLabel {
            return "Pace: \(detail.leftLabel) · \(rightLabel)"
        }
        return "Pace: \(detail.leftLabel)"
    }

    static func weeklyDetail(
        provider: UsageProvider,
        window: RateWindow,
        now: Date = .init(),
        profile: UsagePaceProfile? = nil) -> WeeklyDetail?
    {
        guard let pace = weeklyPace(provider: provider, window: window, now: now, profile: profile) else {
            return nil
        }
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
            return "On pace"
        case .slightlyAhead, .ahead, .farAhead:
            return "\(deltaValue)% in deficit"
        case .slightlyBehind, .behind, .farBehind:
            return "\(deltaValue)% in reserve"
        }
    }

    private static func detailRightLabel(for pace: UsagePace, now: Date) -> String? {
        let runwayLabel: String? = {
            if pace.willLastToReset { return "Lasts until reset" }
            guard let etaSeconds = pace.etaSeconds else { return nil }
            let etaText = Self.durationText(seconds: etaSeconds, now: now)
            if etaText == "now" { return "Runs out now" }
            return "Runs out in \(etaText)"
        }()

        let confidenceLabel: String? = if pace.confidence == .low, pace.isFallbackLinear {
            "Low confidence"
        } else {
            nil
        }

        if let runwayLabel, let confidenceLabel {
            return "\(runwayLabel) · \(confidenceLabel)"
        }
        return runwayLabel ?? confidenceLabel
    }

    private static func durationText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        if countdown == "now" { return "now" }
        if countdown.hasPrefix("in ") { return String(countdown.dropFirst(3)) }
        return countdown
    }

    static func weeklyPace(
        provider _: UsageProvider,
        window: RateWindow,
        now: Date,
        profile: UsagePaceProfile? = nil) -> UsagePace?
    {
        guard window.remainingPercent > 0 else { return nil }
        guard self.isWeeklyWindow(window) else { return nil }
        guard let pace = UsagePace.weekly(
            window: window,
            now: now,
            defaultWindowMinutes: weeklyWindowMinutes,
            profile: profile)
        else {
            return nil
        }
        guard pace.expectedUsedPercent >= Self.minimumExpectedPercent else { return nil }
        return pace
    }

    static func isWeeklyWindow(_ window: RateWindow) -> Bool {
        guard let minutes = window.windowMinutes else {
            return false
        }
        let delta = abs(minutes - Self.weeklyWindowMinutes)
        return delta <= Self.weeklyWindowToleranceMinutes
    }
}
