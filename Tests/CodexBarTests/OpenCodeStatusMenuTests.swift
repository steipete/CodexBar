import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct OpenCodeStatusMenuTests {
    @Test
    func oldWorkspaceResultsAreRejectedAfterSelectionChanges() throws {
        let suite = "OpenCodeStatusMenuTests-refresh-guard"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.addTokenAccount(provider: .opencode, label: "Shared", token: "auth=shared")
        let tokenAccount = try #require(settings.selectedTokenAccount(for: .opencode))
        let firstResult = settings.addOpenCodeWorkspace(
            tokenAccountID: tokenAccount.id,
            workspaceID: "wrk_ALPHA",
            label: "Alpha")
        #expect(firstResult == .saved)
        let first = try #require(settings.opencodeWorkspaceAccounts.accounts.first)
        let secondResult = settings.addOpenCodeWorkspace(
            tokenAccountID: tokenAccount.id,
            workspaceID: "wrk_BETA",
            label: "Beta")
        #expect(secondResult == .saved)
        let second = try #require(settings.opencodeWorkspaceAccounts.accounts.last)
        #expect(settings.setActiveOpenCodeWorkspace(id: first.id))
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        #expect(store.shouldApplyOpenCodeWorkspaceResult(expectedWorkspaceAccountID: first.id))
        #expect(settings.setActiveOpenCodeWorkspace(id: second.id))
        #expect(!store.shouldApplyOpenCodeWorkspaceResult(expectedWorkspaceAccountID: first.id))
        #expect(store.shouldApplyOpenCodeWorkspaceResult(expectedWorkspaceAccountID: second.id))
    }

    @Test
    func sharedCredentialWorkspacesRemainDistinctSelectableEntries() throws {
        let tokenAccountID = try #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"))
        let first = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccountID,
            workspaceID: "wrk_ALPHA",
            label: "Alpha"))
        let second = try #require(OpenCodeWorkspaceAccount(
            tokenAccountID: tokenAccountID,
            workspaceID: "wrk_BETA",
            label: "Beta"))

        let display = TokenAccountMenuDisplay.openCode(
            accounts: OpenCodeWorkspaceAccounts(accounts: [first, second]))

        #expect(display.entries.count == 2)
        #expect(display.entries[0].id != display.entries[1].id)
        #expect(display.entries.map(\.tokenAccountID) == [tokenAccountID, tokenAccountID])
    }
}
