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
    public let model: UsagePaceModel
    public let confidence: UsagePaceConfidence
    public let isFallbackLinear: Bool

    public static func weekly(
        window: RateWindow,
        now: Date = .init(),
        defaultWindowMinutes: Int = 10080,
        profile: UsagePaceProfile? = nil) -> UsagePace?
    {
        guard let context = baseContext(window: window, now: now, defaultWindowMinutes: defaultWindowMinutes)
        else {
            return nil
        }

        if let profile {
            if profile.hasSufficientData,
               let profiled = Self.profiledPace(context: context, profile: profile)
            {
                return profiled
            }
            return Self.linearPace(
                context: context,
                confidence: .low,
                isFallbackLinear: true)
        }

        return Self.linearPace(
            context: context,
            confidence: .high,
            isFallbackLinear: false)
    }

    private struct Context {
        let now: Date
        let resetsAt: Date
        let duration: TimeInterval
        let timeUntilReset: TimeInterval
        let elapsed: TimeInterval
        let expectedLinear: Double
        let actual: Double
    }

    private static func baseContext(
        window: RateWindow,
        now: Date,
        defaultWindowMinutes: Int) -> Context?
    {
        guard let resetsAt = window.resetsAt else { return nil }
        let minutes = window.windowMinutes ?? defaultWindowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return nil }
        guard timeUntilReset <= duration else { return nil }

        let elapsed = Self.clamp(duration - timeUntilReset, lower: 0, upper: duration)
        let expectedLinear = Self.clamp((elapsed / duration) * 100, lower: 0, upper: 100)
        let actual = Self.clamp(window.usedPercent, lower: 0, upper: 100)

        if elapsed == 0, actual > 0 {
            return nil
        }

        return Context(
            now: now,
            resetsAt: resetsAt,
            duration: duration,
            timeUntilReset: timeUntilReset,
            elapsed: elapsed,
            expectedLinear: expectedLinear,
            actual: actual)
    }

    private static func linearPace(
        context: Context,
        confidence: UsagePaceConfidence,
        isFallbackLinear: Bool) -> UsagePace
    {
        let delta = context.actual - context.expectedLinear
        let stage = Self.stage(for: delta)

        var etaSeconds: TimeInterval?
        var willLastToReset = false

        if context.elapsed > 0, context.actual > 0 {
            let rate = context.actual / context.elapsed
            if rate > 0 {
                let remaining = max(0, 100 - context.actual)
                let candidate = remaining / rate
                if candidate >= context.timeUntilReset {
                    willLastToReset = true
                } else {
                    etaSeconds = candidate
                }
            }
        } else if context.elapsed > 0, context.actual == 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: stage,
            deltaPercent: delta,
            expectedUsedPercent: context.expectedLinear,
            actualUsedPercent: context.actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            model: .linear,
            confidence: confidence,
            isFallbackLinear: isFallbackLinear)
    }

    private static func profiledPace(context: Context, profile: UsagePaceProfile) -> UsagePace? {
        let start = context.resetsAt.addingTimeInterval(-context.duration)
        let pastShape = profile.integratedIntensity(from: start, to: context.now)
        let fullShape = profile.integratedIntensity(from: start, to: context.resetsAt)
        guard pastShape > 0, fullShape > 0 else { return nil }

        let expected = Self.clamp((pastShape / fullShape) * 100, lower: 0, upper: 100)
        let delta = context.actual - expected
        let stage = Self.stage(for: delta)

        let scale = context.actual / pastShape
        var etaSeconds: TimeInterval?
        var willLastToReset = false

        if scale > 0, context.actual > 0 {
            let remaining = max(0, 100 - context.actual)
            let futureShape = profile.integratedIntensity(from: context.now, to: context.resetsAt)
            let projectedFuture = scale * futureShape
            if projectedFuture < remaining {
                willLastToReset = true
            } else if let eta = Self.timeToConsume(
                remainingPercent: remaining,
                start: context.now,
                end: context.resetsAt,
                scale: scale,
                profile: profile)
            {
                if eta >= context.timeUntilReset {
                    willLastToReset = true
                } else {
                    etaSeconds = eta
                }
            } else {
                willLastToReset = true
            }
        } else {
            willLastToReset = true
        }

        return UsagePace(
            stage: stage,
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: context.actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            model: .timeOfDayProfile,
            confidence: .high,
            isFallbackLinear: false)
    }

    private static func timeToConsume(
        remainingPercent: Double,
        start: Date,
        end: Date,
        scale: Double,
        profile: UsagePaceProfile,
        calendar: Calendar = .current) -> TimeInterval?
    {
        guard remainingPercent > 0 else { return 0 }
        guard end > start else { return nil }
        guard scale > 0 else { return nil }

        var consumed = 0.0
        var cursor = start

        while cursor < end {
            let boundary = Self.nextHourBoundary(after: cursor, calendar: calendar)
            let segmentEnd = min(end, boundary)
            let duration = segmentEnd.timeIntervalSince(cursor)
            if duration > 0 {
                let intensity = profile.intensity(at: cursor, calendar: calendar)
                let rate = scale * intensity
                if rate > 0 {
                    let canConsume = rate * duration
                    if consumed + canConsume >= remainingPercent {
                        let needed = (remainingPercent - consumed) / rate
                        return cursor.timeIntervalSince(start) + needed
                    }
                    consumed += canConsume
                }
            }
            cursor = segmentEnd
        }

        return nil
    }

    private static func nextHourBoundary(after date: Date, calendar: Calendar) -> Date {
        if let interval = calendar.dateInterval(of: .hour, for: date) {
            let boundary = interval.end
            if boundary > date {
                return boundary
            }
        }
        return date.addingTimeInterval(3600)
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
