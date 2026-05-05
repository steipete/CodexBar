import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct OpenAIWebAccountSwitchTests {
    @Test
    func `clears dashboard when codex email changes`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "OpenAIWebAccountSwitchTests-clears"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: "a@example.com")
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "a@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: "b@example.com")
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.openAIDashboardCookieImportStatus?.contains("Codex account changed") == true)
    }

    @Test
    func `keeps dashboard when codex email stays same`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "OpenAIWebAccountSwitchTests-keeps"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: "a@example.com")
        let dash = OpenAIDashboardSnapshot(
            signedInEmail: "a@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())
        store.openAIDashboard = dash

        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: "a@example.com")
        #expect(store.openAIDashboard == dash)
    }
}
