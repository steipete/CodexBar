import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CopilotAccountCreditEntitlementTests {
    @Test
    func `account credit entitlement overrides the global fallback`() throws {
        let settings = Self.makeSettingsStore()
        settings.copilotSeatCreditEntitlementRaw = "3000"
        settings.addTokenAccount(provider: .copilot, label: "Work", token: "token-1")
        let account = try #require(settings.selectedTokenAccount(for: .copilot))

        settings.updateTokenAccount(
            provider: .copilot,
            accountID: account.id,
            seatCreditEntitlement: "1500")

        let snapshot = settings.copilotSettingsSnapshot(tokenOverride: nil)
        #expect(snapshot.seatCreditEntitlement == 1500)
        // The global values stay untouched as the fallback for accounts without an override.
        #expect(settings.copilotSeatCreditEntitlementRaw == "3000")
    }

    @Test
    func `credit entitlements fall back to the global values when the account has none`() {
        let settings = Self.makeSettingsStore()
        settings.copilotSeatCreditEntitlementRaw = "3000"
        settings.addTokenAccount(provider: .copilot, label: "Legacy", token: "token-1")

        let snapshot = settings.copilotSettingsSnapshot(tokenOverride: nil)

        #expect(snapshot.seatCreditEntitlement == 3000)
    }

    @Test
    func `credit entitlements follow the selected account`() throws {
        let settings = Self.makeSettingsStore()
        settings.copilotSeatCreditEntitlementRaw = "3000"
        settings.addTokenAccount(provider: .copilot, label: "Personal", token: "token-1")
        settings.addTokenAccount(provider: .copilot, label: "Work", token: "token-2")
        let accounts = settings.tokenAccounts(for: .copilot)
        let personal = try #require(accounts.first { $0.label == "Personal" })
        let work = try #require(accounts.first { $0.label == "Work" })
        settings.updateTokenAccount(
            provider: .copilot,
            accountID: personal.id,
            seatCreditEntitlement: "300")
        settings.updateTokenAccount(
            provider: .copilot,
            accountID: work.id,
            seatCreditEntitlement: "4500")

        settings.setActiveTokenAccountIndex(0, for: .copilot)
        #expect(settings.copilotSettingsSnapshot(tokenOverride: nil).seatCreditEntitlement == 300)

        settings.setActiveTokenAccountIndex(1, for: .copilot)
        #expect(settings.copilotSettingsSnapshot(tokenOverride: nil).seatCreditEntitlement == 4500)
    }

    @Test
    func `account credit entitlements persist through the config store`() throws {
        let suite = "CopilotAccountCreditEntitlementTests-persistence"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let first = Self.makeSettingsStore(userDefaults: defaults, configStore: configStore)

        first.addTokenAccount(provider: .copilot, label: "Work", token: "token-1")
        let account = try #require(first.selectedTokenAccount(for: .copilot))
        first.updateTokenAccount(
            provider: .copilot,
            accountID: account.id,
            seatCreditEntitlement: "1500")

        let reloadedStore = testConfigStore(suiteName: suite, reset: false)
        let second = Self.makeSettingsStore(userDefaults: defaults, configStore: reloadedStore)
        let reloaded = try #require(second.selectedTokenAccount(for: .copilot))
        #expect(reloaded.seatCreditEntitlement == "1500")
        let snapshot = second.copilotSettingsSnapshot(tokenOverride: nil)
        #expect(snapshot.seatCreditEntitlement == 1500)
    }

    private static func makeSettingsStore(
        suiteName: String = "CopilotAccountCreditEntitlementTests")
        -> SettingsStore
    {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        return Self.makeSettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suiteName))
    }

    private static func makeSettingsStore(
        userDefaults: UserDefaults,
        configStore: CodexBarConfigStore)
        -> SettingsStore
    {
        SettingsStore(
            userDefaults: userDefaults,
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
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            antigravityOAuthCredentialsStore: AntigravityOAuthCredentialsStore())
    }
}
