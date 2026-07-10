import AdaptiveReplayKit
import Foundation

/// Adapter letting the production `AdaptiveRefreshPolicy`
/// conform to `ReplayPolicy`. `AdaptiveReplayKit` cannot import this app target, so it ships a
/// hand-mirrored copy of the policy table (`MirroredAdaptivePolicy`) for the standalone CLI to
/// use; this adapter is the other half of that story — it lets in-app tooling (phase 2: comparing
/// candidate policies against the TRUE live policy, not just the mirror) replay traces against
/// the real implementation. `AdaptiveReplayPolicyMirrorTests` asserts this adapter and the mirror
/// agree with the real policy case-for-case, so a drift between the two would fail loudly.
extension AdaptiveRefreshPolicy: ReplayPolicy {
    var name: String {
        "adaptive-live"
    }

    /// Mirrors `UsageStore.noteMenuOpened(at:)`'s adaptive-only advance guard, same as
    /// `MirroredAdaptivePolicy.advancesOnInteraction` in `AdaptiveReplayKit`.
    var advancesOnInteraction: Bool {
        true
    }

    func decide(_ input: ReplayPolicyInput) -> ReplayPolicyDecision {
        let decision = self.nextDelay(for: Input(
            now: input.now,
            lastMenuOpenAt: input.lastMenuOpenAt,
            lowPowerModeEnabled: input.lowPowerModeEnabled,
            thermalState: input.thermalState.asProcessInfoThermalState))
        return ReplayPolicyDecision(
            delaySeconds: TimeInterval(decision.delay.components.seconds),
            reason: decision.reason.rawValue)
    }
}

extension ReplayThermalState {
    fileprivate var asProcessInfoThermalState: ProcessInfo.ThermalState {
        switch self {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        }
    }
}
