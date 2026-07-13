import AdaptiveReplayKit
import Foundation
import Testing

struct CodingActivityReplayPolicyTests {
    private static let now = Date(timeIntervalSinceReferenceDate: 10000)

    private func input(
        menuAge: TimeInterval?,
        activityAge: TimeInterval?,
        constrained: Bool = false) -> ReplayPolicyInput
    {
        ReplayPolicyInput(
            now: Self.now,
            lastMenuOpenAt: menuAge.map { Self.now.addingTimeInterval(-$0) },
            lastCodingActivityAt: activityAge.map { Self.now.addingTimeInterval(-$0) },
            lowPowerModeEnabled: constrained,
            thermalState: .nominal)
    }

    @Test
    func `active coding caps idle and long-idle decisions at five minutes`() {
        let policy = CodingActivityAdaptivePolicy()

        #expect(policy.name == "adaptive-activity")
        #expect(policy.decide(self.input(menuAge: 2 * 3600, activityAge: 10)).delaySeconds == 300)
        #expect(policy.decide(self.input(menuAge: nil, activityAge: 10)).delaySeconds == 300)
        #expect(policy.decide(self.input(menuAge: nil, activityAge: 10)).reason == "codingActivity")
    }

    @Test
    func `existing recent and warm decisions remain unchanged`() {
        let policy = CodingActivityAdaptivePolicy()

        #expect(policy.decide(self.input(menuAge: 60, activityAge: 10)).delaySeconds == 120)
        #expect(policy.decide(self.input(menuAge: 600, activityAge: 10)).delaySeconds == 300)
    }

    @Test
    func `constrained state wins and exact threshold is inactive`() {
        let policy = CodingActivityAdaptivePolicy()

        #expect(policy.decide(self.input(menuAge: nil, activityAge: 10, constrained: true)).delaySeconds == 1800)
        #expect(policy.decide(self.input(menuAge: nil, activityAge: 300)).delaySeconds == 1800)
        #expect(policy.decide(self.input(menuAge: nil, activityAge: nil)).delaySeconds == 1800)
    }

    @Test
    func `future activity samples never backfill an earlier replay decision`() {
        let trace: [AdaptiveRefreshTraceRecord] = [
            .decision(
                timestamp: Self.now,
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800),
            .decision(
                timestamp: Self.now.addingTimeInterval(600),
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800,
                codexActivitySeconds: 0),
        ]

        let metrics = ReplayEngine.run(trace: trace, policy: CodingActivityAdaptivePolicy())

        #expect(metrics.codingActiveDecisionCount == 0)
        #expect(metrics.totalRefreshCount == 0)
    }

    @Test
    func `a newer unavailable observation invalidates older activity`() {
        let trace: [AdaptiveRefreshTraceRecord] = [
            .menuOpen(timestamp: Self.now),
            .decision(
                timestamp: Self.now,
                menuAgeSeconds: 0,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "recentInteraction",
                delaySeconds: 120,
                codexActivitySeconds: 0),
            .decision(
                timestamp: Self.now.addingTimeInterval(100),
                menuAgeSeconds: 100,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "recentInteraction",
                delaySeconds: 120),
            .refreshCompleted(timestamp: Self.now.addingTimeInterval(240)),
        ]

        let metrics = ReplayEngine.run(trace: trace, policy: CodingActivityAdaptivePolicy())

        #expect(metrics.totalRefreshCount == 2)
        #expect(metrics.codingActiveDecisionCount == 1)
    }

    @Test
    func `active compliance denominator excludes constrained decisions`() {
        let trace: [AdaptiveRefreshTraceRecord] = [
            .decision(
                timestamp: Self.now,
                menuAgeSeconds: nil,
                lowPowerModeEnabled: true,
                thermalState: .nominal,
                reason: "constrained",
                delaySeconds: 1800,
                codexActivitySeconds: 0),
            .refreshCompleted(timestamp: Self.now.addingTimeInterval(1800)),
        ]

        let metrics = ReplayEngine.run(trace: trace, policy: CodingActivityAdaptivePolicy())

        #expect(metrics.codingActiveDecisionCount == 0)
        #expect(metrics.codingActiveDelayViolationCount == 0)
    }

    @Test
    func `manual policy counts as slower than the active freshness cap`() {
        let trace: [AdaptiveRefreshTraceRecord] = [
            .decision(
                timestamp: Self.now,
                menuAgeSeconds: nil,
                lowPowerModeEnabled: false,
                thermalState: .nominal,
                reason: "longIdle",
                delaySeconds: 1800,
                codexActivitySeconds: 0),
            .refreshCompleted(timestamp: Self.now.addingTimeInterval(600)),
        ]

        let metrics = ReplayEngine.run(trace: trace, policy: ManualPolicy())

        #expect(metrics.codingActiveDecisionCount == 1)
        #expect(metrics.codingActiveDelayViolationCount == 1)
    }
}
