import AdaptiveReplayKit
import Foundation
import Testing

/// Purely informational trace-level stats surfaced by `AdaptiveReplayCLI` — computed directly from
/// raw `decision` records, independent of any `ReplayPolicy` or `ReplayEngine` simulation.
struct ActivityCoverageStatsTests {
    private static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func decision(codex: TimeInterval?, claude: TimeInterval?) -> AdaptiveRefreshTraceRecord {
        .decision(
            timestamp: self.referenceNow,
            menuAgeSeconds: nil,
            lowPowerModeEnabled: false,
            thermalState: .nominal,
            reason: "warm",
            delaySeconds: 300,
            codexActivitySeconds: codex,
            claudeActivitySeconds: claude)
    }

    @Test
    func `an empty trace reports zero decisions and zero fractions`() {
        let stats = ActivityCoverageStats.compute(from: [])
        #expect(stats.decisionCount == 0)
        #expect(stats.sampledCount == 0)
        #expect(stats.activeCount == 0)
        #expect(stats.sampledFraction == 0)
        #expect(stats.activeFraction == 0)
    }

    @Test
    func `non decision records are ignored entirely`() {
        let records: [AdaptiveRefreshTraceRecord] = [
            .menuOpen(timestamp: Self.referenceNow),
            .refreshCompleted(timestamp: Self.referenceNow),
        ]
        let stats = ActivityCoverageStats.compute(from: records)
        #expect(stats.decisionCount == 0)
    }

    @Test
    func `a decision with neither activity field set counts toward decisionCount but not sampledCount`() {
        let stats = ActivityCoverageStats.compute(from: [Self.decision(codex: nil, claude: nil)])
        #expect(stats.decisionCount == 1)
        #expect(stats.sampledCount == 0)
        #expect(stats.activeCount == 0)
    }

    @Test
    func `a decision with only one activity field set still counts as sampled`() {
        let stats = ActivityCoverageStats.compute(from: [Self.decision(codex: 500, claude: nil)])
        #expect(stats.sampledCount == 1)
    }

    @Test
    func `a sampled decision under the active threshold on either CLI counts as active`() {
        let codexActive = ActivityCoverageStats.compute(from: [Self.decision(codex: 100, claude: nil)])
        #expect(codexActive.activeCount == 1)

        let claudeActive = ActivityCoverageStats.compute(from: [Self.decision(codex: nil, claude: 100)])
        #expect(claudeActive.activeCount == 1)
    }

    @Test
    func `a sampled decision at or above the active threshold on both CLIs does not count as active`() {
        let stats = ActivityCoverageStats.compute(from: [Self.decision(codex: 500, claude: 400)])
        #expect(stats.sampledCount == 1)
        #expect(stats.activeCount == 0)
    }

    @Test
    func `fractions are computed against decisionCount and sampledCount respectively`() {
        let records: [AdaptiveRefreshTraceRecord] = [
            Self.decision(codex: 100, claude: nil), // sampled, active
            Self.decision(codex: 500, claude: 400), // sampled, not active
            Self.decision(codex: nil, claude: nil), // not sampled
            Self.decision(codex: nil, claude: nil), // not sampled
        ]
        let stats = ActivityCoverageStats.compute(from: records)
        #expect(stats.decisionCount == 4)
        #expect(stats.sampledCount == 2)
        #expect(stats.activeCount == 1)
        #expect(stats.sampledFraction == 0.5)
        #expect(stats.activeFraction == 0.5)
    }

    @Test
    func `a custom active threshold changes the active classification`() {
        let stats = ActivityCoverageStats.compute(
            from: [Self.decision(codex: 250, claude: nil)],
            activeThresholdSeconds: 60)
        #expect(stats.sampledCount == 1)
        #expect(stats.activeCount == 0)
    }
}
