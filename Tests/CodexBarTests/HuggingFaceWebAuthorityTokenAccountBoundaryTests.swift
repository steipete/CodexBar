import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// FP-171 remediation: Hugging Face's browser-session wallet (Web authority) carries no identifier that can be
/// correlated with any API token account. These tests prove that Web-authority Hugging Face refreshes — explicit
/// Web mode and Cookie source Refresh's `.web` override — never fan out across stacked API token accounts, never
/// relabel the wallet with a token-account label, and never populate the per-token-account snapshot cache, while
/// ordinary Auto/API token-account fan-out, labeling, and caching remain unchanged.
private actor HuggingFaceAuthorityFetchRecorder {
    struct Request: Sendable {
        let sourceMode: ProviderSourceMode
        let accountID: UUID?
    }

    private(set) var apiRequests: [Request] = []
    private(set) var webRequests: [Request] = []

    func recordAPI(_ context: ProviderFetchContext) {
        self.apiRequests.append(Request(sourceMode: context.sourceMode, accountID: context.selectedTokenAccountID))
    }

    func recordWeb(_ context: ProviderFetchContext) {
        self.webRequests.append(Request(sourceMode: context.sourceMode, accountID: context.selectedTokenAccountID))
    }
}

private struct HuggingFaceAPIStubStrategy: ProviderFetchStrategy {
    let recorder: HuggingFaceAuthorityFetchRecorder

    let id = "huggingface-api-stub"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        await self.recorder.recordAPI(context)
        let cost = ProviderCostSnapshot(
            used: 12,
            limit: 0,
            currencyCode: "USD",
            period: "Current billing period",
            updatedAt: Date())
        let usage = UsageSnapshot(primary: nil, secondary: nil, providerCost: cost, updatedAt: Date(), identity: nil)
        return self.makeResult(usage: usage, sourceLabel: "api")
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private struct HuggingFaceWebStubStrategy: ProviderFetchStrategy {
    let recorder: HuggingFaceAuthorityFetchRecorder

    let id = "huggingface-web-stub"
    let kind: ProviderFetchKind = .web

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        await self.recorder.recordWeb(context)
        let cost = ProviderCostSnapshot(
            used: 0,
            limit: 0,
            currencyCode: "USD",
            period: "Prepaid credits",
            balance: 42,
            updatedAt: Date())
        let usage = UsageSnapshot(primary: nil, secondary: nil, providerCost: cost, updatedAt: Date(), identity: nil)
        return self.makeResult(usage: usage, sourceLabel: "web")
    }

    func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

@MainActor
@Suite(.serialized)
struct HuggingFaceWebAuthorityTokenAccountBoundaryTests {
    @Test
    func `selected token account stays Web scoped and is not relabeled or cached as that account`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-selected")
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        let accounts = settings.tokenAccounts(for: .huggingface)
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)

        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)

        let webRequests = await recorder.webRequests
        let apiRequests = await recorder.apiRequests
        #expect(webRequests.count == 1)
        #expect(webRequests.first?.accountID == accounts.first?.id)
        #expect(apiRequests.isEmpty)

        #expect(store.lastSourceLabels[.huggingface] == "web")
        let snapshot = try #require(store.snapshot(for: .huggingface))
        #expect(snapshot.providerCost?.balance == 42)
        // Not relabeled with the selected token account's label.
        #expect(snapshot.accountEmail(for: .huggingface) != "Personal")
        // Not cached as though it belonged to the selected token account.
        #expect(store.accountSnapshots[.huggingface] == nil)
    }

    @Test
    func `stacked accounts and Cookie source Refresh perform one Web validation and cache nothing`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-stacked-cookie-refresh")
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        settings.addTokenAccount(provider: .huggingface, label: "Work", token: "hf_work_token")
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)

        // Mirrors ProviderCookieRefreshAction.perform: an explicit user-initiated refresh that forces
        // the Web source even though Hugging Face token accounts are configured and stacked.
        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)

        let webRequests = await recorder.webRequests
        let apiRequests = await recorder.apiRequests
        #expect(webRequests.count == 1)
        #expect(apiRequests.isEmpty)
        #expect(store.lastSourceLabels[.huggingface] == "web")
        #expect(store.snapshot(for: .huggingface)?.providerCost?.balance == 42)
        // No per-token-account Web wallet snapshots were populated by the fan-out path.
        #expect(store.accountSnapshots[.huggingface] == nil)
    }

    @Test
    func `ordinary Auto refresh with stacked token accounts remains correctly token account scoped`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-ordinary-auto")
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        settings.addTokenAccount(provider: .huggingface, label: "Work", token: "hf_work_token")
        let accounts = settings.tokenAccounts(for: .huggingface)
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)

        await store.refreshProvider(.huggingface)

        let apiRequests = await recorder.apiRequests
        let webRequests = await recorder.webRequests
        #expect(webRequests.isEmpty)
        #expect(Set(apiRequests.map(\.accountID)) == Set(accounts.map { $0.id as UUID? }))
        #expect(apiRequests.count == 2)

        let snapshots = try #require(store.accountSnapshots[.huggingface])
        #expect(snapshots.map(\.account.id) == accounts.map(\.id))
        #expect(snapshots.map { $0.snapshot?.accountEmail(for: .huggingface) } == ["Personal", "Work"])
    }

    @Test
    func `Web wallet outranks populated stacked API caches without discarding them`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-web-projection")
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        settings.addTokenAccount(provider: .huggingface, label: "Work", token: "hf_work_token")
        let accounts = settings.tokenAccounts(for: .huggingface)
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)
        let fetcher = UsageFetcher(environment: [:])
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        await store.refreshProvider(.huggingface)

        let initialAPIRequests = await recorder.apiRequests
        let initialWebRequests = await recorder.webRequests
        #expect(initialAPIRequests.count == 2)
        #expect(initialWebRequests.isEmpty)
        let initialSnapshots = try #require(store.accountSnapshots[.huggingface])
        #expect(initialSnapshots.map(\.account.id) == accounts.map(\.id))
        #expect(initialSnapshots.allSatisfy { $0.sourceLabel == "api" })
        #expect(initialSnapshots.allSatisfy { $0.snapshot?.providerCost?.balance == nil })
        let initialDisplay = try #require(controller.tokenAccountMenuDisplay(for: .huggingface))
        #expect(initialDisplay.layout == .stacked)
        #expect(initialDisplay.snapshots.map(\.account.id) == accounts.map(\.id))
        let cachedAPIState = initialSnapshots.map(Self.cacheIdentity)

        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)

        let webPhaseAPIRequests = await recorder.apiRequests
        let webPhaseWebRequests = await recorder.webRequests
        #expect(webPhaseWebRequests.count == 1)
        #expect(webPhaseAPIRequests.count == initialAPIRequests.count)
        #expect(store.lastSourceLabels[.huggingface] == "web")
        #expect(store.snapshot(for: .huggingface)?.providerCost?.balance == 42)
        let webSnapshot = try #require(store.snapshot(for: .huggingface))
        #expect(webSnapshot.accountEmail(for: .huggingface) != "Personal")
        #expect(webSnapshot.accountEmail(for: .huggingface) != "Work")
        let preservedAPISnapshots = try #require(store.accountSnapshots[.huggingface])
        let preservedAPIState = preservedAPISnapshots.map(Self.cacheIdentity)
        #expect(preservedAPIState == cachedAPIState)
        #expect(controller.tokenAccountMenuDisplay(for: .huggingface) == nil)
        let webCard = try #require(controller.menuCardModel(for: .huggingface))
        #expect(webCard.provider == .huggingface)
        #expect(webCard.email != "Personal")
        #expect(webCard.email != "Work")
        #expect(webCard.providerCost?.spendLine.contains("42") == true)

        await store.refreshProvider(.huggingface)

        #expect(store.lastSourceLabels[.huggingface] == "api")
        let restoredDisplay = try #require(controller.tokenAccountMenuDisplay(for: .huggingface))
        #expect(restoredDisplay.layout == .stacked)
        #expect(restoredDisplay.snapshots.map(\.account.id) == accounts.map(\.id))
        #expect(store.accountSnapshots[.huggingface]?.map(Self.cacheIdentity) == cachedAPIState)
    }

    private static func makeSettings(suite: String) -> SettingsStore {
        testSettingsStore(
            suiteName: "\(suite)-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeStore(
        settings: SettingsStore,
        recorder: HuggingFaceAuthorityFetchRecorder) throws -> UsageStore
    {
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let baseSpec = try #require(store.providerSpecs[.huggingface])
        let baseDescriptor = baseSpec.descriptor
        let apiStub = HuggingFaceAPIStubStrategy(recorder: recorder)
        let webStub = HuggingFaceWebStubStrategy(recorder: recorder)
        store.providerSpecs[.huggingface] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: { true },
            descriptor: ProviderDescriptor(
                id: .huggingface,
                metadata: baseDescriptor.metadata,
                branding: baseDescriptor.branding,
                tokenCost: baseDescriptor.tokenCost,
                fetchPlan: ProviderFetchPlan(
                    sourceModes: [.auto, .api, .web],
                    pipeline: ProviderFetchPipeline { context in
                        switch context.sourceMode {
                        case .web:
                            [webStub]
                        default:
                            [apiStub]
                        }
                    }),
                cli: baseDescriptor.cli),
            makeFetchContext: baseSpec.makeFetchContext)
        return store
    }

    private struct CacheIdentity: Equatable {
        let accountID: UUID
        let cacheKey: String
        let sourceLabel: String?
        let used: Double?
        let balance: Double?
    }

    private static func cacheIdentity(_ snapshot: TokenAccountUsageSnapshot) -> CacheIdentity {
        CacheIdentity(
            accountID: snapshot.account.id,
            cacheKey: snapshot.cacheKey,
            sourceLabel: snapshot.sourceLabel,
            used: snapshot.snapshot?.providerCost?.used,
            balance: snapshot.snapshot?.providerCost?.balance)
    }
}
