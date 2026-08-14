import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct OpenAIWebRefreshGateTests {
    @Test
    func `Battery saver keeps background OpenAI web refreshes off`() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: true,
            force: false,
            refreshPhase: .regular))

        #expect(shouldRun == false)
    }

    @Test
    func `Disabling battery saver restores normal OpenAI web refreshes`() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: false,
            force: false,
            refreshPhase: .regular))

        #expect(shouldRun == true)
    }

    @Test
    func `Manual refresh still forces OpenAI web refreshes with battery saver enabled`() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: true,
            force: true,
            refreshPhase: .regular))

        #expect(shouldRun == true)
    }

    @Test
    func `Startup skips automatic OpenAI web refreshes`() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: false,
            force: false,
            refreshPhase: .startup))

        #expect(shouldRun == false)
    }

    @Test
    func `Startup connectivity retry remains startup only for OpenAI web refresh gate`() {
        let providerPhase = UsageStore.refreshPhase(
            hasCompletedInitialRefresh: true)
        let openAIWebPhase = UsageStore.openAIWebRefreshPhase(
            providerRefreshPhase: providerPhase,
            startupConnectivityRetryAttempt: 1)
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: false,
            force: false,
            refreshPhase: openAIWebPhase))

        #expect(providerPhase == .regular)
        #expect(openAIWebPhase == .startup)
        #expect(shouldRun == false)
    }

    @Test
    func `Manual startup refresh still forces OpenAI web refreshes`() {
        let shouldRun = UsageStore.shouldRunOpenAIWebRefresh(.init(
            accessEnabled: true,
            batterySaverEnabled: true,
            force: true,
            refreshPhase: .startup))

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

    @Test
    func `Empty dashboard history retry is throttled after a recent attempt`() {
        let now = Date()

        let shouldSkip = UsageStore.shouldSkipOpenAIWebEmptyHistoryRetry(.init(
            force: false,
            accountDidChange: false,
            lastError: nil,
            lastSnapshotAt: now.addingTimeInterval(-120),
            lastAttemptAt: now.addingTimeInterval(-60),
            now: now,
            refreshInterval: 300))

        #expect(shouldSkip == true)
    }

    @Test
    func `code review alone is not dashboard page history`() {
        let snapshot = OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            codeReviewRemainingPercent: 80,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        #expect(!UsageStore.dashboardHasPageHistory(snapshot))
    }

    @Test
    func `cached history without an in memory scrape stamp does not scrape`() {
        let now = Date()
        let shouldScrape = UsageStore.shouldAllowOpenAIDashboardPageScrape(.init(
            force: false,
            userInitiated: false,
            hasHistory: true,
            lastPageScrapeAt: nil,
            historyUpdatedAt: now.addingTimeInterval(-60),
            now: now,
            refreshInterval: 300))

        #expect(!shouldScrape)
    }

    @Test
    func `page scrape stays on when history has never been collected`() {
        let shouldScrape = UsageStore.shouldAllowOpenAIDashboardPageScrape(.init(
            force: false,
            userInitiated: false,
            hasHistory: false,
            lastPageScrapeAt: nil,
            historyUpdatedAt: nil,
            now: Date(),
            refreshInterval: 300))

        #expect(shouldScrape)
    }

    @Test
    func `page scrape is skipped when recent history already exists`() {
        let now = Date()
        let shouldScrape = UsageStore.shouldAllowOpenAIDashboardPageScrape(.init(
            force: false,
            userInitiated: false,
            hasHistory: true,
            lastPageScrapeAt: now.addingTimeInterval(-60),
            historyUpdatedAt: now.addingTimeInterval(-60),
            now: now,
            refreshInterval: 300))

        #expect(!shouldScrape)
    }

    @Test
    func `user initiated force refresh still scrapes recent history`() {
        let now = Date()
        let shouldScrape = UsageStore.shouldAllowOpenAIDashboardPageScrape(.init(
            force: true,
            userInitiated: true,
            hasHistory: true,
            lastPageScrapeAt: now.addingTimeInterval(-60),
            historyUpdatedAt: now.addingTimeInterval(-60),
            now: now,
            refreshInterval: 300))

        #expect(shouldScrape)
    }

    @Test
    func `background force refresh does not scrape recent history`() {
        let now = Date()
        let shouldScrape = UsageStore.shouldAllowOpenAIDashboardPageScrape(.init(
            force: true,
            userInitiated: false,
            hasHistory: true,
            lastPageScrapeAt: now.addingTimeInterval(-60),
            historyUpdatedAt: now.addingTimeInterval(-60),
            now: now,
            refreshInterval: 300))

        #expect(!shouldScrape)
    }

    @Test
    func `page scrape returns after the dashboard interval`() {
        let now = Date()
        let shouldScrape = UsageStore.shouldAllowOpenAIDashboardPageScrape(.init(
            force: false,
            userInitiated: false,
            hasHistory: true,
            lastPageScrapeAt: now.addingTimeInterval(-301),
            historyUpdatedAt: now.addingTimeInterval(-301),
            now: now,
            refreshInterval: 300))

        #expect(shouldScrape)
    }

    @Test
    func `Empty dashboard history retry runs once for a newer empty snapshot`() {
        let now = Date()

        let shouldSkip = UsageStore.shouldSkipOpenAIWebEmptyHistoryRetry(.init(
            force: false,
            accountDidChange: false,
            lastError: nil,
            lastSnapshotAt: now.addingTimeInterval(-60),
            lastAttemptAt: now.addingTimeInterval(-120),
            now: now,
            refreshInterval: 300))

        #expect(shouldSkip == false)
    }
}
