import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CodexActiveCreditsTests {
    @Test
    func `primary account uses store credits`() throws {
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
}
