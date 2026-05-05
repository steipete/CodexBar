import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexConsumerProjectionTests {
    @Test
    func `live card projection compacts weekly lanes and attaches dashboard extras`() {
        let store = self.makeStore(suite: "CodexConsumerProjectionTests-live-card")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: RateWindow(
                    usedPercent: 25,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        store.credits = CreditsSnapshot(remaining: 42, events: [], updatedAt: now)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: 88,
            codeReviewLimit: RateWindow(
                usedPercent: 12,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(7200),
                resetDescription: nil),
            creditEvents: [],
            dailyBreakdown: [OpenAIDashboardDailyBreakdown(day: "2024-01-01", services: [], totalCreditsUsed: 3)],
            usageBreakdown: [OpenAIDashboardDailyBreakdown(day: "2024-01-01", services: [], totalCreditsUsed: 4)],
            creditsPurchaseURL: "https://chatgpt.com/settings/billing",
            updatedAt: now)
        store.openAIDashboardAttachmentAuthorized = true
        store.openAIDashboardRequiresLogin = false

        let projection = store.codexConsumerProjection(surface: .liveCard, now: now)

        #expect(projection.visibleRateLanes == [.weekly])
        #expect(projection.planUtilizationLanes.map(\.role.rawValue) == ["weekly"])
        #expect(projection.dashboardVisibility == .attached)
        #expect(projection.supplementalMetrics == [.codeReview])
        #expect(projection.remainingPercent(for: .codeReview) == 88)
        #expect(projection.credits?.remaining == 42)
        #expect(projection.canShowBuyCredits)
        #expect(projection.hasUsageBreakdown)
        #expect(projection.hasCreditsHistory)
    }

    @Test
    func `display only dashboard stays visible without attached extras`() {
        let store = self.makeStore(suite: "CodexConsumerProjectionTests-display-only")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 15,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 30,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: 66,
            creditEvents: [],
            dailyBreakdown: [OpenAIDashboardDailyBreakdown(day: "2024-01-01", services: [], totalCreditsUsed: 3)],
            usageBreakdown: [OpenAIDashboardDailyBreakdown(day: "2024-01-01", services: [], totalCreditsUsed: 4)],
            creditsPurchaseURL: "https://chatgpt.com/settings/billing",
            updatedAt: now)
        store.openAIDashboardAttachmentAuthorized = false
        store.openAIDashboardRequiresLogin = false

        let projection = store.codexConsumerProjection(surface: .liveCard, now: now)

        #expect(projection.dashboardVisibility == .displayOnly)
        #expect(projection.supplementalMetrics.isEmpty)
        #expect(projection.canShowBuyCredits)
        #expect(!projection.hasUsageBreakdown)
        #expect(!projection.hasCreditsHistory)
    }

    @Test
    func `override card projection does not pull live codex adjuncts`() {
        let store = self.makeStore(suite: "CodexConsumerProjectionTests-override")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 18,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)
        store.credits = CreditsSnapshot(remaining: 42, events: [], updatedAt: now)
        store.lastCreditsError = "Frame load interrupted"
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "codex@example.com",
            codeReviewRemainingPercent: 88,
            creditEvents: [],
            dailyBreakdown: [OpenAIDashboardDailyBreakdown(day: "2024-01-01", services: [], totalCreditsUsed: 3)],
            usageBreakdown: [OpenAIDashboardDailyBreakdown(day: "2024-01-01", services: [], totalCreditsUsed: 4)],
            creditsPurchaseURL: "https://chatgpt.com/settings/billing",
            updatedAt: now)
        store.openAIDashboardAttachmentAuthorized = true
        store.openAIDashboardRequiresLogin = false
        store._setErrorForTesting("Live codex error", provider: .codex)

        let overrideSnapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 55,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(1200),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)

        let projection = store.codexConsumerProjection(
            surface: .overrideCard,
            snapshotOverride: overrideSnapshot,
            errorOverride: "Override error",
            now: now)

        #expect(projection.visibleRateLanes == [.session])
        #expect(projection.dashboardVisibility == .hidden)
        #expect(projection.credits == nil)
        #expect(projection.supplementalMetrics.isEmpty)
        #expect(!projection.canShowBuyCredits)
        #expect(!projection.hasUsageBreakdown)
        #expect(!projection.hasCreditsHistory)
        #expect(projection.userFacingErrors.usage == "Override error")
        #expect(projection.userFacingErrors.credits == nil)
        #expect(projection.userFacingErrors.dashboard == nil)
    }

    @Test
    func `menu bar projection flags credits fallback on exhaustion`() {
        let store = self.makeStore(suite: "CodexConsumerProjectionTests-menu-bar")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                updatedAt: now),
            provider: .codex)
        store.credits = CreditsSnapshot(remaining: 80, events: [], updatedAt: now)

        let projection = store.codexConsumerProjection(surface: .menuBar, now: now)

        #expect(projection.menuBarFallback == .creditsBalance)
    }

    @Test
    func `live card projection keeps buy credits available without dashboard purchase URL`() {
        let store = self.makeStore(suite: "CodexConsumerProjectionTests-buy-credits")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now),
            provider: .codex)
        store.credits = CreditsSnapshot(remaining: 42, events: [], updatedAt: now)
        store.openAIDashboardAttachmentAuthorized = false
        store.openAIDashboardRequiresLogin = false

        let projection = store.codexConsumerProjection(surface: .liveCard, now: now)

        #expect(projection.canShowBuyCredits)
    }

    @Test
    func `menu bar projection keeps credits fallback when credits load before usage`() {
        let store = self.makeStore(suite: "CodexConsumerProjectionTests-menu-bar-credits-only")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        store._setSnapshotForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: 80, events: [], updatedAt: now)

        let projection = store.codexConsumerProjection(surface: .menuBar, now: now)

        #expect(projection.menuBarFallback == .creditsBalance)
        #expect(!projection.hasExhaustedRateLane)
    }

    private func makeStore(suite: String) -> UsageStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())

        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }
}
