import AdaptiveRefreshCore
import Foundation
import Testing

struct AdaptiveRefreshPolicyCoreTests {
    private static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func input(
        ageSeconds: TimeInterval?,
        lowPowerModeEnabled: Bool = false,
        thermalPressure: AdaptiveRefreshPolicyCore.ThermalPressure = .nominal)
        -> AdaptiveRefreshPolicyCore.Input
    {
        AdaptiveRefreshPolicyCore.Input(
            now: Self.referenceNow,
            lastMenuOpenAt: ageSeconds.map { Self.referenceNow.addingTimeInterval(-$0) },
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
