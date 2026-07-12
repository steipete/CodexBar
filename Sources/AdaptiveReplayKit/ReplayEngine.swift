import Foundation

/// Simulates the live timer loop (`decide` → sleep → refresh → `decide` → ...) over a trace's
/// observed span for a given `ReplayPolicy`, pure and deterministic: the same trace and policy
/// always produce the same `ReplayMetrics`, since every input the policy sees comes from the
/// trace, never from a live clock.
///
/// Ground truth vs. reconstructed signal: `menuOpen` events are ground truth — a menu either
/// opened at a timestamp or it didn't, independent of any policy. `lowPowerModeEnabled` and
/// `thermalState`, by contrast, are only *sampled* at the timestamps the trace's original
/// `decision` events happened to occur at (whatever policy produced the trace). When a candidate
/// policy's own tick times fall between those samples, the engine holds the most recent known
/// value (step function). This is the phase-1 approximation: without a continuous power/thermal
/// signal in the trace, "most recent sample" is the best available reconstruction. Before the
/// first known sample, the earliest available sample is used (hold-first).
///
/// Interaction advances: this is a *counterfactual* replay, not a literal replay of whatever the
/// recording policy happened to do — each candidate policy gets its own tick schedule computed
/// fresh from `policy.decide(_:)`. To reproduce `UsageStore.noteMenuOpened(at:)`'s "pull the timer
/// forward" behavior (see `UsageStore.shouldAdvanceAdaptiveTimer(scheduledAt:candidate:)`) for
/// *any* candidate policy, every `menuOpen` event that falls inside a policy's current tick window
/// is independently re-evaluated: if `policy.advancesOnInteraction` and the decision computed as of
/// that menu open would land earlier than the already-scheduled next tick, the schedule advances to
/// that earlier time, exactly like `startTimer(preservingResetBoundaryRefresh: true)` replacing a
/// pending sleep with a shorter one. Recorded `timerAdvanced` events are audited separately: their
/// count is not expected to equal
/// this counterfactual schedule because live refresh work has non-zero duration and can coalesce.
public enum ReplayEngine {
    /// Safety valve against a pathological policy (e.g. a zero-or-negative delay bug) turning a
    /// long trace into an unbounded loop.
    private static let maxIterations = 2_000_000

    /// The trace-derived, replay-invariant inputs the simulation loop reads on every tick:
    /// menu-open ground truth plus the sampled power/thermal signal, both precomputed and sorted
    /// once per `run` so the per-tick lookups stay O(log n).
    private struct TraceSignals {
        let menuOpenTimestamps: [Date]
        let signalSamples: [(timestamp: Date, lowPower: Bool, thermal: ReplayThermalState)]
        let signalTimestamps: [Date]
        let activitySamples: [ActivityObservation]
        let activityTimestamps: [Date]
    }

    private struct ActivityObservation {
        let timestamp: Date
        let lastCodingActivityAt: Date?
    }

    public static func run(trace: [AdaptiveRefreshTraceRecord], policy: some ReplayPolicy) -> ReplayMetrics {
        self.runDetailed(trace: trace, policy: policy).metrics
    }

    static func runDetailed(
        trace: [AdaptiveRefreshTraceRecord],
        policy: some ReplayPolicy,
        stalenessStartAt: Date? = nil) -> ReplayRun
    {
        guard let start = trace.map(\.timestamp).min(), let end = trace.map(\.timestamp).max() else {
            return ReplayRun(
                metrics: ReplayMetrics(
                    policyName: policy.name,
                    simulatedSpanSeconds: 0,
                    totalRefreshCount: 0,
                    refreshCountPer24h: 0,
                    stalenessAtMenuOpen: nil,
                    constrainedCompliance: ConstrainedCompliance(constrainedDecisionCount: 0, violationCount: 0)),
                stalenessSamples: [])
        }

        let menuOpenTimestamps = trace
            .filter { $0.kind == .menuOpen }
            .map(\.timestamp)
            .sorted()

        let signalSamples: [(timestamp: Date, lowPower: Bool, thermal: ReplayThermalState)] = trace
            .filter { $0.kind == .decision }
            .compactMap { record in
                guard let lowPower = record.lowPowerModeEnabled, let thermal = record.thermalState else {
                    return nil
                }
                return (timestamp: record.timestamp, lowPower: lowPower, thermal: thermal)
            }
            .sorted { $0.timestamp < $1.timestamp }
        let activitySamples = trace
            .filter { $0.kind == .decision }
            .map { record in
                let activityDates = [record.codexActivitySeconds, record.claudeActivitySeconds]
                    .compactMap(\.self)
                    .map { record.timestamp.addingTimeInterval(-max(0, $0)) }
                return ActivityObservation(
                    timestamp: record.timestamp,
                    lastCodingActivityAt: activityDates.max())
            }
            .sorted { $0.timestamp < $1.timestamp }
        let signals = TraceSignals(
            menuOpenTimestamps: menuOpenTimestamps,
            signalSamples: signalSamples,
            signalTimestamps: signalSamples.map(\.timestamp),
            activitySamples: activitySamples,
            activityTimestamps: activitySamples.map(\.timestamp))

        var cursor = start
        var refreshTimestamps: [Date] = []
        var constrainedDecisionCount = 0
        var violationCount = 0
        var interactionAdvanceCount = 0
        var codingActiveDecisionCount = 0
        var codingActiveDelayViolationCount = 0
        var iterations = 0
        // Monotonic pointer into `menuOpenTimestamps`: the scan below considers each menu open for
        // an advance at most once, in the single tick window (cursor, next] it falls into.
        var menuOpenScanIndex = 0

        while cursor <= end, iterations < self.maxIterations {
            iterations += 1
            let (lowPower, thermal) = self.signal(
                signals.signalSamples,
                timestamps: signals.signalTimestamps,
                at: cursor)
            let input = ReplayPolicyInput(
                now: cursor,
                lastMenuOpenAt: self.lastValue(menuOpenTimestamps, atOrBefore: cursor),
                lastCodingActivityAt: self.lastActivity(
                    signals.activitySamples,
                    timestamps: signals.activityTimestamps,
                    at: cursor),
                lowPowerModeEnabled: lowPower,
                thermalState: thermal)
            let decision = policy.decide(input)

            if input.isConstrained {
                constrainedDecisionCount += 1
                if let delay = decision.delaySeconds, delay < 1800 {
                    violationCount += 1
                }
            }

            if !input.isConstrained,
               let activityAge = input.codingActivityAgeSeconds,
               activityAge < 5 * 60
            {
                codingActiveDecisionCount += 1
                if decision.delaySeconds.map({ $0 <= 0 || $0 > 5 * 60 }) ?? true {
                    codingActiveDelayViolationCount += 1
                }
            }

            guard let delay = decision.delaySeconds, delay > 0 else { break }
            var next = cursor.addingTimeInterval(delay)

            if policy.advancesOnInteraction {
                let advanced = self.applyInteractionAdvances(
                    policy: policy,
                    signals: signals,
                    scanIndex: &menuOpenScanIndex,
                    windowStart: cursor,
                    scheduledAt: next)
                next = advanced.scheduledAt
                interactionAdvanceCount += advanced.advanceCount
            }

            guard next <= end else { break }
            refreshTimestamps.append(next)
            cursor = next
        }

        let span = end.timeIntervalSince(start)
        let refreshCountPer24h = span > 0 ? Double(refreshTimestamps.count) * 86400 / span : 0

        let stalenessMenuTimestamps = stalenessStartAt.map { start in
            menuOpenTimestamps.filter { $0 >= start }
        } ?? menuOpenTimestamps
        let stalenessSamples = stalenessMenuTimestamps.isEmpty ? [] : self.stalenessSamples(
            menuOpenTimestamps: stalenessMenuTimestamps,
            refreshTimestamps: refreshTimestamps,
            initialFreshAt: stalenessStartAt ?? start)

        return ReplayRun(
            metrics: ReplayMetrics(
                policyName: policy.name,
                simulatedSpanSeconds: span,
                totalRefreshCount: refreshTimestamps.count,
                refreshCountPer24h: refreshCountPer24h,
                stalenessAtMenuOpen: StalenessStats(samples: stalenessSamples),
                constrainedCompliance: ConstrainedCompliance(
                    constrainedDecisionCount: constrainedDecisionCount,
                    violationCount: violationCount),
                interactionAdvanceCount: interactionAdvanceCount,
                codingActiveDecisionCount: codingActiveDecisionCount,
                codingActiveDelayViolationCount: codingActiveDelayViolationCount),
            stalenessSamples: stalenessSamples)
    }

    /// Re-evaluates every not-yet-scanned menu open that falls in `(windowStart, scheduledAt]`
    /// against `policy`, mirroring `UsageStore.shouldAdvanceAdaptiveTimer(scheduledAt:candidate:)`:
    /// a menu open at time `T` computes `policy.decide(now: T, lastMenuOpenAt: T, ...)` (age zero,
    /// exactly as `noteMenuOpened(at:)` does with `self.lastMenuOpenAt = date` already applied), and
    /// if the resulting candidate (`T + delay`) lands earlier than the currently scheduled refresh,
    /// the schedule advances to that candidate. Later menu opens in the same window are then
    /// compared against the *advanced* schedule, same as a real second interaction tightening an
    /// already-shortened sleep. Returns the (possibly advanced) scheduled time plus how many
    /// advances were taken in this window.
    private static func applyInteractionAdvances(
        policy: some ReplayPolicy,
        signals: TraceSignals,
        scanIndex: inout Int,
        windowStart: Date,
        scheduledAt: Date) -> (scheduledAt: Date, advanceCount: Int)
    {
        var next = scheduledAt
        var advanceCount = 0
        while scanIndex < signals.menuOpenTimestamps.count {
            let menuOpenAt = signals.menuOpenTimestamps[scanIndex]
            guard menuOpenAt > windowStart else {
                scanIndex += 1
                continue
            }
            guard menuOpenAt <= next else { break }

            let (lowPower, thermal) = self.signal(
                signals.signalSamples,
                timestamps: signals.signalTimestamps,
                at: menuOpenAt)
            let advanceDecision = policy.decide(ReplayPolicyInput(
                now: menuOpenAt,
                lastMenuOpenAt: menuOpenAt,
                lastCodingActivityAt: self.lastActivity(
                    signals.activitySamples,
                    timestamps: signals.activityTimestamps,
                    at: menuOpenAt),
                lowPowerModeEnabled: lowPower,
                thermalState: thermal))
            scanIndex += 1

            guard let advanceDelay = advanceDecision.delaySeconds, advanceDelay > 0 else { continue }
            let candidate = menuOpenAt.addingTimeInterval(advanceDelay)
            if candidate < next {
                next = candidate
                advanceCount += 1
            }
        }
        return (next, advanceCount)
    }

    private static func stalenessSamples(
        menuOpenTimestamps: [Date],
        refreshTimestamps: [Date],
        initialFreshAt: Date) -> [Double]
    {
        menuOpenTimestamps.map { menuOpenAt in
            let simulatedRefresh = self.lastValue(refreshTimestamps, atOrBefore: menuOpenAt)
            let freshestAt = simulatedRefresh.map { max($0, initialFreshAt) } ?? initialFreshAt
            return menuOpenAt.timeIntervalSince(freshestAt)
        }
    }

    private static func lastActivity(
        _ samples: [ActivityObservation],
        timestamps: [Date],
        at time: Date) -> Date?
    {
        guard let index = self.lastIndex(timestamps, atOrBefore: time) else { return nil }
        return samples[index].lastCodingActivityAt
    }

    /// Binds the most recent power/thermal sample at or before `time` (hold-last), falling back
    /// to the earliest known sample when `time` precedes every sample (hold-first), and to
    /// nominal/not-low-power when no samples exist at all.
    private static func signal(
        _ samples: [(timestamp: Date, lowPower: Bool, thermal: ReplayThermalState)],
        timestamps: [Date],
        at time: Date) -> (Bool, ReplayThermalState)
    {
        guard !samples.isEmpty else { return (false, .nominal) }
        if let index = self.lastIndex(timestamps, atOrBefore: time) {
            return (samples[index].lowPower, samples[index].thermal)
        }
        return (samples[0].lowPower, samples[0].thermal)
    }

    private static func lastValue(_ timestamps: [Date], atOrBefore time: Date) -> Date? {
        guard let index = self.lastIndex(timestamps, atOrBefore: time) else { return nil }
        return timestamps[index]
    }

    /// Binary search for the last index whose timestamp is `<= time`, assuming `timestamps` is
    /// sorted ascending. O(log n) so a long trace (thousands of decisions) stays fast to replay.
    private static func lastIndex(_ timestamps: [Date], atOrBefore time: Date) -> Int? {
        var low = 0
        var high = timestamps.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if timestamps[mid] <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
