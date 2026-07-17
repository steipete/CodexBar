import Foundation

public enum QuotaPlanningConstants {
    public static let resetEquivalenceTolerance: TimeInterval = 120
    public static let percentageJitterTolerance = 0.5
    public static let minimumShortDelta = 20.0
    public static let minimumLongDelta = 1.0
    public static let minimumSingleCandidateLongDelta = 3.0
    public static let longSaturationThreshold = 99.5
    public static let maximumRelativeDeviation = 0.30
    public static let maximumCompletedCandidates = 5
}

public struct QuotaPlanningWindowSnapshot: Equatable, Sendable {
    public let metricID: String
    public let window: RateWindow
    public let usageKnown: Bool

    public init(metricID: String, window: RateWindow, usageKnown: Bool = true) {
        self.metricID = metricID
        self.window = window
        self.usageKnown = usageKnown
    }
}

public struct QuotaPlanningPairSnapshot: Equatable, Sendable {
    public let id: String
    public let short: QuotaPlanningWindowSnapshot
    public let long: QuotaPlanningWindowSnapshot

    public init(id: String, short: QuotaPlanningWindowSnapshot, long: QuotaPlanningWindowSnapshot) {
        self.id = id
        self.short = short
        self.long = long
    }
}

public struct QuotaPlanningObservation: Equatable, Sendable {
    public let capturedAt: Date
    public let shortUsedPercent: Double
    public let longUsedPercent: Double
    public let shortResetAt: Date
    public let longResetAt: Date

    public init(
        capturedAt: Date,
        shortUsedPercent: Double,
        longUsedPercent: Double,
        shortResetAt: Date,
        longResetAt: Date)
    {
        self.capturedAt = capturedAt
        self.shortUsedPercent = shortUsedPercent
        self.longUsedPercent = longUsedPercent
        self.shortResetAt = shortResetAt
        self.longResetAt = longResetAt
    }
}

public struct QuotaPlanningCandidate: Equatable, Sendable {
    public let longPercentPerFullShortAllowance: Double
    public let sourceLongDelta: Double

    public init(longPercentPerFullShortAllowance: Double, sourceLongDelta: Double) {
        self.longPercentPerFullShortAllowance = longPercentPerFullShortAllowance
        self.sourceLongDelta = sourceLongDelta
    }
}

public struct QuotaPlanningCalibrationState: Equatable, Sendable {
    public let baseline: QuotaPlanningObservation
    public let latest: QuotaPlanningObservation
    public let canonicalShortResetAt: Date
    public let canonicalLongResetAt: Date
    public let activeCandidate: QuotaPlanningCandidate?
    public let completedCandidates: [QuotaPlanningCandidate]
    public let requiresActiveRequalification: Bool

    public init(
        baseline: QuotaPlanningObservation,
        latest: QuotaPlanningObservation,
        canonicalShortResetAt: Date,
        canonicalLongResetAt: Date,
        activeCandidate: QuotaPlanningCandidate?,
        completedCandidates: [QuotaPlanningCandidate],
        requiresActiveRequalification: Bool)
    {
        self.baseline = baseline
        self.latest = latest
        self.canonicalShortResetAt = canonicalShortResetAt
        self.canonicalLongResetAt = canonicalLongResetAt
        self.activeCandidate = activeCandidate
        self.completedCandidates = completedCandidates
        self.requiresActiveRequalification = requiresActiveRequalification
    }

    public var candidates: [QuotaPlanningCandidate] {
        self.completedCandidates + [self.activeCandidate].compactMap(\.self)
    }
}

public enum QuotaPlanningReachability: Equatable, Sendable {
    case insufficientEvidence
    case theoreticallyReachable
    case likelyStranded
    case uncertain
}

public struct QuotaPlanningScheduleCapacity: Equatable, Sendable {
    public let maximumFullSessionEquivalentsBeforeReset: Double
    public let futureFullShortAllowanceCount: Int
    public let shortResetAt: Date
    public let longResetAt: Date

    public init(
        maximumFullSessionEquivalentsBeforeReset: Double,
        futureFullShortAllowanceCount: Int,
        shortResetAt: Date,
        longResetAt: Date)
    {
        self.maximumFullSessionEquivalentsBeforeReset = maximumFullSessionEquivalentsBeforeReset
        self.futureFullShortAllowanceCount = futureFullShortAllowanceCount
        self.shortResetAt = shortResetAt
        self.longResetAt = longResetAt
    }
}

public struct QuotaPlanningEstimate: Equatable, Sendable {
    public let pairID: String
    public let longMetricID: String
    public let fundableFullSessionEquivalents: Double
    public let maximumFullSessionEquivalentsBeforeReset: Double
    public let futureFullShortAllowanceCount: Int
    public let longPercentPerFullShortAllowance: Double
    public let reachability: QuotaPlanningReachability
    public let shortResetAt: Date
    public let longResetAt: Date

    public init(
        pairID: String,
        longMetricID: String,
        fundableFullSessionEquivalents: Double,
        maximumFullSessionEquivalentsBeforeReset: Double,
        futureFullShortAllowanceCount: Int,
        longPercentPerFullShortAllowance: Double,
        reachability: QuotaPlanningReachability,
        shortResetAt: Date,
        longResetAt: Date)
    {
        self.pairID = pairID
        self.longMetricID = longMetricID
        self.fundableFullSessionEquivalents = fundableFullSessionEquivalents
        self.maximumFullSessionEquivalentsBeforeReset = maximumFullSessionEquivalentsBeforeReset
        self.futureFullShortAllowanceCount = futureFullShortAllowanceCount
        self.longPercentPerFullShortAllowance = longPercentPerFullShortAllowance
        self.reachability = reachability
        self.shortResetAt = shortResetAt
        self.longResetAt = longResetAt
    }
}

public enum QuotaPlanningEstimator {
    public static func observation(
        for pair: QuotaPlanningPairSnapshot,
        now: Date = .init()) -> QuotaPlanningObservation?
    {
        guard let pair = self.validated(pair: pair, now: now) else { return nil }
        return QuotaPlanningObservation(
            capturedAt: now,
            shortUsedPercent: pair.shortUsedPercent,
            longUsedPercent: pair.longUsedPercent,
            shortResetAt: pair.shortResetAt,
            longResetAt: pair.longResetAt)
    }

    public static func scheduleCapacity(
        for pair: QuotaPlanningPairSnapshot,
        now: Date = .init()) -> QuotaPlanningScheduleCapacity?
    {
        guard let pair = self.validated(pair: pair, now: now) else { return nil }
        return self.scheduleCapacity(
            pair: pair,
            shortResetAt: pair.shortResetAt,
            longResetAt: pair.longResetAt)
    }

    public static func estimate(
        for pair: QuotaPlanningPairSnapshot,
        calibration: QuotaPlanningCalibrationState,
        now: Date = .init()) -> QuotaPlanningEstimate?
    {
        guard !calibration.requiresActiveRequalification,
              let pair = self.validated(pair: pair, now: now),
              equivalent(pair.shortResetAt, calibration.canonicalShortResetAt),
              equivalent(pair.longResetAt, calibration.canonicalLongResetAt),
              calibration.canonicalShortResetAt > now,
              calibration.canonicalLongResetAt > now
        else {
            return nil
        }

        let candidates = calibration.candidates
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1,
           candidates[0].sourceLongDelta < QuotaPlanningConstants.minimumSingleCandidateLongDelta
        {
            return nil
        }

        let costs = candidates.map(\.longPercentPerFullShortAllowance).sorted()
        guard let median = Self.median(costs), median.isFinite, median > 0 else { return nil }
        if costs.count >= 2,
           costs.contains(where: {
               abs($0 - median) / median > QuotaPlanningConstants.maximumRelativeDeviation
           })
        {
            return nil
        }

        guard let schedule = self.scheduleCapacity(
            pair: pair,
            shortResetAt: calibration.canonicalShortResetAt,
            longResetAt: calibration.canonicalLongResetAt)
        else {
            return nil
        }

        let longRemainingPercent = 100 - pair.longUsedPercent
        let fundable = longRemainingPercent / median
        guard fundable.isFinite, fundable >= 0 else { return nil }

        let reachability: QuotaPlanningReachability
        if costs.count < 2 {
            reachability = .insufficientEvidence
        } else {
            let lowerFundable = longRemainingPercent / (costs.last ?? median)
            let upperFundable = longRemainingPercent / (costs.first ?? median)
            if lowerFundable > schedule.maximumFullSessionEquivalentsBeforeReset {
                reachability = .likelyStranded
            } else if upperFundable <= schedule.maximumFullSessionEquivalentsBeforeReset {
                reachability = .theoreticallyReachable
            } else {
                reachability = .uncertain
            }
        }

        return QuotaPlanningEstimate(
            pairID: pair.id,
            longMetricID: pair.longMetricID,
            fundableFullSessionEquivalents: fundable,
            maximumFullSessionEquivalentsBeforeReset: schedule.maximumFullSessionEquivalentsBeforeReset,
            futureFullShortAllowanceCount: schedule.futureFullShortAllowanceCount,
            longPercentPerFullShortAllowance: median,
            reachability: reachability,
            shortResetAt: schedule.shortResetAt,
            longResetAt: schedule.longResetAt)
    }

    private struct ValidatedPair {
        let id: String
        let longMetricID: String
        let shortUsedPercent: Double
        let longUsedPercent: Double
        let shortDuration: TimeInterval
        let shortResetAt: Date
        let longResetAt: Date
    }

    private static func validated(pair: QuotaPlanningPairSnapshot, now: Date) -> ValidatedPair? {
        let pairID = pair.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortMetricID = pair.short.metricID.trimmingCharacters(in: .whitespacesAndNewlines)
        let longMetricID = pair.long.metricID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pairID.isEmpty,
              !shortMetricID.isEmpty,
              !longMetricID.isEmpty,
              shortMetricID != longMetricID,
              pair.short.usageKnown,
              pair.long.usageKnown,
              !pair.short.window.isSyntheticPlaceholder,
              !pair.long.window.isSyntheticPlaceholder,
              pair.short.window.nextRegenPercent == nil,
              pair.long.window.nextRegenPercent == nil,
              pair.short.window.usedPercent.isFinite,
              pair.long.window.usedPercent.isFinite,
              (0...100).contains(pair.short.window.usedPercent),
              (0...100).contains(pair.long.window.usedPercent),
              pair.long.window.usedPercent < 100,
              let shortMinutes = pair.short.window.windowMinutes,
              let longMinutes = pair.long.window.windowMinutes,
              shortMinutes > 0,
              longMinutes > shortMinutes,
              let shortResetAt = pair.short.window.resetsAt,
              let longResetAt = pair.long.window.resetsAt
        else {
            return nil
        }

        let shortDuration = TimeInterval(shortMinutes) * 60
        let longDuration = TimeInterval(longMinutes) * 60
        let shortRemaining = shortResetAt.timeIntervalSince(now)
        let longRemaining = longResetAt.timeIntervalSince(now)
        let tolerance = QuotaPlanningConstants.resetEquivalenceTolerance
        guard shortRemaining > 0,
              longRemaining > 0,
              shortRemaining <= shortDuration + tolerance,
              longRemaining <= longDuration + tolerance
        else {
            return nil
        }

        return ValidatedPair(
            id: pairID,
            longMetricID: longMetricID,
            shortUsedPercent: pair.short.window.usedPercent,
            longUsedPercent: pair.long.window.usedPercent,
            shortDuration: shortDuration,
            shortResetAt: shortResetAt,
            longResetAt: longResetAt)
    }

    private static func scheduleCapacity(
        pair: ValidatedPair,
        shortResetAt: Date,
        longResetAt: Date) -> QuotaPlanningScheduleCapacity?
    {
        let delta = longResetAt.timeIntervalSince(shortResetAt)
        let tolerance = QuotaPlanningConstants.resetEquivalenceTolerance
        let futureCount: Int
        if delta <= tolerance {
            futureCount = 0
        } else {
            let rawCount = ceil((delta - tolerance) / pair.shortDuration)
            guard rawCount.isFinite, rawCount >= 0, rawCount <= Double(Int.max) else { return nil }
            futureCount = Int(rawCount)
        }

        let shortRemainingFraction = (100 - pair.shortUsedPercent) / 100
        let maximum = shortRemainingFraction + Double(futureCount)
        guard maximum.isFinite, maximum >= 0 else { return nil }
        return QuotaPlanningScheduleCapacity(
            maximumFullSessionEquivalentsBeforeReset: maximum,
            futureFullShortAllowanceCount: futureCount,
            shortResetAt: shortResetAt,
            longResetAt: longResetAt)
    }

    private static func equivalent(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= QuotaPlanningConstants.resetEquivalenceTolerance
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let midpoint = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[midpoint - 1] + values[midpoint]) / 2
        }
        return values[midpoint]
    }
}

public enum QuotaPlanningCalibrationReducer {
    public static func reduce(
        state: QuotaPlanningCalibrationState?,
        observation: QuotaPlanningObservation) -> QuotaPlanningCalibrationState
    {
        guard let state else { return self.freshState(observation: observation) }

        guard self.equivalent(observation.longResetAt, state.canonicalLongResetAt) else {
            return self.freshState(observation: observation)
        }

        let shortResetDelta = observation.shortResetAt.timeIntervalSince(state.canonicalShortResetAt)
        let tolerance = QuotaPlanningConstants.resetEquivalenceTolerance
        if shortResetDelta > tolerance {
            var completed = state.completedCandidates
            if let candidate = state.activeCandidate {
                completed.append(candidate)
                if completed.count > QuotaPlanningConstants.maximumCompletedCandidates {
                    completed.removeFirst(completed.count - QuotaPlanningConstants.maximumCompletedCandidates)
                }
            }
            let normalized = self.normalized(
                observation,
                shortResetAt: observation.shortResetAt,
                longResetAt: state.canonicalLongResetAt)
            return QuotaPlanningCalibrationState(
                baseline: normalized,
                latest: normalized,
                canonicalShortResetAt: observation.shortResetAt,
                canonicalLongResetAt: state.canonicalLongResetAt,
                activeCandidate: nil,
                completedCandidates: completed,
                requiresActiveRequalification: state.requiresActiveRequalification)
        }

        if shortResetDelta < -tolerance {
            return self.discontinuousState(
                from: state,
                observation: observation,
                shortResetAt: observation.shortResetAt)
        }

        let jitter = QuotaPlanningConstants.percentageJitterTolerance
        if observation.shortUsedPercent < state.latest.shortUsedPercent - jitter ||
            observation.longUsedPercent < state.latest.longUsedPercent - jitter
        {
            return self.discontinuousState(
                from: state,
                observation: observation,
                shortResetAt: state.canonicalShortResetAt)
        }

        let latest = QuotaPlanningObservation(
            capturedAt: observation.capturedAt,
            shortUsedPercent: max(state.latest.shortUsedPercent, observation.shortUsedPercent),
            longUsedPercent: max(state.latest.longUsedPercent, observation.longUsedPercent),
            shortResetAt: state.canonicalShortResetAt,
            longResetAt: state.canonicalLongResetAt)
        let candidate = self.candidate(baseline: state.baseline, latest: latest)
        return QuotaPlanningCalibrationState(
            baseline: state.baseline,
            latest: latest,
            canonicalShortResetAt: state.canonicalShortResetAt,
            canonicalLongResetAt: state.canonicalLongResetAt,
            activeCandidate: candidate ?? state.activeCandidate,
            completedCandidates: state.completedCandidates,
            requiresActiveRequalification: candidate == nil ? state.requiresActiveRequalification : false)
    }

    private static func freshState(observation: QuotaPlanningObservation) -> QuotaPlanningCalibrationState {
        let normalized = self.normalized(
            observation,
            shortResetAt: observation.shortResetAt,
            longResetAt: observation.longResetAt)
        return QuotaPlanningCalibrationState(
            baseline: normalized,
            latest: normalized,
            canonicalShortResetAt: observation.shortResetAt,
            canonicalLongResetAt: observation.longResetAt,
            activeCandidate: nil,
            completedCandidates: [],
            requiresActiveRequalification: false)
    }

    private static func discontinuousState(
        from state: QuotaPlanningCalibrationState,
        observation: QuotaPlanningObservation,
        shortResetAt: Date) -> QuotaPlanningCalibrationState
    {
        let normalized = self.normalized(
            observation,
            shortResetAt: shortResetAt,
            longResetAt: state.canonicalLongResetAt)
        return QuotaPlanningCalibrationState(
            baseline: normalized,
            latest: normalized,
            canonicalShortResetAt: shortResetAt,
            canonicalLongResetAt: state.canonicalLongResetAt,
            activeCandidate: nil,
            completedCandidates: state.completedCandidates,
            requiresActiveRequalification: true)
    }

    private static func candidate(
        baseline: QuotaPlanningObservation,
        latest: QuotaPlanningObservation) -> QuotaPlanningCandidate?
    {
        let shortDelta = latest.shortUsedPercent - baseline.shortUsedPercent
        let longDelta = latest.longUsedPercent - baseline.longUsedPercent
        guard shortDelta >= QuotaPlanningConstants.minimumShortDelta,
              longDelta >= QuotaPlanningConstants.minimumLongDelta,
              latest.longUsedPercent < QuotaPlanningConstants.longSaturationThreshold
        else {
            return nil
        }

        let cost = 100 * longDelta / shortDelta
        guard cost.isFinite, cost > 0 else { return nil }
        return QuotaPlanningCandidate(
            longPercentPerFullShortAllowance: cost,
            sourceLongDelta: longDelta)
    }

    private static func normalized(
        _ observation: QuotaPlanningObservation,
        shortResetAt: Date,
        longResetAt: Date) -> QuotaPlanningObservation
    {
        QuotaPlanningObservation(
            capturedAt: observation.capturedAt,
            shortUsedPercent: observation.shortUsedPercent,
            longUsedPercent: observation.longUsedPercent,
            shortResetAt: shortResetAt,
            longResetAt: longResetAt)
    }

    private static func equivalent(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= QuotaPlanningConstants.resetEquivalenceTolerance
    }
}
