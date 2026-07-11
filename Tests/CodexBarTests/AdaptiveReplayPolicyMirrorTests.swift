import AdaptiveReplayKit
import Foundation
import Testing
@testable import CodexBar

/// Guards the hand-copied policy table used by the standalone replay kit. The mirror must agree
/// with the real `AdaptiveRefreshPolicy` at every boundary the existing policy tests exercise.
/// Mutation-red: temporarily change any constant in `MirroredAdaptivePolicy` (for example,
/// `warmDelay` from 5*60 to 6*60) and this test fails.
struct AdaptiveReplayPolicyMirrorTests {
    private static let referenceNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static let ages: [TimeInterval?] = [
        nil, -1_000_000, -600, 0, 299, 300, 301, 3599, 3600, 3601, 14399, 14400, 100_000,
    ]
    private static let lowPowerModes = [false, true]
    private static let thermalStates: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]

    private func realInput(
        ageSeconds: TimeInterval?,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState) -> AdaptiveRefreshPolicy.Input
    {
        let lastMenuOpenAt = ageSeconds.map { Self.referenceNow.addingTimeInterval(-$0) }
        return AdaptiveRefreshPolicy.Input(
            now: Self.referenceNow,
            lastMenuOpenAt: lastMenuOpenAt,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState)
    }

    private func replayInput(
        ageSeconds: TimeInterval?,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState) -> ReplayPolicyInput
    {
        let lastMenuOpenAt = ageSeconds.map { Self.referenceNow.addingTimeInterval(-$0) }
        return ReplayPolicyInput(
            now: Self.referenceNow,
            lastMenuOpenAt: lastMenuOpenAt,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: self.replayThermalState(thermalState))
    }

    private func replayThermalState(_ state: ProcessInfo.ThermalState) -> ReplayThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    @Test
    func `mirrored policy matches the real policy across the boundary table`() {
        let mirror = MirroredAdaptivePolicy()
        for age in Self.ages {
            for lowPower in Self.lowPowerModes {
                for thermalState in Self.thermalStates {
                    let real = AdaptiveRefreshPolicy().nextDelay(for: self.realInput(
                        ageSeconds: age,
                        lowPowerModeEnabled: lowPower,
                        thermalState: thermalState))
                    let mirrored = mirror.decide(self.replayInput(
                        ageSeconds: age,
                        lowPowerModeEnabled: lowPower,
                        thermalState: thermalState))

                    #expect(mirrored.reason == real.reason.rawValue)
                    #expect(mirrored.delaySeconds == TimeInterval(real.delay.components.seconds))
                }
            }
        }
    }

    /// `UsageStore.noteMenuOpened(at:)` only ever advances the timer in adaptive mode (see the
    /// `settings.refreshFrequency == .adaptive` guard), so the mirror must report
    /// `advancesOnInteraction == true`; otherwise replay would miss that production behavior.
    @Test
    func `the adaptive policy mirror advances on interaction`() {
        #expect(MirroredAdaptivePolicy().advancesOnInteraction)
    }

    /// Baseline policies default to `advancesOnInteraction == false` via the protocol extension,
    /// matching fixed-cadence and manual refresh frequencies, which never wire up
    /// `noteMenuOpened(at:)`'s advance check at all.
    @Test
    func `baseline policies never advance on interaction`() {
        #expect(!FixedIntervalPolicy(minutes: 5).advancesOnInteraction)
        #expect(!ManualPolicy().advancesOnInteraction)
    }
}
