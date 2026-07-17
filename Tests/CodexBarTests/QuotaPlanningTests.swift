import CodexBarCore
import Foundation
import Testing

struct QuotaPlanningTests {
    @Test
    func `schedule capacity includes fractional current remainder and future refills`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let pair = Self.pair(
            now: now,
            shortUsed: 60,
            longUsed: 20,
            shortResetOffset: 3600,
            longResetOffset: 16 * 3600)

        let capacity = try #require(QuotaPlanningEstimator.scheduleCapacity(for: pair, now: now))

        #expect(capacity.futureFullShortAllowanceCount == 3)
        #expect(Self.close(capacity.maximumFullSessionEquivalentsBeforeReset, 3.4))
    }

    @Test
    func `schedule capacity honors tolerance and exact duration boundaries`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let shortResetOffset: TimeInterval = 3600
        let shortDuration: TimeInterval = 5 * 3600
        let tolerance = QuotaPlanningConstants.resetEquivalenceTolerance

        let simultaneous = Self.pair(
            now: now,
            shortUsed: 100,
            shortResetOffset: shortResetOffset,
            longResetOffset: shortResetOffset + tolerance)
        let exactOne = Self.pair(
            now: now,
            shortUsed: 100,
            shortResetOffset: shortResetOffset,
            longResetOffset: shortResetOffset + shortDuration + tolerance)
        let justTwo = Self.pair(
            now: now,
            shortUsed: 100,
            shortResetOffset: shortResetOffset,
            longResetOffset: shortResetOffset + shortDuration + tolerance + 0.001)

        #expect(try #require(QuotaPlanningEstimator.scheduleCapacity(for: simultaneous, now: now))
            .futureFullShortAllowanceCount == 0)
        #expect(try #require(QuotaPlanningEstimator.scheduleCapacity(for: exactOne, now: now))
            .futureFullShortAllowanceCount == 1)
        #expect(try #require(QuotaPlanningEstimator.scheduleCapacity(for: justTwo, now: now))
            .futureFullShortAllowanceCount == 2)
    }

    @Test
    func `pair eligibility rejects malformed and unsupported windows`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let invalidPairs = [
            Self.pair(now: now, shortUsed: -1),
            Self.pair(now: now, longUsed: 100),
            Self.pair(now: now, shortUsed: .nan),
            Self.pair(now: now, shortUsageKnown: false),
            Self.pair(now: now, shortSynthetic: true),
            Self.pair(now: now, shortNextRegenPercent: 1),
            Self.pair(now: now, shortMinutes: nil),
            Self.pair(now: now, shortResetOffset: -1),
            Self.pair(now: now, longResetOffset: 8 * 24 * 3600),
        ]

        for pair in invalidPairs {
            #expect(QuotaPlanningEstimator.observation(for: pair, now: now) == nil)
            #expect(QuotaPlanningEstimator.scheduleCapacity(for: pair, now: now) == nil)
        }
    }

    @Test
    func `single candidate requires three long points for presentation`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let shortReset = now.addingTimeInterval(5 * 3600)
        let longReset = now.addingTimeInterval(7 * 24 * 3600)
        var state = QuotaPlanningCalibrationReducer.reduce(
            state: nil,
            observation: Self.observation(
                at: now,
                short: 0,
                long: 10,
                shortReset: shortReset,
                longReset: longReset))

        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(60),
                short: 20,
                long: 11,
                shortReset: shortReset,
                longReset: longReset))

        #expect(state.activeCandidate?.longPercentPerFullShortAllowance == 5)
        #expect(QuotaPlanningEstimator.estimate(
            for: Self.pair(
                now: now.addingTimeInterval(60),
                shortUsed: 20,
                longUsed: 11,
                shortResetAt: shortReset,
                longResetAt: longReset),
            calibration: state,
            now: now.addingTimeInterval(60)) == nil)

        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(120),
                short: 60,
                long: 13,
                shortReset: shortReset,
                longReset: longReset))
        let estimate = try #require(QuotaPlanningEstimator.estimate(
            for: Self.pair(
                now: now.addingTimeInterval(120),
                shortUsed: 60,
                longUsed: 13,
                shortResetAt: shortReset,
                longResetAt: longReset),
            calibration: state,
            now: now.addingTimeInterval(120)))

        #expect(Self.close(estimate.longPercentPerFullShortAllowance, 5))
        #expect(Self.close(estimate.fundableFullSessionEquivalents, 17.4))
        #expect(estimate.reachability == .insufficientEvidence)
    }

    @Test
    func `two consistent low movement candidates qualify`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let firstShortReset = now.addingTimeInterval(5 * 3600)
        let secondShortReset = firstShortReset.addingTimeInterval(5 * 3600)
        let longReset = now.addingTimeInterval(7 * 24 * 3600)
        var state = QuotaPlanningCalibrationReducer.reduce(
            state: nil,
            observation: Self.observation(
                at: now,
                short: 0,
                long: 10,
                shortReset: firstShortReset,
                longReset: longReset))
        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(60),
                short: 20,
                long: 11,
                shortReset: firstShortReset,
                longReset: longReset))
        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: firstShortReset.addingTimeInterval(60),
                short: 0,
                long: 11,
                shortReset: secondShortReset,
                longReset: longReset))
        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: firstShortReset.addingTimeInterval(120),
                short: 20,
                long: 12,
                shortReset: secondShortReset,
                longReset: longReset))

        let estimate = try #require(QuotaPlanningEstimator.estimate(
            for: Self.pair(
                now: firstShortReset.addingTimeInterval(120),
                shortUsed: 20,
                longUsed: 12,
                shortResetAt: secondShortReset,
                longResetAt: longReset),
            calibration: state,
            now: firstShortReset.addingTimeInterval(120)))

        #expect(state.candidates.count == 2)
        #expect(Self.close(estimate.longPercentPerFullShortAllowance, 5))
        #expect(estimate.reachability == .theoreticallyReachable)
    }

    @Test
    func `verdict uses full candidate range`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let shortReset = now.addingTimeInterval(3600)
        let longReset = shortReset.addingTimeInterval(15 * 3600)
        let pair = Self.pair(
            now: now,
            shortUsed: 100,
            longUsed: 90,
            shortResetAt: shortReset,
            longResetAt: longReset)

        let reachable = try #require(QuotaPlanningEstimator.estimate(
            for: pair,
            calibration: Self.calibration(
                now: now,
                shortReset: shortReset,
                longReset: longReset,
                costs: [4, 4.2],
                longUsed: 90),
            now: now))
        let stranded = try #require(QuotaPlanningEstimator.estimate(
            for: pair,
            calibration: Self.calibration(
                now: now,
                shortReset: shortReset,
                longReset: longReset,
                costs: [2, 2.2],
                longUsed: 90),
            now: now))
        let uncertain = try #require(QuotaPlanningEstimator.estimate(
            for: pair,
            calibration: Self.calibration(
                now: now,
                shortReset: shortReset,
                longReset: longReset,
                costs: [2.5, 4],
                longUsed: 90),
            now: now))

        #expect(reachable.reachability == .theoreticallyReachable)
        #expect(stranded.reachability == .likelyStranded)
        #expect(uncertain.reachability == .uncertain)
    }

    @Test
    func `dispersion suppresses estimate without deleting candidates`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let shortReset = now.addingTimeInterval(3600)
        let longReset = now.addingTimeInterval(24 * 3600)
        let calibration = Self.calibration(
            now: now,
            shortReset: shortReset,
            longReset: longReset,
            costs: [5, 10],
            longUsed: 50)

        let estimate = QuotaPlanningEstimator.estimate(
            for: Self.pair(
                now: now,
                shortUsed: 50,
                longUsed: 50,
                shortResetAt: shortReset,
                longResetAt: longReset),
            calibration: calibration,
            now: now)

        #expect(estimate == nil)
        #expect(calibration.candidates.count == 2)
    }

    @Test
    func `material decrease requires active requalification`() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let shortReset = now.addingTimeInterval(5 * 3600)
        let longReset = now.addingTimeInterval(7 * 24 * 3600)
        var state = QuotaPlanningCalibrationReducer.reduce(
            state: nil,
            observation: Self.observation(
                at: now,
                short: 0,
                long: 10,
                shortReset: shortReset,
                longReset: longReset))
        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(60),
                short: 20,
                long: 13,
                shortReset: shortReset,
                longReset: longReset))
        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(120),
                short: 19.7,
                long: 12.7,
                shortReset: shortReset,
                longReset: longReset))
        #expect(state.activeCandidate != nil)
        #expect(state.latest.shortUsedPercent == 20)
        #expect(state.latest.longUsedPercent == 13)

        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(180),
                short: 19,
                long: 12,
                shortReset: shortReset,
                longReset: longReset))
        #expect(state.activeCandidate == nil)
        #expect(state.requiresActiveRequalification)

        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(240),
                short: 39,
                long: 15,
                shortReset: shortReset,
                longReset: longReset))
        #expect(state.activeCandidate != nil)
        #expect(!state.requiresActiveRequalification)
    }

    @Test
    func `long reset clears prior candidates`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let shortReset = now.addingTimeInterval(5 * 3600)
        let longReset = now.addingTimeInterval(7 * 24 * 3600)
        var state = Self.calibration(
            now: now,
            shortReset: shortReset,
            longReset: longReset,
            costs: [5, 6],
            longUsed: 30)
        let nextLongReset = longReset.addingTimeInterval(7 * 24 * 3600)

        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(60),
                short: 0,
                long: 0,
                shortReset: shortReset.addingTimeInterval(5 * 3600),
                longReset: nextLongReset))

        #expect(state.candidates.isEmpty)
        #expect(state.canonicalLongResetAt == nextLongReset)
    }

    @Test
    func `saturation retains earlier active candidate`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let shortReset = now.addingTimeInterval(5 * 3600)
        let longReset = now.addingTimeInterval(7 * 24 * 3600)
        var state = QuotaPlanningCalibrationReducer.reduce(
            state: nil,
            observation: Self.observation(
                at: now,
                short: 0,
                long: 10,
                shortReset: shortReset,
                longReset: longReset))
        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(60),
                short: 20,
                long: 13,
                shortReset: shortReset,
                longReset: longReset))
        let candidate = state.activeCandidate

        state = QuotaPlanningCalibrationReducer.reduce(
            state: state,
            observation: Self.observation(
                at: now.addingTimeInterval(120),
                short: 80,
                long: 99.6,
                shortReset: shortReset,
                longReset: longReset))

        #expect(state.activeCandidate == candidate)
        #expect(state.latest.longUsedPercent == 99.6)
    }

    @Test
    func `completed candidate fifo keeps newest five`() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let longReset = now.addingTimeInterval(7 * 24 * 3600)
        var shortReset = now.addingTimeInterval(5 * 3600)
        var longUsed = 0.0
        var state = QuotaPlanningCalibrationReducer.reduce(
            state: nil,
            observation: Self.observation(
                at: now,
                short: 0,
                long: longUsed,
                shortReset: shortReset,
                longReset: longReset))

        for index in 0..<7 {
            longUsed += Double(index + 1)
            state = QuotaPlanningCalibrationReducer.reduce(
                state: state,
                observation: Self.observation(
                    at: now.addingTimeInterval(Double(index * 120 + 60)),
                    short: 20,
                    long: longUsed,
                    shortReset: shortReset,
                    longReset: longReset))
            shortReset = shortReset.addingTimeInterval(5 * 3600)
            state = QuotaPlanningCalibrationReducer.reduce(
                state: state,
                observation: Self.observation(
                    at: now.addingTimeInterval(Double(index * 120 + 120)),
                    short: 0,
                    long: longUsed,
                    shortReset: shortReset,
                    longReset: longReset))
        }

        #expect(state.completedCandidates.count == 5)
        #expect(state.completedCandidates.map(\.sourceLongDelta) == [3, 4, 5, 6, 7])
    }

    private static func pair(
        now: Date,
        shortUsed: Double = 10,
        longUsed: Double = 20,
        shortResetOffset: TimeInterval = 5 * 3600,
        longResetOffset: TimeInterval = 7 * 24 * 3600,
        shortResetAt: Date? = nil,
        longResetAt: Date? = nil,
        shortMinutes: Int? = 300,
        longMinutes: Int? = 10080,
        shortUsageKnown: Bool = true,
        shortSynthetic: Bool = false,
        shortNextRegenPercent: Double? = nil) -> QuotaPlanningPairSnapshot
    {
        QuotaPlanningPairSnapshot(
            id: "session-weekly",
            short: QuotaPlanningWindowSnapshot(
                metricID: "session",
                window: RateWindow(
                    usedPercent: shortUsed,
                    windowMinutes: shortMinutes,
                    resetsAt: shortResetAt ?? now.addingTimeInterval(shortResetOffset),
                    resetDescription: nil,
                    nextRegenPercent: shortNextRegenPercent,
                    isSyntheticPlaceholder: shortSynthetic),
                usageKnown: shortUsageKnown),
            long: QuotaPlanningWindowSnapshot(
                metricID: "weekly",
                window: RateWindow(
                    usedPercent: longUsed,
                    windowMinutes: longMinutes,
                    resetsAt: longResetAt ?? now.addingTimeInterval(longResetOffset),
                    resetDescription: nil)))
    }

    private static func observation(
        at capturedAt: Date,
        short: Double,
        long: Double,
        shortReset: Date,
        longReset: Date) -> QuotaPlanningObservation
    {
        QuotaPlanningObservation(
            capturedAt: capturedAt,
            shortUsedPercent: short,
            longUsedPercent: long,
            shortResetAt: shortReset,
            longResetAt: longReset)
    }

    private static func calibration(
        now: Date,
        shortReset: Date,
        longReset: Date,
        costs: [Double],
        longUsed: Double) -> QuotaPlanningCalibrationState
    {
        let observation = self.observation(
            at: now,
            short: 0,
            long: longUsed,
            shortReset: shortReset,
            longReset: longReset)
        return QuotaPlanningCalibrationState(
            baseline: observation,
            latest: observation,
            canonicalShortResetAt: shortReset,
            canonicalLongResetAt: longReset,
            activeCandidate: nil,
            completedCandidates: costs.map {
                QuotaPlanningCandidate(
                    longPercentPerFullShortAllowance: $0,
                    sourceLongDelta: 3)
            },
            requiresActiveRequalification: false)
    }

    private static func close(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.0001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}
