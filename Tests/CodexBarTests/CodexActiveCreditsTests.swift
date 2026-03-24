import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexActiveCreditsTests {
    @Test
    func `primary account uses store credits`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "CodexActiveCreditsTests-primary"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let now = Date()
        store.credits = CreditsSnapshot(remaining: 99, events: [], updatedAt: now)
        store.lastCreditsError = nil

        let result = store.codexActiveMenuCredits()
        #expect(result.snapshot?.remaining == 99)
        #expect(result.error == nil)
        #expect(result.unlimited == false)
        #expect(store.codexActiveCreditsRemaining() == 99)
    }

    @Test
    func `add-on account uses oauth account cost entry`() throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "CodexActiveCreditsTests-addon"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.addTokenAccount(provider: .codex, label: "Work", token: "/tmp/codex-work")
        let account = try #require(settings.tokenAccounts(for: .codex).first)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        store.credits = CreditsSnapshot(remaining: 1, events: [], updatedAt: Date())
        let updatedAt = Date()
        let entry = AccountCostEntry(
            id: account.id.uuidString,
            label: account.label,
            isDefault: false,
            creditsRemaining: 55,
            isUnlimited: false,
            planType: "Pro",
            primaryUsedPercent: 10,
            secondaryUsedPercent: 20,
            primaryResetDescription: "3h",
            secondaryResetDescription: "2d",
            error: nil,
            updatedAt: updatedAt)
        store._setAllAccountCreditsForTesting([entry], provider: .codex)

        let result = store.codexActiveMenuCredits()
        #expect(result.snapshot?.remaining == 55)
        #expect(result.error == nil)
        #expect(result.unlimited == false)
        #expect(store.codexActiveCreditsRemaining() == 55)
    }

    @Test
    func `primary oauth default row unlimited merges into menu credits`() {
        let now = Date()
        let defaultEntry = AccountCostEntry(
            id: "default",
            label: "Primary",
            isDefault: true,
            creditsRemaining: nil,
            isUnlimited: true,
            planType: "Pro",
            primaryUsedPercent: nil,
            secondaryUsedPercent: nil,
            primaryResetDescription: nil,
            secondaryResetDescription: nil,
            error: nil,
            updatedAt: now)
        let result = UsageStore.resolvePrimaryCodexCreditsFromOAuth(
            entries: [defaultEntry],
            rpcCredits: CreditsSnapshot(remaining: 5, events: [], updatedAt: now),
            rpcError: nil,
            costRefreshInFlight: false)
        #expect(result.snapshot == nil)
        #expect(result.error == nil)
        #expect(result.unlimited == true)
    }

    @Test
    func `primary oauth default row error wins over rpc credits`() {
        let now = Date()
        let defaultEntry = AccountCostEntry(
            id: "default",
            label: "Primary",
            isDefault: true,
            creditsRemaining: nil,
            isUnlimited: false,
            planType: nil,
            primaryUsedPercent: nil,
            secondaryUsedPercent: nil,
            primaryResetDescription: nil,
            secondaryResetDescription: nil,
            error: "unauthorized",
            updatedAt: now)
        let result = UsageStore.resolvePrimaryCodexCreditsFromOAuth(
            entries: [defaultEntry],
            rpcCredits: CreditsSnapshot(remaining: 99, events: [], updatedAt: now),
            rpcError: nil,
            costRefreshInFlight: false)
        #expect(result.snapshot == nil)
        #expect(result.error == "Token expired")
        #expect(result.unlimited == false)
    }

    @Test
    func `add-on unlimited reports unlimited flag`() throws {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "CodexActiveCreditsTests-unlimited"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.addTokenAccount(provider: .codex, label: "Team", token: "/tmp/codex-team")
        let account = try #require(settings.tokenAccounts(for: .codex).first)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let entry = AccountCostEntry(
            id: account.id.uuidString,
            label: account.label,
            isDefault: false,
            creditsRemaining: nil,
            isUnlimited: true,
            planType: "Team",
            primaryUsedPercent: nil,
            secondaryUsedPercent: nil,
            primaryResetDescription: nil,
            secondaryResetDescription: nil,
            error: nil,
            updatedAt: Date())
        store._setAllAccountCreditsForTesting([entry], provider: .codex)

        let result = store.codexActiveMenuCredits()
        #expect(result.snapshot == nil)
        #expect(result.unlimited == true)
        #expect(store.codexActiveCreditsRemaining() == nil)
    }

    @Test
    func `api key account shows api credits message instead of oauth error`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "CodexActiveCreditsTests-apikey"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.addTokenAccount(provider: .codex, label: "Attune API Test", token: "apikey:sk-test")

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        let result = store.codexActiveMenuCredits()
        #expect(result.snapshot == nil)
        #expect(result.unlimited == false)
        #expect(result.error?.contains("Attune API Test") == true)
        #expect(result.error?.contains("Subscription Utilization") == true)
        #expect(result.error?.localizedCaseInsensitiveContains("oauth token expired") == false)
    }
}
