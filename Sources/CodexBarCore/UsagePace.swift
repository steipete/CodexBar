import Foundation

public struct UsagePace: Sendable {
    public enum Stage: Sendable {
        case onTrack
        case slightlyAhead
        case ahead
        case farAhead
        case slightlyBehind
        case behind
        case farBehind
    }

    public let stage: Stage
    public let deltaPercent: Double
    public let expectedUsedPercent: Double
    public let actualUsedPercent: Double
    public let etaSeconds: TimeInterval?
    public let willLastToReset: Bool

    public static func weekly(
        window: RateWindow,
        now: Date = .init(),
        defaultWindowMinutes: Int = 10080) -> UsagePace?
    {
        guard let resetsAt = window.resetsAt else { return nil }
        let minutes = window.windowMinutes ?? defaultWindowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return nil }
        guard timeUntilReset <= duration else { return nil }
        let elapsed = Self.clamp(duration - timeUntilReset, lower: 0, upper: duration)
        let expected = Self.clamp((elapsed / duration) * 100, lower: 0, upper: 100)
        let actual = Self.clamp(window.usedPercent, lower: 0, upper: 100)
        if elapsed == 0, actual > 0 {
            return nil
        }
        let delta = actual - expected
        let stage = Self.stage(for: delta)

        var etaSeconds: TimeInterval?
        var willLastToReset = false

        if elapsed > 0, actual > 0 {
            let rate = actual / elapsed
            if rate > 0 {
                let remaining = max(0, 100 - actual)
                let candidate = remaining / rate
                if candidate >= timeUntilReset {
                    willLastToReset = true
                } else {
                    etaSeconds = candidate
                }
            }
        } else if elapsed > 0, actual == 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: stage,
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset)
    }

    private static func stage(for delta: Double) -> Stage {
        let absDelta = abs(delta)
        if absDelta <= 2 { return .onTrack }
        if absDelta <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if absDelta <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}
