import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@MainActor
struct VeniceUsageSourceTests {
    @Test
    func `defaults venice usage source to auto and persists web`() {
        let store = testSettingsStore(
            suiteName: "VeniceUsageSourceTests-source", userDefaults: InMemoryUserDefaults())

        #expect(store.veniceUsageDataSource == .auto)
        store.veniceUsageDataSource = .web
        #expect(store.veniceUsageDataSource == .web)
        store.veniceUsageDataSource = .api
        #expect(store.veniceUsageDataSource == .api)
    }
}

extension VeniceUsageSourceTests {
    @Test
    func `web source leaves saved API accounts passive until explicitly selected`() {
        let account = Self.account()
        let settings = testSettingsStore(
            suiteName: #function, userDefaults: InMemoryUserDefaults(), config: Self.config(
                account: account,
                source: .api))
        #expect(settings.effectiveSelectedTokenAccount(for: .venice)?.id == account.id)
        settings.veniceUsageDataSource = .web
        #expect(settings.effectiveSelectedTokenAccount(for: .venice) == nil)
        #expect(settings.selectedTokenAccount(for: .venice)?.id == account.id)
        #expect(settings.tokenAccounts(for: .venice).count == 1)
        #expect(ProviderTokenAccountSelection
            .selectedAccount(provider: .venice, settings: settings, override: nil) == nil)
        let explicit = ProviderTokenAccountSelection.selectedAccount(
            provider: .venice, settings: settings, override: TokenAccountOverride(provider: .venice, account: account))
        #expect(explicit?.id == account.id)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        settings.multiAccountMenuLayout = .stacked
        #expect(!store.shouldFetchAllTokenAccounts(provider: .venice, accounts: [account, Self.account()]))
        settings.veniceCookieSource = .manual
        settings.veniceCookieHeader = "__venice-auth.session-token=synthetic"
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
        #expect(snapshot.venice?.cookieSource == .manual)
        #expect(snapshot.venice?.manualCookieHeader == settings.veniceCookieHeader)
        settings.veniceUsageDataSource = .api
        #expect(settings.effectiveSelectedTokenAccount(for: .venice)?.id == account.id)
    }

    @Test(arguments: [ProviderSourceMode.auto, .api, .web])
    func `CLI source override and explicit account selection retain distinct authority`(
        source: ProviderSourceMode) throws
    {
        let account = Self.account()
        for selection in [
            TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            TokenAccountCLISelection(label: "Fixture", index: nil, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: 0, allAccounts: false),
            TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
        ] {
            let context = try TokenAccountCLIContext(
                selection: selection,
                config: Self.config(account: account, source: source),
                verbose: false,
                baseEnvironment: [:])
            let configured = try context.resolvedAccounts(for: .venice)
            #expect(configured.isEmpty == (source == .web && !selection.usesOverride))
            let web = try context.resolvedAccounts(for: .venice, sourceMode: .web)
            let selected = web.first
            #expect(selected?.id == (selection.usesOverride ? account.id : nil))
            #expect(context.effectiveSourceMode(base: .web, provider: .venice, account: selected)
                == (selection.usesOverride ? .api : .web))
            #expect(context.environment(base: [:], provider: .venice, account: selected)["VENICE_API_KEY"]
                == (selection.usesOverride ? account.token : nil))
        }
    }

    private static func account() -> ProviderTokenAccount {
        ProviderTokenAccount(id: UUID(), label: "Fixture", token: "synthetic-venice-key", addedAt: 0, lastUsed: nil)
    }

    private static func config(account: ProviderTokenAccount, source: ProviderSourceMode) -> CodexBarConfig {
        CodexBarConfig(providers: [ProviderConfig(
            id: .venice,
            source: source,
            tokenAccounts: ProviderTokenAccountData(version: 1, accounts: [account], activeIndex: 0))])
    }
}
