import CodexBarCore
import Foundation

enum UsagePaceText {
    static func weekly(provider: UsageProvider, window: RateWindow, now: Date = .init()) -> String? {
        guard provider == .codex || provider == .claude else { return nil }
        guard let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 10080) else { return nil }

        let label = Self.label(for: pace.stage)
        let deltaSuffix = Self.deltaSuffix(for: pace)
        let etaSuffix = Self.etaSuffix(for: pace, now: now)

        if let etaSuffix {
            return "Pace: \(label)\(deltaSuffix) · \(etaSuffix)"
        }
        return "Pace: \(label)\(deltaSuffix)"
    }

    private static func label(for stage: UsagePace.Stage) -> String {
        switch stage {
        case .onTrack: "On track"
        case .slightlyAhead, .ahead, .farAhead: "High"
        case .slightlyBehind, .behind, .farBehind: "Low"
        }
    }

    private static func deltaSuffix(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        let sign = pace.deltaPercent >= 0 ? "+" : "-"
        return " (\(sign)\(deltaValue)%)"
    }

    private static func etaSuffix(for pace: UsagePace, now: Date) -> String? {
        if pace.willLastToReset { return "Lasts to reset" }
        guard let etaSeconds = pace.etaSeconds else { return nil }
        return Self.leftText(seconds: etaSeconds, now: now)
    }

    private static func leftText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = UsageFormatter.resetCountdownDescription(from: date, now: now)
        if countdown == "now" { return "now" }
        if countdown.hasPrefix("in ") {
            return "\(countdown.dropFirst(3)) left"
        }
        return "\(countdown) left"
    }
}
