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
    public let runOutProbability: Double?

    public init(
        stage: Stage,
        deltaPercent: Double,
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        runOutProbability: Double? = nil)
    {
        self.stage = stage
        self.deltaPercent = deltaPercent
        self.expectedUsedPercent = expectedUsedPercent
        self.actualUsedPercent = actualUsedPercent
        self.etaSeconds = etaSeconds
        self.willLastToReset = willLastToReset
        self.runOutProbability = runOutProbability
    }

    public static func weekly(
        window: RateWindow,
        now: Date = .init(),
        defaultWindowMinutes: Int = 10080,
        workDays: Int? = nil) -> UsagePace?
    {
        guard let resetsAt = window.resetsAt else { return nil }
        let minutes = window.windowMinutes ?? defaultWindowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return nil }
        guard timeUntilReset <= duration else { return nil }
        let elapsed = (duration - timeUntilReset).clamped(to: 0...duration)
        let expected: Double
        if let workDays, workDays >= 2, workDays < 7, minutes == 10080 {
            expected = Self.workdayAwareExpected(
                elapsed: elapsed, duration: duration, resetsAt: resetsAt, workDays: workDays)
        } else {
            expected = ((elapsed / duration) * 100).clamped(to: 0...100)
        }
        let actual = window.usedPercent.clamped(to: 0...100)
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
            willLastToReset: willLastToReset,
            runOutProbability: nil)
    }

    public static func historical(
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        runOutProbability: Double?) -> UsagePace
    {
        let expected = expectedUsedPercent.clamped(to: 0...100)
        let actual = actualUsedPercent.clamped(to: 0...100)
        let delta = actual - expected
        return UsagePace(
            stage: Self.stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            runOutProbability: runOutProbability)
    }

    /// Computes expected usage percent distributing 100% only across work days within a 7-day window.
    /// Non-work days contribute zero expected usage, so the curve stays flat on weekends.
    /// Splits intervals at local calendar day boundaries so that a non-midnight reset time
    /// does not shift the workday classification of adjacent days.
    private static func workdayAwareExpected(
        elapsed: TimeInterval,
        duration: TimeInterval,
        resetsAt: Date,
        workDays: Int) -> Double
    {
        let windowStart = resetsAt.addingTimeInterval(-duration)
        let now = windowStart.addingTimeInterval(elapsed)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        var totalWorkSeconds: TimeInterval = 0
        var elapsedWorkSeconds: TimeInterval = 0

        // Walk the window splitting at local calendar day boundaries (midnight).
        var cursor = windowStart
        while cursor < resetsAt {
            let startOfNextDay = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: cursor)!)
            let sliceEnd = min(startOfNextDay, resetsAt)

            let weekday = calendar.component(.weekday, from: cursor)
            // Calendar weekday: 1=Sun, 2=Mon, ..., 7=Sat → convert to ISO: Mon=1..Sun=7
            let isoWeekday = weekday == 1 ? 7 : weekday - 1
            let isWorkDay = isoWeekday <= workDays

            let sliceDuration = sliceEnd.timeIntervalSince(cursor)
            if isWorkDay {
                totalWorkSeconds += sliceDuration
                if now > cursor {
                    elapsedWorkSeconds += min(now, sliceEnd).timeIntervalSince(cursor)
                }
            }
            cursor = sliceEnd
        }

        guard totalWorkSeconds > 0 else {
            return ((elapsed / duration) * 100).clamped(to: 0...100)
        }
        return ((elapsedWorkSeconds / totalWorkSeconds) * 100).clamped(to: 0...100)
    }

    private static func stage(for delta: Double) -> Stage {
        let absDelta = abs(delta)
        if absDelta <= 2 { return .onTrack }
        if absDelta <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if absDelta <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }
}
