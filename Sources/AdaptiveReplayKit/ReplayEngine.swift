import Foundation

/// Simulates the live timer loop (`decide` → sleep → refresh → `decide` → ...) over a trace's
/// wall-clock span for a given `ReplayPolicy`, pure and deterministic: the same trace and policy
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
/// pending sleep with a shorter one. `AdaptiveRefreshTraceRecordingTests` (app target) proves the
/// recorded `timerAdvanced` ground truth agrees with what this recomputation independently derives.
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
    }

    public static func run(trace: [AdaptiveRefreshTraceRecord], policy: some ReplayPolicy) -> ReplayMetrics {
        guard let start = trace.map(\.timestamp).min(), let end = trace.map(\.timestamp).max() else {
            return ReplayMetrics(
                policyName: policy.name,
                simulatedSpanSeconds: 0,
                totalRefreshCount: 0,
                refreshCountPer24h: 0,
                stalenessAtMenuOpen: nil,
                constrainedCompliance: ConstrainedCompliance(constrainedDecisionCount: 0, violationCount: 0),
                interactionAdvanceCount: 0)
        }

        let menuOpenTimestamps = trace
            .filter { $0.kind == .menuOpen }
            .map(\.timestamp)
            .sorted()

        let signals = TraceSignals(
            menuOpenTimestamps: menuOpenTimestamps,
            signalSamples: trace
                .filter { $0.kind == .decision }
                .compactMap { record in
                    guard let lowPower = record.lowPowerModeEnabled, let thermal = record.thermalState else {
                        return nil
                    }
                    return (record.timestamp, lowPower, thermal)
                }
                .sorted { $0.timestamp < $1.timestamp })

        var cursor = start
        var refreshTimestamps: [Date] = []
        var constrainedDecisionCount = 0
        var violationCount = 0
        var interactionAdvanceCount = 0
        var iterations = 0
        // Monotonic pointer into `menuOpenTimestamps`: the scan below considers each menu open for
        // an advance at most once, in the single tick window (cursor, next] it falls into.
        var menuOpenScanIndex = 0

        while cursor <= end, iterations < self.maxIterations {
            iterations += 1
            let (lowPower, thermal) = self.signal(signals.signalSamples, at: cursor)
            let input = ReplayPolicyInput(
                now: cursor,
                lastMenuOpenAt: self.lastValue(menuOpenTimestamps, atOrBefore: cursor),
                lowPowerModeEnabled: lowPower,
                thermalState: thermal)
            let decision = policy.decide(input)

            if input.isConstrained {
                constrainedDecisionCount += 1
                if let delay = decision.delaySeconds, delay < 1800 {
                    violationCount += 1
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

        let staleness = menuOpenTimestamps.isEmpty ? nil : self.stalenessStats(
            menuOpenTimestamps: menuOpenTimestamps,
            refreshTimestamps: refreshTimestamps,
            traceStart: start)

        return ReplayMetrics(
            policyName: policy.name,
            simulatedSpanSeconds: span,
            totalRefreshCount: refreshTimestamps.count,
            refreshCountPer24h: refreshCountPer24h,
            stalenessAtMenuOpen: staleness,
            constrainedCompliance: ConstrainedCompliance(
                constrainedDecisionCount: constrainedDecisionCount,
                violationCount: violationCount),
            interactionAdvanceCount: interactionAdvanceCount)
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

            let (lowPower, thermal) = self.signal(signals.signalSamples, at: menuOpenAt)
            let advanceDecision = policy.decide(ReplayPolicyInput(
                now: menuOpenAt,
                lastMenuOpenAt: menuOpenAt,
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

    private static func stalenessStats(
        menuOpenTimestamps: [Date],
        refreshTimestamps: [Date],
        traceStart: Date) -> StalenessStats
    {
        let samples: [Double] = menuOpenTimestamps.map { menuOpenAt in
            if let lastRefresh = self.lastValue(refreshTimestamps, atOrBefore: menuOpenAt) {
                menuOpenAt.timeIntervalSince(lastRefresh)
            } else {
                menuOpenAt.timeIntervalSince(traceStart)
            }
        }
        let sorted = samples.sorted()
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        let median = Self.percentile(sorted, fraction: 0.5)
        let p95 = Self.percentile(sorted, fraction: 0.95)
        return StalenessStats(mean: mean, median: median, p95: p95, sampleCount: sorted.count)
    }

    /// Nearest-rank percentile over an already-sorted array.
    private static func percentile(_ sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        let index = max(0, min(sorted.count - 1, rank - 1))
        return sorted[index]
    }

    /// Binds the most recent power/thermal sample at or before `time` (hold-last), falling back
    /// to the earliest known sample when `time` precedes every sample (hold-first), and to
    /// nominal/not-low-power when no samples exist at all.
    private static func signal(
        _ samples: [(timestamp: Date, lowPower: Bool, thermal: ReplayThermalState)],
        at time: Date) -> (Bool, ReplayThermalState)
    {
        guard !samples.isEmpty else { return (false, .nominal) }
        if let index = self.lastIndex(samples.map(\.timestamp), atOrBefore: time) {
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
