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
    public let speedMultiplierToReset: Double?

    public init(
        stage: Stage,
        deltaPercent: Double,
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        runOutProbability: Double? = nil,
        speedMultiplierToReset: Double? = nil)
    {
        self.stage = stage
        self.deltaPercent = deltaPercent
        self.expectedUsedPercent = expectedUsedPercent
        self.actualUsedPercent = actualUsedPercent
        self.etaSeconds = etaSeconds
        self.willLastToReset = willLastToReset
        self.runOutProbability = runOutProbability
        self.speedMultiplierToReset = speedMultiplierToReset
    }

    public static func weekly(
        window: RateWindow,
        now: Date = .init(),
        defaultWindowMinutes: Int = 10080,
        workDays: Int? = nil,
        calendar: Calendar = .current) -> UsagePace?
    {
        guard let resetsAt = window.resetsAt else { return nil }
        let minutes = window.windowMinutes ?? defaultWindowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return nil }
        guard timeUntilReset <= duration else { return nil }
        let elapsed = (duration - timeUntilReset).clamped(to: 0...duration)
        let workdayProgress: WorkdayProgress? = if let workDays, workDays >= 2, workDays < 7,
                                                   minutes == 10080
        {
            Self.workdayProgress(
                now: now,
                duration: duration,
                resetsAt: resetsAt,
                workDays: workDays,
                calendar: calendar)
        } else {
            nil
        }
        let expected = workdayProgress?.expectedUsedPercent
            ?? ((elapsed / duration) * 100).clamped(to: 0...100)
        let actual = window.usedPercent.clamped(to: 0...100)
        if elapsed == 0, actual > 0 {
            return nil
        }
        let delta = actual - expected
        let stage = Self.stage(for: delta)

        var etaSeconds: TimeInterval?
        var willLastToReset = false

        let paceElapsed = workdayProgress?.elapsedSeconds ?? elapsed
        let effectiveTimeUntilReset = workdayProgress?.remainingSeconds ?? timeUntilReset
        let projectedRemainingUsage = paceElapsed > 0
            ? actual * effectiveTimeUntilReset / paceElapsed
            : 0
        let speedMultiplierToReset = Self.safeSpeedMultiplier(
            remainingCapacity: 100 - actual,
            projectedRemainingUsage: projectedRemainingUsage)
        if actual >= 100 {
            etaSeconds = 0
        } else if paceElapsed > 0, actual > 0 {
            let rate = actual / paceElapsed
            if rate > 0 {
                let remaining = 100 - actual
                let candidate = remaining / rate
                if candidate >= effectiveTimeUntilReset {
                    willLastToReset = true
                } else if let workDays = workdayProgress?.workDays {
                    etaSeconds = Self.wallClockInterval(
                        from: now,
                        to: resetsAt,
                        consumingWorkSeconds: candidate,
                        workDays: workDays,
                        calendar: calendar)
                } else {
                    etaSeconds = candidate
                }
            }
        } else if paceElapsed > 0, actual == 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: stage,
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            runOutProbability: nil,
            speedMultiplierToReset: speedMultiplierToReset)
    }

    public static func historical(
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        runOutProbability: Double?,
        projectedRemainingUsage: Double? = nil) -> UsagePace
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
            runOutProbability: runOutProbability,
            speedMultiplierToReset: projectedRemainingUsage.flatMap {
                Self.safeSpeedMultiplier(
                    remainingCapacity: 100 - actual,
                    projectedRemainingUsage: $0)
            })
    }

    private static func safeSpeedMultiplier(
        remainingCapacity: Double,
        projectedRemainingUsage: Double) -> Double?
    {
        guard remainingCapacity > 0, projectedRemainingUsage > 0 else { return nil }
        let multiplier = remainingCapacity / projectedRemainingUsage
        return multiplier.isFinite ? multiplier : nil
    }

    private struct WorkdayProgress {
        let workDays: Int
        let totalSeconds: TimeInterval
        let elapsedSeconds: TimeInterval
        let remainingSeconds: TimeInterval

        var expectedUsedPercent: Double {
            ((self.elapsedSeconds / self.totalSeconds) * 100).clamped(to: 0...100)
        }
    }

    /// Splits the weekly window at local day boundaries so reset offsets do not shift weekday classification.
    private static func workdayProgress(
        now: Date,
        duration: TimeInterval,
        resetsAt: Date,
        workDays: Int,
        calendar: Calendar) -> WorkdayProgress?
    {
        let windowStart = resetsAt.addingTimeInterval(-duration)

        var totalWorkSeconds: TimeInterval = 0
        var elapsedWorkSeconds: TimeInterval = 0
        var remainingWorkSeconds: TimeInterval = 0

        var cursor = windowStart
        while cursor < resetsAt {
            guard let startOfNextDay = Self.nextDayBoundary(after: cursor, calendar: calendar),
                  startOfNextDay > cursor
            else {
                return nil
            }
            let sliceEnd = min(startOfNextDay, resetsAt)

            if Self.isWorkday(cursor, calendar: calendar, workDays: workDays) {
                let sliceDuration = sliceEnd.timeIntervalSince(cursor)
                totalWorkSeconds += sliceDuration
                if now > cursor {
                    elapsedWorkSeconds += min(now, sliceEnd).timeIntervalSince(cursor)
                }
                if now < sliceEnd {
                    remainingWorkSeconds += sliceEnd.timeIntervalSince(max(now, cursor))
                }
            }
            cursor = sliceEnd
        }

        guard totalWorkSeconds > 0 else { return nil }
        return WorkdayProgress(
            workDays: workDays,
            totalSeconds: totalWorkSeconds,
            elapsedSeconds: elapsedWorkSeconds,
            remainingSeconds: remainingWorkSeconds)
    }

    private static func wallClockInterval(
        from now: Date,
        to resetsAt: Date,
        consumingWorkSeconds requiredWorkSeconds: TimeInterval,
        workDays: Int,
        calendar: Calendar) -> TimeInterval?
    {
        guard requiredWorkSeconds > 0 else { return 0 }

        var remaining = requiredWorkSeconds
        var cursor = now
        while cursor < resetsAt {
            guard let startOfNextDay = Self.nextDayBoundary(after: cursor, calendar: calendar),
                  startOfNextDay > cursor
            else {
                return nil
            }
            let sliceEnd = min(startOfNextDay, resetsAt)
            if Self.isWorkday(cursor, calendar: calendar, workDays: workDays) {
                let available = sliceEnd.timeIntervalSince(cursor)
                if remaining <= available {
                    return cursor.addingTimeInterval(remaining).timeIntervalSince(now)
                }
                remaining -= available
            }
            cursor = sliceEnd
        }
        return nil
    }

    private static func nextDayBoundary(after date: Date, calendar: Calendar) -> Date? {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
    }

    private static func isWorkday(_ date: Date, calendar: Calendar, workDays: Int) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        let isoWeekday = weekday == 1 ? 7 : weekday - 1
        return isoWeekday <= workDays
    }

    private static func stage(for delta: Double) -> Stage {
        let absDelta = abs(delta)
        if absDelta <= 2 { return .onTrack }
        if absDelta <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if absDelta <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }
}
