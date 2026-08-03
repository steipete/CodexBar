import Foundation
import Testing
@testable import CodexBar

struct BackgroundWorkPowerPolicyTests {
    @Test
    func `disabled mode preserves requested automatic intervals`() {
        #expect(BackgroundWorkPowerPolicy.automaticInterval(nil, lowPowerModeEnabled: false) == nil)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(300, lowPowerModeEnabled: false) == 300)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(3600, lowPowerModeEnabled: false) == 3600)
    }

    @Test
    func `enabled mode clamps automatic intervals to thirty minutes`() {
        #expect(BackgroundWorkPowerPolicy.automaticInterval(nil, lowPowerModeEnabled: true) == nil)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(60, lowPowerModeEnabled: true) == 1800)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(1800, lowPowerModeEnabled: true) == 1800)
        #expect(BackgroundWorkPowerPolicy.automaticInterval(3600, lowPowerModeEnabled: true) == 3600)
    }

    @Test
    func `usage refresh wiring applies the shared policy`() {
        #expect(UsageStore.effectiveAutomaticRefreshInterval(
            60,
            lowPowerModeEnabled: false) == 60)
        #expect(UsageStore.effectiveAutomaticRefreshInterval(
            60,
            lowPowerModeEnabled: true) == 1800.0)
        #expect(UsageStore.effectiveAutomaticRefreshInterval(
            nil,
            lowPowerModeEnabled: true) == nil)
    }
}
