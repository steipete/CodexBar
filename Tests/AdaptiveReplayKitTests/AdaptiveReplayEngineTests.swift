import AdaptiveReplayKit
import Foundation
import Testing

/// Hand-computed metric checks against small synthetic traces, plus determinism and baseline
/// (manual/fixed) sanity checks for `ReplayEngine`. Trace construction stays in-code (no fixture
/// files): each trace is small enough that its expected metrics can be derived by hand in the
/// comments beside it, which is the actual verification for requirement 4 ("metric math verified
/// against hand-computed values").
struct AdaptiveReplayEngineTests {
    private static let epoch = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        Self.epoch.addingTimeInterval(seconds)
    }

    /// A one-hour span (t=0...3600) pinned by two `decision` boundary records, `FixedIntervalPolicy`
    /// refreshing every 10 minutes, and four `menuOpen` events chosen so each falls a different,
    /// hand-computable number of seconds after the preceding simulated refresh.
    ///
    /// Refreshes land at t=600,1200,...,3600 (6 total: cursor starts at 0, and 3600 <= end is still
    /// included). Staleness samples: menuOpen@50 -> 50-0=50 (no refresh yet, falls back to
    /// time-since-trace-start); @900 -> 900-600=300; @2200 -> 2200-1800=400; @3500 -> 3500-3000=500.
    /// mean=(50+300+400+500)/4=312.5, median (nearest-rank, sorted=[50,300,400,500])=sorted[1]=300,
    /// p95=sorted[3]=500.
    private func fixedCadenceTrace() -> [AdaptiveRefreshTraceRecord] {
        [
            .decision(
                timestamp: self.at(0),
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800),
            .decision(
                timestamp: self.at(3600),
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800),
            .menuOpen(timestamp: self.at(50)),
            .menuOpen(timestamp: self.at(900)),
            .menuOpen(timestamp: self.at(2200)),
            .menuOpen(timestamp: self.at(3500)),
        ]
    }

    @Test
    func `fixed cadence refresh count and staleness match hand computation`() throws {
        let metrics = ReplayEngine.run(trace: self.fixedCadenceTrace(), policy: FixedIntervalPolicy(minutes: 10))

        #expect(metrics.totalRefreshCount == 6)
        #expect(metrics.simulatedSpanSeconds == 3600.0)
        #expect(metrics.refreshCountPer24h == 144.0) // 6 refreshes/hour * 24h
        #expect(metrics.interactionAdvanceCount == 0) // fixed cadence never advances on interaction

        let staleness = try #require(metrics.stalenessAtMenuOpen)
        #expect(staleness.sampleCount == 4)
        #expect(staleness.mean == 312.5)
        #expect(staleness.median == 300.0)
        #expect(staleness.p95 == 500.0)
    }

    @Test
    func `replaying the same trace and policy twice is deterministic`() {
        let trace = self.fixedCadenceTrace()
        let first = ReplayEngine.run(trace: trace, policy: FixedIntervalPolicy(minutes: 10))
        let second = ReplayEngine.run(trace: trace, policy: FixedIntervalPolicy(minutes: 10))
        #expect(first == second)
    }

    @Test
    func `manual policy never schedules a refresh`() {
        let metrics = ReplayEngine.run(trace: self.fixedCadenceTrace(), policy: ManualPolicy())
        #expect(metrics.totalRefreshCount == 0)
        #expect(metrics.refreshCountPer24h == 0.0)
    }

    @Test
    func `a trace with no menu-open events reports no staleness stats`() {
        let trace: [AdaptiveRefreshTraceRecord] = [
            .decision(
                timestamp: self.at(0),
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800),
            .refreshCompleted(timestamp: self.at(1800)),
        ]
        let metrics = ReplayEngine.run(trace: trace, policy: AdaptiveReplayPolicy())
        #expect(metrics.stalenessAtMenuOpen == nil)
    }

    /// A single constrained (`lowPowerModeEnabled: true`) sample at t=0, held for the whole
    /// 0...1000 span (no later sample overrides it), replayed against `FixedIntervalPolicy(2m)`
    /// (120s, well under the 30-minute constrained floor).
    ///
    /// decide() is called at cursor = 0,120,240,...,960 (9 calls: the call at 960 computes
    /// next=1080 > end=1000 and breaks before appending). All 9 calls see the constrained sample,
    /// and every one returns a 120s delay, so all 9 are violations. 8 of those calls' `next` landed
    /// at or before 1000 (120,240,...,960), so 8 refreshes were recorded.
    private func constrainedTrace() -> [AdaptiveRefreshTraceRecord] {
        [
            .decision(
                timestamp: self.at(0),
                menuAgeSeconds: nil,
                lowPowerModeEnabled: true,
                thermalState: .nominal,
                reason: "constrained",
                delaySeconds: 1800),
            .menuOpen(timestamp: self.at(1000)),
        ]
    }

    @Test
    func `a policy that ignores the constrained floor is flagged non-compliant`() {
        let metrics = ReplayEngine.run(trace: self.constrainedTrace(), policy: FixedIntervalPolicy(minutes: 2))

        #expect(metrics.totalRefreshCount == 8)
        #expect(metrics.constrainedCompliance.constrainedDecisionCount == 9)
        #expect(metrics.constrainedCompliance.violationCount == 9)
        #expect(!metrics.constrainedCompliance.isCompliant)
    }

    @Test
    func `the shared adaptive policy honors the constrained floor`() {
        let metrics = ReplayEngine.run(trace: self.constrainedTrace(), policy: AdaptiveReplayPolicy())

        #expect(metrics.constrainedCompliance.constrainedDecisionCount == 1)
        #expect(metrics.constrainedCompliance.violationCount == 0)
        #expect(metrics.constrainedCompliance.isCompliant)
        // The menu open at t=1000 is still under low-power, so the advance-check itself also
        // returns the constrained floor (candidate = 1000+1800 = 2800), which is later than the
        // already-scheduled t=1800 tick — no advance is taken. Mirrors the real
        // `noteMenuOpened(at:)` guard: opening the menu while constrained never shortens the timer.
        #expect(metrics.interactionAdvanceCount == 0)
    }

    @Test
    func `an empty trace reports zero metrics without crashing`() {
        let metrics = ReplayEngine.run(trace: [], policy: AdaptiveReplayPolicy())
        #expect(metrics.totalRefreshCount == 0)
        #expect(metrics.simulatedSpanSeconds == 0.0)
        #expect(metrics.stalenessAtMenuOpen == nil)
        #expect(metrics.constrainedCompliance.constrainedDecisionCount == 0)
        #expect(metrics.interactionAdvanceCount == 0)
    }

    // MARK: - Interaction-advance path (mirrors UsageStore.noteMenuOpened(at:))

    /// A 300-second span with a single tick boundary at t=0 (which alone would schedule a longIdle
    /// refresh at t=1800, far past the trace's end) and one `menuOpen` at t=50 landing inside that
    /// tick's window.
    ///
    /// Hand computation for `AdaptiveReplayPolicy` (`advancesOnInteraction == true`):
    /// - cursor=0: decide(now:0, lastMenuOpenAt: nil) -> longIdle, delay=1800 -> next=1800.
    ///   menuOpen@50 falls in (0, 1800]: decide(now:50, lastMenuOpenAt:50) (age 0) ->
    ///   recentInteraction, delay=120 -> candidate=170. 170 < 1800, so the schedule advances:
    ///   next=170 (1 advance so far). next(170) <= end(300), so a refresh lands at t=170.
    /// - cursor=170: decide(now:170, lastMenuOpenAt:50) (age 120 <= 300 recentInteractionThreshold)
    ///   -> recentInteraction, delay=120 -> next=290. No more menu opens to scan. 290 <= 300, so a
    ///   refresh lands at t=290.
    /// - cursor=290: decide(now:290, lastMenuOpenAt:50) (age 240 <= 300) -> recentInteraction,
    ///   delay=120 -> next=410. 410 > end(300), loop breaks without appending.
    ///
    /// Total: 2 refreshes (170, 290), 1 interaction advance. Without the advance, the *only*
    /// schedulable event would be the t=1800 tick, which falls entirely outside this 300s span —
    /// i.e. `totalRefreshCount` would be 0. The non-zero count here is only possible because the
    /// engine reproduces the interaction-advance path.
    private func menuOpenAdvanceTrace() -> [AdaptiveRefreshTraceRecord] {
        [
            .decision(
                timestamp: self.at(0),
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800),
            .decision(
                timestamp: self.at(300),
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800),
            .menuOpen(timestamp: self.at(50)),
        ]
    }

    @Test
    func `a menu open pulls the adaptive schedule forward, matching hand computation`() {
        let metrics = ReplayEngine.run(trace: self.menuOpenAdvanceTrace(), policy: AdaptiveReplayPolicy())

        #expect(metrics.totalRefreshCount == 2)
        #expect(metrics.interactionAdvanceCount == 1)
    }

    @Test
    func `a policy that does not advance on interaction ignores the same menu open`() {
        // Same trace, but FixedIntervalPolicy(30m) never overrides `advancesOnInteraction` (stays
        // false), matching fixed-cadence refresh frequencies in the real app, which never wire
        // `noteMenuOpened(at:)`'s advance check at all. The t=1800 tick falls outside the 300s
        // span, so nothing is scheduled — the menu open at t=50 has zero scheduling effect.
        let metrics = ReplayEngine.run(trace: self.menuOpenAdvanceTrace(), policy: FixedIntervalPolicy(minutes: 30))

        #expect(metrics.totalRefreshCount == 0)
        #expect(metrics.interactionAdvanceCount == 0)
    }

    @Test
    func `a recorded timerAdvanced ground-truth event agrees with the engine's own recomputation`() throws {
        // The menuOpen ground truth plus a timerAdvanced record for the accepted schedule change.
        // The offline audit checks that record against the policy's recomputed candidate.
        let menuOpenAt = self.at(50)
        let recordedCandidate = self.at(170) // menuOpenAt + recentInteractionDelay (120s)
        var trace = self.menuOpenAdvanceTrace()
        trace.append(.timerAdvanced(
            timestamp: menuOpenAt,
            previousScheduledAt: self.at(1800),
            candidateScheduledAt: recordedCandidate,
            reason: "recentInteraction",
            delaySeconds: 120))

        let policy = AdaptiveReplayPolicy()
        let recomputed = policy.decide(ReplayPolicyInput(
            now: menuOpenAt,
            lastMenuOpenAt: menuOpenAt,
            lowPowerModeEnabled: false,
            thermalState: .nominal))
        let recomputedCandidate = try menuOpenAt.addingTimeInterval(#require(recomputed.delaySeconds))

        #expect(recomputedCandidate == recordedCandidate)

        // The recorded event doesn't change the metrics (the engine recomputes advances itself,
        // independent of any timerAdvanced lines in the trace); replaying still reproduces the
        // same two refreshes as the trace without the extra record.
        let metrics = ReplayEngine.run(trace: trace, policy: policy)
        #expect(metrics.totalRefreshCount == 2)
        #expect(metrics.interactionAdvanceCount == 1)
    }

    /// Two menu opens in the same tick window: the second one's candidate is compared against the
    /// *already-advanced* schedule from the first, not the original tick schedule — mirroring a
    /// real second `noteMenuOpened(at:)` call tightening an already-shortened sleep.
    ///
    /// - cursor=0: decide -> longIdle, next=1800. menuOpen@50: candidate=170 < 1800 -> next=170
    ///   (advance 1). menuOpen@100 also falls in (0, 170]? No — 100 <= 170 is true, so it's still
    ///   scanned: decide(now:100, lastMenuOpenAt:100) -> recentInteraction, candidate=220. Is 220 <
    ///   next(170)? No, so this second menu open does *not* further advance the schedule (it would
    ///   move the refresh *later*, which `shouldAdvanceAdaptiveTimer` never does). next stays 170.
    /// - Total: 1 refresh (170), 1 advance (only the first menu open's candidate beat the schedule).
    private func twoMenuOpensSameWindowTrace() -> [AdaptiveRefreshTraceRecord] {
        [
            .decision(
                timestamp: self.at(0),
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800),
            .decision(
                timestamp: self.at(170),
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800),
            .menuOpen(timestamp: self.at(50)),
            .menuOpen(timestamp: self.at(100)),
        ]
    }

    @Test
    func `a later menu open in the same window cannot postpone an earlier advance`() {
        let metrics = ReplayEngine.run(trace: self.twoMenuOpensSameWindowTrace(), policy: AdaptiveReplayPolicy())

        #expect(metrics.totalRefreshCount == 1)
        #expect(metrics.interactionAdvanceCount == 1)
    }
}
