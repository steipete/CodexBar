import AdaptiveRefreshCore
import Foundation
import Testing

struct AdaptiveRefreshPolicyCoreTests {
    private static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func input(
        ageSeconds: TimeInterval?,
        codingActivityAgeSeconds: TimeInterval? = nil,
        lowPowerModeEnabled: Bool = false,
        thermalPressure: AdaptiveRefreshPolicyCore.ThermalPressure = .nominal)
        -> AdaptiveRefreshPolicyCore.Input
    {
        AdaptiveRefreshPolicyCore.Input(
            now: Self.referenceNow,
            lastMenuOpenAt: ageSeconds.map { Self.referenceNow.addingTimeInterval(-$0) },
            lastCodingActivityAt: codingActivityAgeSeconds.map { Self.referenceNow.addingTimeInterval(-$0) },
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalPressure: thermalPressure)
    }

    @Test(arguments: [
        (-600.0, AdaptiveRefreshPolicyCore.Reason.recentInteraction, 120),
        (0.0, .recentInteraction, 120),
        (299.0, .recentInteraction, 120),
        (300.0, .recentInteraction, 120),
        (301.0, .warm, 300),
        (3599.0, .warm, 300),
        (3600.0, .warm, 300),
        (3601.0, .idle, 900),
        (14399.0, .idle, 900),
        (14400.0, .longIdle, 1800),
        (100_000.0, .longIdle, 1800),
    ])
    func `age determines the canonical table boundary`(
        ageSeconds: TimeInterval,
        expectedReason: AdaptiveRefreshPolicyCore.Reason,
        expectedDelaySeconds: Int)
    {
        let decision = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(ageSeconds: ageSeconds))
        #expect(decision.reason == expectedReason)
        #expect(decision.delay == .seconds(expectedDelaySeconds))
    }

    @Test
    func `nil last menu open is long idle`() {
        let decision = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(ageSeconds: nil))
        #expect(decision.reason == .longIdle)
        #expect(decision.delay == .seconds(30 * 60))
    }

    @Test
    func `low power mode wins over recent interaction`() {
        let decision = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(
            ageSeconds: 0,
            lowPowerModeEnabled: true))
        #expect(decision.reason == .constrained)
        #expect(decision.delay == .seconds(30 * 60))
    }

    @Test
    func `thermal pressure wins when no menu open is recorded`() {
        let decision = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(
            ageSeconds: nil,
            thermalPressure: .constrained))
        #expect(decision.reason == .constrained)
        #expect(decision.delay == .seconds(30 * 60))
    }

    @Test(arguments: [TimeInterval(3601), 14400, 100_000])
    func `recent coding activity caps slower menu decisions at five minutes`(ageSeconds: TimeInterval) {
        let decision = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(
            ageSeconds: ageSeconds,
            codingActivityAgeSeconds: 0))
        #expect(decision.reason == .codingActivity)
        #expect(decision.delay == .seconds(5 * 60))
    }

    @Test
    func `coding activity does not lengthen recent or warm decisions`() {
        let recent = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(
            ageSeconds: 0,
            codingActivityAgeSeconds: 0))
        let warm = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(
            ageSeconds: 301,
            codingActivityAgeSeconds: 0))
        #expect(recent.reason == .recentInteraction)
        #expect(recent.delay == .seconds(2 * 60))
        #expect(warm.reason == .warm)
        #expect(warm.delay == .seconds(5 * 60))
    }

    @Test
    func `constraints win and the coding activity boundary is exclusive`() {
        let constrained = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(
            ageSeconds: nil,
            codingActivityAgeSeconds: 0,
            lowPowerModeEnabled: true))
        let insideBoundary = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(
            ageSeconds: nil,
            codingActivityAgeSeconds: 299))
        let atBoundary = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(
            ageSeconds: nil,
            codingActivityAgeSeconds: 300))
        #expect(constrained.reason == .constrained)
        #expect(constrained.delay == .seconds(30 * 60))
        #expect(insideBoundary.reason == .codingActivity)
        #expect(insideBoundary.delay == .seconds(5 * 60))
        #expect(atBoundary.reason == .longIdle)
        #expect(atBoundary.delay == .seconds(30 * 60))
    }

    @Test
    func `future timestamps read as recent`() {
        let decision = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(ageSeconds: -1_000_000))
        #expect(decision.reason == .recentInteraction)
        #expect(decision.delay == .seconds(2 * 60))
    }

    @Test
    func `every decision stays within the two to thirty minute bounds`() {
        let ages: [TimeInterval?] = [nil, -1_000_000, 0, 300, 301, 3600, 3601, 14399, 14400, 1_000_000]
        for age in ages {
            for lowPowerModeEnabled in [false, true] {
                for thermalPressure in [
                    AdaptiveRefreshPolicyCore.ThermalPressure.nominal,
                    .constrained,
                ] {
                    let decision = AdaptiveRefreshPolicyCore().nextDelay(for: self.input(
                        ageSeconds: age,
                        lowPowerModeEnabled: lowPowerModeEnabled,
                        thermalPressure: thermalPressure))
                    #expect(decision.delay >= .seconds(2 * 60))
                    #expect(decision.delay <= .seconds(30 * 60))
                }
            }
        }
    }

    @Test
    func `nominal heuristic interval remains five minutes`() {
        #expect(AdaptiveRefreshPolicyCore.nominalIntervalForHeuristics == 5 * 60)
    }
}
