import CodexBarCore
import Commander
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

private actor OpenRouterAccountFetchRecorder {
    struct Request: Sendable {
        let accountID: UUID?
        let accountValue: String?
    }

    private(set) var requests: [Request] = []

    func record(context: ProviderFetchContext) {
        self.requests.append(Request(
            accountID: context.selectedTokenAccountID,
            accountValue: context.env[OpenRouterSettingsReader.envKey]))
    }
}

private struct OpenRouterAccountFetchStrategy: ProviderFetchStrategy {
    let recorder: OpenRouterAccountFetchRecorder

    let id = "openrouter-account-test"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        await self.recorder.record(context: context)
        let accountValue = context.env[OpenRouterSettingsReader.envKey]
        let totalUsage = accountValue == "test-key" ? 10.0 : 40.0
        let usage = OpenRouterUsageSnapshot(
            totalCredits: 100,
            totalUsage: totalUsage,
            balance: 100 - totalUsage,
            usedPercent: totalUsage,
            keyDataFetched: true,
            keyLimit: 100,
            keyUsage: totalUsage,
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: totalUsage))
            .toUsageSnapshot()
        return self.makeResult(usage: usage, sourceLabel: self.id)
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

@MainActor
@Suite(.serialized)
struct OpenRouterMultiAccountTests {
    @Test
    func `catalog entry exposes OpenRouter accounts in provider settings`() throws {
        let support = try #require(TokenAccountSupportCatalog.support(for: .openrouter))
        #expect(support.title == "API keys")
        #expect(support.subtitle == "Store multiple OpenRouter API keys.")
        #expect(support.placeholder == "sk-or-v1-...")
        #expect(!support.requiresManualCookieSource)
        #expect(support.cookieName == nil)
        guard case let .environment(key) = support.injection else {
            Issue.record("Expected OpenRouter token accounts to use environment injection")
            return
        }
        #expect(key == OpenRouterSettingsReader.envKey)

        let settings = Self.makeSettings(suite: "OpenRouterMultiAccountTests-settings")
        let store = try Self.makeStore(settings: settings)
        let descriptor = try #require(
            ProvidersPane(settings: settings, store: store)._test_tokenAccountDescriptor(for: .openrouter))
        #expect(descriptor.provider == .openrouter)
        #expect(descriptor.title == support.title)
        #expect(descriptor.isVisible?() == true)
    }

    @Test
    func `two OpenRouter accounts fetch with isolated keys and caches`() async throws {
        let settings = Self.makeSettings(suite: "OpenRouterMultiAccountTests-fetch")
        settings.openRouterAPIToken = "decoy-token"
        settings.addTokenAccount(provider: .openrouter, label: "Personal", token: "test-key")
        settings.addTokenAccount(provider: .openrouter, label: "Work", token: "test-auth-token")
        let accounts = settings.tokenAccounts(for: .openrouter)
        let recorder = OpenRouterAccountFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)

        await store.refreshTokenAccounts(provider: .openrouter, accounts: accounts)

        let requests = await recorder.requests
        #expect(Set(requests.compactMap(\.accountValue)) == ["test-key", "test-auth-token"])
        #expect(Set(requests.compactMap(\.accountID)) == Set(accounts.map(\.id)))
        #expect(!requests.contains {
            $0.accountValue == "decoy-token" || $0.accountValue == "test-token-placeholder"
        })

        let snapshots = try #require(store.accountSnapshots[.openrouter])
        #expect(snapshots.map(\.account.id) == accounts.map(\.id))
        #expect(snapshots.map { $0.snapshot?.accountEmail(for: .openrouter) } == ["Personal", "Work"])
        #expect(snapshots.map(\.snapshot?.openRouterUsage?.balance) == [90, 60])
        #expect(Set(snapshots.map(\.cacheKey)).count == 2)

        settings.setActiveTokenAccountIndex(0, for: .openrouter)
        store.activateCachedTokenAccountSnapshot(provider: .openrouter, accountID: accounts[0].id)
        #expect(store.snapshot(for: .openrouter)?.openRouterUsage?.balance == 90)
        settings.setActiveTokenAccountIndex(1, for: .openrouter)
        store.activateCachedTokenAccountSnapshot(provider: .openrouter, accountID: accounts[1].id)
        #expect(store.snapshot(for: .openrouter)?.openRouterUsage?.balance == 60)
    }

    @Test
    func `OpenRouter menu projection supports stacked and segmented layouts`() async throws {
        let settings = Self.makeSettings(suite: "OpenRouterMultiAccountTests-menu")
        settings.addTokenAccount(provider: .openrouter, label: "Personal", token: "test-key")
        settings.addTokenAccount(provider: .openrouter, label: "Work", token: "test-auth-token")
        let accounts = settings.tokenAccounts(for: .openrouter)
        let recorder = OpenRouterAccountFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)
        await store.refreshTokenAccounts(provider: .openrouter, accounts: accounts)

        let fetcher = UsageFetcher(environment: [:])
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        settings.multiAccountMenuLayout = .stacked
        let stacked = try #require(controller.tokenAccountMenuDisplay(for: .openrouter))
        #expect(stacked.layout == .stacked)
        #expect(stacked.accounts.map(\.label) == ["Personal", "Work"])
        #expect(stacked.snapshots.map(\.account.id) == accounts.map(\.id))
        let cardModels = stacked.snapshots.compactMap {
            controller.tokenAccountMenuCardModel(for: .openrouter, accountSnapshot: $0)
        }
        #expect(cardModels.map(\.provider) == [.openrouter, .openrouter])
        #expect(cardModels.map(\.email) == ["Personal", "Work"])

        settings.multiAccountMenuLayout = .segmented
        let segmented = try #require(controller.tokenAccountMenuDisplay(for: .openrouter))
        #expect(segmented.layout == .segmented)
        #expect(segmented.activeIndex == 1)
        #expect(segmented.snapshots.isEmpty)
    }

    @Test
    func `OpenRouter CLI routes selected and all accounts`() throws {
        let accounts = [
            Self.account(label: "Personal", token: "test-key", seed: 1),
            Self.account(label: "Work", token: "test-auth-token", seed: 2),
        ]
        let config = CodexBarConfig(providers: [
            ProviderConfig(
                id: .openrouter,
                apiKey: "decoy-token",
                tokenAccounts: ProviderTokenAccountData(version: 1, accounts: accounts, activeIndex: 0)),
        ])
        let parser = CommandParser(signature: CodexBarCLI._usageSignatureForTesting())
        let selectedValues = try parser.parse(arguments: [
            "--provider", "openrouter",
            "--account", "Work",
        ])
        let allValues = try parser.parse(arguments: [
            "--provider", "openrouter",
            "--all-accounts",
        ])

        let selectedContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(
                label: selectedValues.options["account"]?.last,
                index: nil,
                allAccounts: false),
            config: config,
            verbose: false,
            baseEnvironment: [OpenRouterSettingsReader.envKey: "test-token-placeholder"])
        let selected = try selectedContext.resolvedAccounts(for: .openrouter)
        #expect(selected.map(\.label) == ["Work"])
        #expect(selectedContext.environment(
            base: [OpenRouterSettingsReader.envKey: "test-token-placeholder"],
            provider: .openrouter,
            account: selected[0])[OpenRouterSettingsReader.envKey] == "test-auth-token")

        let allContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(
                label: nil,
                index: nil,
                allAccounts: allValues.flags.contains("allAccounts")),
            config: config,
            verbose: false,
            baseEnvironment: [OpenRouterSettingsReader.envKey: "test-token-placeholder"])
        let all = try allContext.resolvedAccounts(for: .openrouter)
        #expect(all.map(\.label) == ["Personal", "Work"])
        #expect(all.map {
            allContext.environment(base: [:], provider: .openrouter, account: $0)[OpenRouterSettingsReader.envKey]
        } == ["test-key", "test-auth-token"])
    }

    private static func makeSettings(suite: String) -> SettingsStore {
        testSettingsStore(
            suiteName: "\(suite)-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeStore(
        settings: SettingsStore,
        recorder: OpenRouterAccountFetchRecorder? = nil) throws -> UsageStore
    {
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [OpenRouterSettingsReader.envKey: "test-token-placeholder"])
        guard let recorder else { return store }
        let baseSpec = try #require(store.providerSpecs[.openrouter])
        let baseDescriptor = baseSpec.descriptor
        let strategy = OpenRouterAccountFetchStrategy(recorder: recorder)
        store.providerSpecs[.openrouter] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .openrouter,
                metadata: baseDescriptor.metadata,
                branding: baseDescriptor.branding,
                tokenCost: baseDescriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .api],
                    pipeline: ProviderFetchPipeline { _ in [strategy] }),
                cli: baseDescriptor.cli),
            makeFetchContext: baseSpec.makeFetchContext)
        return store
    }

    private static func account(label: String, token: String, seed: UInt8) -> ProviderTokenAccount {
        ProviderTokenAccount(
            id: UUID(uuid: (seed, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, seed)),
            label: label,
            token: token,
            addedAt: TimeInterval(seed),
            lastUsed: nil)
    }
}
