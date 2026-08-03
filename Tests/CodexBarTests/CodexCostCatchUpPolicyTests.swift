import Foundation
import Testing
@testable import CodexBar

struct CodexCostCatchUpPolicyTests {
    @Test
    func `automatic mode targets twenty percent duty cycle on AC power`() {
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .automatic,
            previousActiveDuration: 2,
            powerSource: .ac,
            lowPowerModeEnabled: false,
            thermalState: .nominal))

        #expect(decision == .init(action: .runAfter(8), targetDutyCycle: 0.2))
    }

    @Test
    func `automatic mode targets five percent duty cycle on battery`() {
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .automatic,
            previousActiveDuration: 2,
            powerSource: .battery,
            lowPowerModeEnabled: false,
            thermalState: .nominal))

        guard case let .runAfter(delay) = decision.action else {
            Issue.record("Expected automatic battery catch-up to schedule another pass")
            return
        }
        #expect(abs(delay - 38) < 0.000_001)
        #expect(decision.targetDutyCycle == 0.05)
    }

    @Test
    func `automatic mode pauses for low power mode`() {
        let decision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .automatic,
            previousActiveDuration: 2,
            powerSource: .battery,
            lowPowerModeEnabled: true,
            thermalState: .nominal))

        #expect(decision == .init(
            action: .pause(CodexCostCatchUpPolicy.constrainedRetryDelay, .lowPower),
            targetDutyCycle: nil))
    }

    @Test
    func `accelerated mode ignores low power but not critical thermal pressure`() {
        let lowPowerDecision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .accelerated,
            previousActiveDuration: 2,
            powerSource: .battery,
            lowPowerModeEnabled: true,
            thermalState: .serious))
        let criticalDecision = CodexCostCatchUpPolicy().decision(for: .init(
            mode: .accelerated,
            previousActiveDuration: 2,
            powerSource: .ac,
            lowPowerModeEnabled: false,
            thermalState: .critical))

        #expect(lowPowerDecision == .init(action: .runAfter(0), targetDutyCycle: 1))
        #expect(criticalDecision == .init(
            action: .pause(CodexCostCatchUpPolicy.constrainedRetryDelay, .thermal),
            targetDutyCycle: nil))
    }
}
