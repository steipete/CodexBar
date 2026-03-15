import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct OpenAIWebAccountSwitchTests {
    @Test
    func clearsDashboardWhenCodexEmailChanges() {
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
    func keepsDashboardWhenCodexEmailStaysSame() {
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

    @Test
    func manualCodexTokenAccountsDoNotForceTargetEmail() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "OpenAIWebAccountSwitchTests-token-accounts"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual
        settings.codexCookieSource = .manual
        settings.addTokenAccount(provider: .codex, label: "personal", token: "session=first")
        settings.addTokenAccount(provider: .codex, label: "simon", token: "session=second")

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        store.snapshots[.codex] = UsageSnapshot(
            primary: nil,
            secondary: nil,
            tertiary: nil,
            providerCost: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "old@example.com",
                accountOrganization: nil,
                loginMethod: nil))

        let target = store.codexAccountEmailForOpenAIDashboard()
        #expect(target == nil)
    }

    @Test
    func clearsDashboardWhenTokenAccountChangesWithoutEmailTarget() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "OpenAIWebAccountSwitchTests-token-id-change"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.refreshFrequency = .manual

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let first = UUID()
        let second = UUID()
        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: nil, tokenAccountID: first)
        store.openAIDashboard = OpenAIDashboardSnapshot(
            signedInEmail: "first@example.com",
            codeReviewRemainingPercent: 100,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            updatedAt: Date())

        store.handleOpenAIWebTargetEmailChangeIfNeeded(targetEmail: nil, tokenAccountID: second)
        #expect(store.openAIDashboard == nil)
        #expect(store.openAIDashboardRequiresLogin == true)
        #expect(store.openAIDashboardCookieImportStatus?.contains("Codex account changed") == true)
    }
}
