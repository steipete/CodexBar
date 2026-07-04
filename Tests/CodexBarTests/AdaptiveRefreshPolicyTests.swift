import Foundation
import Testing
@testable import CodexBar

struct AdaptiveRefreshPolicyTests {
    private static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func input(
        ageSeconds: TimeInterval?,
        lowPowerModeEnabled: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal) -> AdaptiveRefreshPolicy.Input
    {
        let lastMenuOpenAt = ageSeconds.map { Self.referenceNow.addingTimeInterval(-$0) }
        return AdaptiveRefreshPolicy.Input(
            now: Self.referenceNow,
            lastMenuOpenAt: lastMenuOpenAt,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState)
    }

    @Test(arguments: [
        (-600.0, AdaptiveRefreshPolicy.Reason.recentInteraction, 120),
        (0.0, .recentInteraction, 120),
        (299.0, .recentInteraction, 120),
        (300.0, .recentInteraction, 120),
        (301.0, .warm, 300),
        (3599.0, .warm, 300),
        (3600.0, .warm, 300),
        (3601.0, .idle, 900),
        (14399.0, .idle, 900),
        (14400.0, .longIdle, 1800),
        (100_000.0, .longIdle, 1800)
    ])
    func `age determines the table boundary`(
        ageSeconds: TimeInterval,
        expectedReason: AdaptiveRefreshPolicy.Reason,
        expectedDelaySeconds: Int)
    {
        let decision = AdaptiveRefreshPolicy().nextDelay(for: self.input(ageSeconds: ageSeconds))
        #expect(decision.reason == expectedReason)
        #expect(decision.delay == .seconds(expectedDelaySeconds))
    }

    @Test
    func `nil last menu open is treated as long idle`() {
        let decision = AdaptiveRefreshPolicy().nextDelay(for: self.input(ageSeconds: nil))
        #expect(decision.reason == .longIdle)
        #expect(decision.delay == .seconds(30 * 60))
    }

    @Test
    func `constrained wins even when no menu open is recorded`() {
        let lowPower = AdaptiveRefreshPolicy().nextDelay(for: self.input(
            ageSeconds: nil,
            lowPowerModeEnabled: true))
        #expect(lowPower.reason == .constrained)

        let critical = AdaptiveRefreshPolicy().nextDelay(for: self.input(
            ageSeconds: nil,
            thermalState: .critical))
        #expect(critical.reason == .constrained)
    }

    @Test
    func `low power mode wins over recent interaction`() {
        let decision = AdaptiveRefreshPolicy().nextDelay(for: self.input(
            ageSeconds: 0,
            lowPowerModeEnabled: true))
        #expect(decision.reason == .constrained)
        #expect(decision.delay == .seconds(30 * 60))
    }

    @Test(arguments: [ProcessInfo.ThermalState.serious, .critical])
    func `serious and critical thermal states force the constrained branch`(
        thermalState: ProcessInfo.ThermalState)
    {
        let decision = AdaptiveRefreshPolicy().nextDelay(for: self.input(
            ageSeconds: 0,
            thermalState: thermalState))
        #expect(decision.reason == .constrained)
        #expect(decision.delay == .seconds(30 * 60))
    }

    @Test(arguments: [ProcessInfo.ThermalState.nominal, .fair])
    func `nominal and fair thermal states do not force the constrained branch`(
        thermalState: ProcessInfo.ThermalState)
    {
        let decision = AdaptiveRefreshPolicy().nextDelay(for: self.input(
            ageSeconds: 0,
            thermalState: thermalState))
        #expect(decision.reason != .constrained)
        #expect(decision.reason == .recentInteraction)
    }

    @Test
    func `future or clock-adjusted timestamps read as recent and never go negative`() {
        let farFuture = self.input(ageSeconds: -1_000_000)
        let decision = AdaptiveRefreshPolicy().nextDelay(for: farFuture)
        #expect(decision.reason == .recentInteraction)
        #expect(decision.delay == .seconds(2 * 60))
        #expect(decision.delay > .zero)
    }

    @Test
    func `every decision stays within the two to thirty minute bounds`() {
        let ages: [TimeInterval?] = [
            nil, -1_000_000, -600, 0, 300, 301, 3600, 3601, 14399, 14400, 1_000_000,
        ]
        let lowPowerModes = [false, true]
        let thermalStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

        for age in ages {
            for lowPowerModeEnabled in lowPowerModes {
                for thermalState in thermalStates {
                    let decision = AdaptiveRefreshPolicy().nextDelay(for: self.input(
                        ageSeconds: age,
                        lowPowerModeEnabled: lowPowerModeEnabled,
                        thermalState: thermalState))
                    #expect(decision.delay >= .seconds(2 * 60))
                    #expect(decision.delay <= .seconds(30 * 60))
                }
            }
        }
    }
}
