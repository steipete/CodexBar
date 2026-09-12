import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct KimiTokenAccountSourceRoutingTests {
    @Test(arguments: [
        ProviderSourceMode.auto,
        ProviderSourceMode.api,
        ProviderSourceMode.web,
    ])
    func `active token accounts route Kimi refreshes through web without persisting source`(
        configuredSource: ProviderSourceMode) throws
    {
        let settings = testSettingsStore(suiteName: "KimiTokenAccountSourceRoutingTests-\(configuredSource.rawValue)")
        settings.kimiUsageDataSource = configuredSource

        let implementation = KimiProviderImplementation()

        // No accounts: source mode follows the user's configured source.
        let noAccountMode = implementation.sourceMode(context: ProviderSourceModeContext(
            provider: .kimi,
            settings: settings))
        #expect(noAccountMode == configuredSource)

        // Add an account: source mode derives .web at fetch time.
        settings.addTokenAccount(
            provider: .kimi,
            label: "kimi-user",
            token: "kimi-auth-test-token")
        let storedAccount = try #require(settings.tokenAccounts(for: .kimi).first)
        let withAccountMode = implementation.sourceMode(context: ProviderSourceModeContext(
            provider: .kimi,
            settings: settings))
        #expect(withAccountMode == .web)

        // The persisted setting must NOT have been overwritten.
        #expect(settings.kimiUsageDataSource == configuredSource)

        // Remove the final account: falls back to the user's configured source.
        settings.removeTokenAccount(provider: .kimi, accountID: storedAccount.id)
        let afterRemovalMode = implementation.sourceMode(context: ProviderSourceModeContext(
            provider: .kimi,
            settings: settings))
        #expect(afterRemovalMode == configuredSource)
        #expect(settings.kimiUsageDataSource == configuredSource)
    }

    @Test
    func `adding account forces manual cookie source but preserves usage source`() throws {
        let settings = testSettingsStore(suiteName: "KimiTokenAccountSourceRoutingTests-cookie")
        settings.kimiUsageDataSource = .api
        settings.kimiCookieSource = .auto

        let implementation = KimiProviderImplementation()
        settings.addTokenAccount(
            provider: .kimi,
            label: "kimi-user",
            token: "kimi-auth-test-token")
        implementation.applyTokenAccountCookieSource(settings: settings)

        // Cookie source becomes manual (required to use per-account cookie header).
        #expect(settings.kimiCookieSource == .manual)
        // Usage source is untouched — routing is derived, not persisted.
        #expect(settings.kimiUsageDataSource == .api)
    }
}
