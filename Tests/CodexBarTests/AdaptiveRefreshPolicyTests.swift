import Foundation
import Testing
@testable import CodexBar

struct AdaptiveRefreshPolicyTests {
    private static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func decision(
        ageSeconds: TimeInterval? = 0,
        codingActivityAgeSeconds: TimeInterval? = nil,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState) -> AdaptiveRefreshPolicy.Decision
    {
        UsageStore.adaptiveRefreshDecision(
            now: Self.referenceNow,
            lastMenuOpenAt: ageSeconds.map { Self.referenceNow.addingTimeInterval(-$0) },
            lastCodingActivityAt: codingActivityAgeSeconds.map { Self.referenceNow.addingTimeInterval(-$0) },
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState)
    }

    @Test(arguments: [ProcessInfo.ThermalState.nominal, .fair])
    func `app adapter maps nominal and fair thermal states to unconstrained`(
        thermalState: ProcessInfo.ThermalState)
    {
        let decision = self.decision(lowPowerModeEnabled: false, thermalState: thermalState)
        #expect(decision.reason == .recentInteraction)
        #expect(decision.delay == .seconds(2 * 60))
    }

    @Test(arguments: [ProcessInfo.ThermalState.serious, .critical])
    func `app adapter maps serious and critical thermal states to constrained`(
        thermalState: ProcessInfo.ThermalState)
    {
        let decision = self.decision(lowPowerModeEnabled: false, thermalState: thermalState)
        #expect(decision.reason == .constrained)
        #expect(decision.delay == .seconds(30 * 60))
    }

    @Test
    func `app adapter preserves low power precedence`() {
        let decision = self.decision(lowPowerModeEnabled: true, thermalState: .nominal)
        #expect(decision.reason == .constrained)
        #expect(decision.delay == .seconds(30 * 60))
    }

    @Test
    func `app adapter forwards timestamps and nil history`() {
        let warm = self.decision(
            ageSeconds: 301,
            lowPowerModeEnabled: false,
            thermalState: .nominal)
        #expect(warm.reason == .warm)
        #expect(warm.delay == .seconds(5 * 60))

        let noHistory = self.decision(
            ageSeconds: nil,
            lowPowerModeEnabled: false,
            thermalState: .nominal)
        #expect(noHistory.reason == .longIdle)
        #expect(noHistory.delay == .seconds(30 * 60))
    }

    @Test
    func `app adapter forwards coding activity into the shared core`() {
        let decision = self.decision(
            ageSeconds: nil,
            codingActivityAgeSeconds: 0,
            lowPowerModeEnabled: false,
            thermalState: .nominal)
        #expect(decision.reason == .codingActivity)
        #expect(decision.delay == .seconds(5 * 60))
    }
}
