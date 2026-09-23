import AppKit
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized)
struct KimiTokenAccountTests {
    private let ambient = [
        "KIMI_AUTH_TOKEN": "kimi-auth=ambient",
        "kimi_auth_token": "lowercase-ambient",
        "KIMI_MANUAL_COOKIE": "kimi-auth=manual-ambient",
        "KIMI_CODE_API_KEY": "api-ambient",
        "UNRELATED": "kept",
    ]

    private func account(_ token: String, label: String = "Fixture") -> ProviderTokenAccount {
        ProviderTokenAccount(id: UUID(), label: label, token: token, addedAt: 0, lastUsed: nil)
    }

    private func cli(region: KimiRegion = .china, accounts: [ProviderTokenAccount] = []) throws
        -> TokenAccountCLIContext
    {
        try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
            config: CodexBarConfig(providers: [ProviderConfig(
                id: .kimi,
                apiKey: "configured-api",
                cookieHeader: "kimi-auth=configured-cookie",
                cookieSource: .off,
                region: region.rawValue,
                tokenAccounts: ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: 0))]),
            verbose: false,
            baseEnvironment: [:])
    }

    @Test(arguments: KimiRegion.allCases, [ProviderSourceMode.auto, .api, .web])
    func `CLI selects labeled web accounts with isolated credentials in the configured region`(
        region: KimiRegion, source: ProviderSourceMode) async throws
    {
        let accounts = [
            self.account("eyJ.first.fixture", label: "Personal"),
            self.account("Cookie: kimi-auth=second; unrelated=value", label: "Work"),
        ]
        let cli = try self.cli(region: region, accounts: accounts)
        #expect(try cli.resolvedAccounts(for: .kimi).map(\.displayName) == ["Personal", "Work"])
        for (index, account) in accounts.enumerated() {
            let environment = cli.environment(base: self.ambient, provider: .kimi, account: account)
            #expect(environment == ["UNRELATED": "kept"])
            let snapshot = try #require(cli.settingsSnapshot(for: .kimi, account: account))
            #expect(snapshot.kimi?.region == region)
            #expect(snapshot.kimi?.cookieSource == .manual)
            let mode = cli.effectiveSourceMode(base: source, provider: .kimi, account: account)
            let context = self.context(environment: environment, settings: snapshot, source: mode)
            #expect(KimiCookieHeader.resolveCookieOverride(context: context)?.token ==
                (index == 0 ? "eyJ.first.fixture" : "second"))
            #expect(mode == .web)
            #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
                mode, provider: .kimi, environment: environment, settings: snapshot))
            let strategies = await KimiProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
            #expect(strategies.map(\.id) == ["kimi.web"])
        }
        #expect(cli.effectiveSourceMode(base: source, provider: .kimi, account: nil) == source)
    }

    @Test(arguments: [ProviderSourceMode.auto, .web], [ProviderCookieSource.auto, .off])
    func `automatic Kimi cookies still require browser support`(
        source: ProviderSourceMode, cookies: ProviderCookieSource)
    {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            source,
            provider: .kimi,
            environment: [:],
            settings: .make(kimi: .init(cookieSource: cookies, manualCookieHeader: nil))))
    }

    @Test(arguments: KimiRegion.allCases)
    func `each saved cookie fetches its own usage without automatic credential discovery`(
        region: KimiRegion) async throws
    {
        let accounts = [self.account("kimi-auth=first"), self.account("kimi-auth=second")]
        let cli = try self.cli(region: region, accounts: accounts)
        let strategy = KimiWebFetchStrategy(
            fetchUsage: { token, selectedRegion in
                #expect(selectedRegion == region)
                #expect(["first", "second"].contains(token))
                return KimiUsageSnapshot(
                    weekly: .init(limit: "100", used: token == "first" ? "25" : "75", remaining: nil, resetTime: nil),
                    rateLimit: nil,
                    updatedAt: Date(timeIntervalSince1970: 100))
            },
            desktopToken: { _ in Issue.record("Unexpected desktop import"); return nil },
            browserTokens: { _ in Issue.record("Unexpected browser import"); return [] },
            expiredBrowserSession: { _ in Issue.record("Unexpected browser import"); return false })
        for (index, account) in accounts.enumerated() {
            let snapshot = try #require(cli.settingsSnapshot(for: .kimi, account: account))
            let environment = cli.environment(base: self.ambient, provider: .kimi, account: account)
            let result = try await strategy.fetch(self.context(environment: environment, settings: snapshot))
            #expect(result.usage.primary?.usedPercent == (index == 0 ? 25 : 75))
        }
    }

    @Test(arguments: [ProviderSourceMode.auto, .api, .web], [ProviderCookieSource.auto, .manual, .off])
    @MainActor
    func `app account changes preserve preferences and per account region snapshots`(
        source: ProviderSourceMode, cookies: ProviderCookieSource) throws
    {
        let settings = self.settings()
        settings.kimiRegion = .international
        settings.kimiUsageDataSource = source
        settings.kimiCookieSource = cookies
        settings.kimiManualCookieHeader = "kimi-auth=original"
        settings.addTokenAccount(provider: .kimi, label: "Personal", token: "eyJ.first.fixture")
        let first = try #require(settings.selectedTokenAccount(for: .kimi))
        settings.addTokenAccount(provider: .kimi, label: "Work", token: "kimi-auth=second")
        let second = try #require(settings.selectedTokenAccount(for: .kimi))
        settings.setActiveTokenAccountIndex(0, for: .kimi)
        #expect(settings.effectiveSelectedTokenAccount(for: .kimi)?.id == first.id)
        for account in [first, second] {
            let override = TokenAccountOverride(provider: .kimi, account: account)
            let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: override)
            #expect(snapshot.kimi?.region == .international)
            #expect(snapshot.kimi?.cookieSource == .manual)
            #expect(snapshot.kimi?.manualCookieHeader == (account.id == first.id
                    ? "kimi-auth=eyJ.first.fixture" : "kimi-auth=second"))
            #expect(ProviderRegistry.resolvedSourceMode(provider: .kimi, settings: settings, account: account) == .web)
            #expect(ProviderRegistry.makeEnvironment(
                base: self.ambient, provider: .kimi, settings: settings, tokenOverride: override) ==
                ["UNRELATED": "kept"])
        }
        settings.updateTokenAccount(provider: .kimi, accountID: first.id, label: "Renamed")
        #expect(settings.tokenAccounts(for: .kimi).map(\.displayName) == ["Renamed", "Work"])
        settings.removeTokenAccount(provider: .kimi, accountID: first.id)
        #expect(settings.selectedTokenAccount(for: .kimi)?.id == second.id)
        settings.removeTokenAccount(provider: .kimi, accountID: second.id)
        #expect(settings.tokenAccounts(for: .kimi).isEmpty)
        #expect(ProviderRegistry.resolvedSourceMode(provider: .kimi, settings: settings, account: nil) == source)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
        #expect(snapshot.kimi?.cookieSource == cookies)
        #expect(snapshot.kimi?.manualCookieHeader == "kimi-auth=original")
        let saved = try #require(try settings.configStore.load()?.providerConfig(for: .kimi))
        #expect(saved.source == source)
        #expect(saved.cookieSource == cookies)
    }

    @Test(arguments: ["Cookie: unrelated=value", "kimi-auth=expired"])
    func `invalid saved credentials cannot fall back to another account`(token: String) async throws {
        let account = self.account(token)
        let cli = try self.cli(accounts: [account])
        let settings = try #require(cli.settingsSnapshot(for: .kimi, account: account))
        let environment = cli.environment(base: self.ambient, provider: .kimi, account: account)
        let strategy = KimiWebFetchStrategy(
            fetchUsage: { authToken, _ in
                #expect(authToken == "expired")
                throw KimiAPIError.invalidToken
            },
            desktopToken: { _ in Issue.record("Unexpected desktop import"); return nil },
            browserTokens: { _ in Issue.record("Unexpected browser import"); return [] },
            expiredBrowserSession: { _ in Issue.record("Unexpected browser import"); return false })
        do {
            _ = try await strategy.fetch(self.context(environment: environment, settings: settings))
            Issue.record("Expected saved credential failure")
        } catch KimiAPIError.missingToken {
            #expect(token == "Cookie: unrelated=value")
        } catch KimiAPIError.invalidToken {
            #expect(token == "kimi-auth=expired")
        }
    }

    @Test @MainActor
    func `existing account editor is discoverable before adding the first account`() throws {
        let settings = self.settings()
        let store = self.store(settings)
        let descriptor = try #require(ProvidersPane(settings: settings, store: store)
            .tokenAccountDescriptor(for: .kimi))
        #expect(descriptor.isVisible?() == true)
        #expect(descriptor.accounts().isEmpty)
        settings.addTokenAccount(provider: .kimi, label: "Personal", token: "eyJ.first.fixture")
        settings.addTokenAccount(provider: .kimi, label: "Work", token: "kimi-auth=second")
        #expect(descriptor.accounts().map(\.displayName) == ["Personal", "Work"])
        #expect(descriptor.primaryAddAction == nil)
    }

    @Test @MainActor
    func `render synthetic account settings when requested`() throws {
        guard let path = ProcessInfo.processInfo.environment["CODEXBAR_KIMI_ACCOUNTS_PROOF"] else { return }
        let settings = self.settings()
        settings.kimiRegion = .international
        settings.addTokenAccount(provider: .kimi, label: "Personal (synthetic)", token: "eyJ.first.fixture")
        settings.addTokenAccount(provider: .kimi, label: "Work (synthetic)", token: "kimi-auth=second")
        let store = self.store(settings)
        let descriptor = ProvidersPane(settings: settings, store: store).tokenAccountDescriptor(for: .kimi)
        let hosting = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
            Text("Kimi Code").font(.title2.bold())
            Text("Synthetic settings · International region").foregroundStyle(.secondary)
            if let descriptor, descriptor.isVisible?() ?? true {
                ProviderSettingsTokenAccountsRowView(descriptor: descriptor)
            } else {
                Text("Account editor unavailable").foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 740).background(Color(nsColor: .windowBackgroundColor)))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private func settings() -> SettingsStore {
        let settings = testSettingsStore(
            suiteName: "KimiTokenAccountTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled())
        settings.configFileWatcher?.stop()
        return settings
    }

    @MainActor
    private func store(_ settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
    }

    private func context(
        environment: [String: String],
        settings: ProviderSettingsSnapshot,
        source: ProviderSourceMode = .web) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .cli,
            sourceMode: source,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: KimiAccountClaudeStub(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }
}

private struct KimiAccountClaudeStub: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ClaudeUsageError.parseFailed("fixture")
    }

    func debugRawProbe(model _: String) async -> String { "fixture" }

    func detectVersion() -> String? { nil }
}
