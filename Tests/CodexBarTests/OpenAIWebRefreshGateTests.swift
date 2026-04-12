import Foundation
import Testing
@testable import CodexBar

struct OpenAIWebRefreshGateTests {
    @Test("Battery saver keeps background OpenAI web refreshes off")
    func batterySaverDisablesBackgroundRefresh() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: true,
            force: false))

        #expect(shouldRun == false)
    }

    @Test("Disabling battery saver restores normal OpenAI web refreshes")
    func disabledBatterySaverAllowsBackgroundRefresh() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: false,
            force: false))

        #expect(shouldRun == true)
    }

    @Test("Manual refresh still forces OpenAI web refreshes with battery saver enabled")
    func manualRefreshBypassesBatterySaver() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: true,
            force: true))

        #expect(shouldRun == true)
    }

    @Test("Battery saver stale-submenu refresh respects the cooldown")
    func batterySaverStaleRefreshDoesNotForce() {
        let shouldForce = UsageStore.forceOpenAIWebRefreshForStaleRequest(batterySaverEnabled: true)

        #expect(shouldForce == false)
    }

    @Test("Normal stale-submenu refresh still forces when battery saver is off")
    func nonBatterySaverStaleRefreshForces() {
        let shouldForce = UsageStore.forceOpenAIWebRefreshForStaleRequest(batterySaverEnabled: false)

        #expect(shouldForce == true)
    }

    @Test("Recent successful dashboard refresh stays throttled")
    func recentSuccessSkipsRefresh() {
        let now = Date()

        let shouldSkip = UsageStore.shouldSkipOpenAIWebRefresh(.init(
            force: false,
            accountDidChange: false,
            lastError: nil,
            lastSnapshotAt: now.addingTimeInterval(-60),
            lastAttemptAt: now.addingTimeInterval(-60),
            now: now,
            refreshInterval: 300))

        #expect(shouldSkip == true)
    }

    @Test("Recent failed dashboard refresh also stays throttled")
    func recentFailureSkipsRefresh() {
        let now = Date()

        let shouldSkip = UsageStore.shouldSkipOpenAIWebRefresh(.init(
            force: false,
            accountDidChange: false,
            lastError: "login required",
            lastSnapshotAt: nil,
            lastAttemptAt: now.addingTimeInterval(-60),
            now: now,
            refreshInterval: 300))

        #expect(shouldSkip == true)
    }

    @Test("Force refresh bypasses throttle after failures")
    func forceRefreshBypassesCooldown() {
        let now = Date()

        let shouldSkip = UsageStore.shouldSkipOpenAIWebRefresh(.init(
            force: true,
            accountDidChange: false,
            lastError: "login required",
            lastSnapshotAt: nil,
            lastAttemptAt: now.addingTimeInterval(-60),
            now: now,
            refreshInterval: 300))

        #expect(shouldSkip == false)
    }

    @Test("Account switches bypass the prior-attempt cooldown")
    func accountChangeBypassesCooldown() {
        let now = Date()

        let shouldSkip = UsageStore.shouldSkipOpenAIWebRefresh(.init(
            force: false,
            accountDidChange: true,
            lastError: "mismatch",
            lastSnapshotAt: nil,
            lastAttemptAt: now.addingTimeInterval(-60),
            now: now,
            refreshInterval: 300))

        #expect(shouldSkip == false)
    }
}
