import Foundation
import Testing
@testable import CodexBar

struct OpenAIWebRefreshGateTests {
    @Test
    func `Battery saver keeps background OpenAI web refreshes off`() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: true,
            force: false))

        #expect(shouldRun == false)
    }

    @Test
    func `Disabling battery saver restores normal OpenAI web refreshes`() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: false,
            force: false))

        #expect(shouldRun == true)
    }

    @Test
    func `Manual refresh still forces OpenAI web refreshes with battery saver enabled`() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: true,
            force: true))

        #expect(shouldRun == true)
    }

    @Test
    func `Battery saver stale-submenu refresh respects the cooldown`() {
        let shouldForce = UsageStore.forceOpenAIWebRefreshForStaleRequest(batterySaverEnabled: true)

        #expect(shouldForce == false)
    }

    @Test
    func `Normal stale-submenu refresh still forces when battery saver is off`() {
        let shouldForce = UsageStore.forceOpenAIWebRefreshForStaleRequest(batterySaverEnabled: false)

        #expect(shouldForce == true)
    }

    @Test
    func `Recent successful dashboard refresh stays throttled`() {
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

    @Test
    func `Recent failed dashboard refresh also stays throttled`() {
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

    @Test
    func `Force refresh bypasses throttle after failures`() {
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

    @Test
    func `Account switches bypass the prior-attempt cooldown`() {
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
