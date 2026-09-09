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
    var apiFailureMode = false
    var apiCancellationAccountIDs: Set<UUID> = []
    var webFailureMode = false
    var composedAccountID: UUID?

    func recordAPI(_ context: ProviderFetchContext) {
        self.apiRequests.append(Request(sourceMode: context.sourceMode, accountID: context.selectedTokenAccountID))
    }

    func recordWeb(_ context: ProviderFetchContext) {
        self.webRequests.append(Request(sourceMode: context.sourceMode, accountID: context.selectedTokenAccountID))
    }

    func setAPIFailureMode(_ enabled: Bool) {
        self.apiFailureMode = enabled
    }

    func setAPICancellationAccountIDs(_ ids: Set<UUID>) {
        self.apiCancellationAccountIDs = ids
    }

    func shouldCancelAPI(for accountID: UUID?) -> Bool {
        guard let accountID else { return false }
        return self.apiCancellationAccountIDs.contains(accountID)
    }

    func setWebFailureMode(_ enabled: Bool) {
        self.webFailureMode = enabled
    }

    func setComposedAccountID(_ id: UUID?) {
        self.composedAccountID = id
    }
}

private struct HuggingFaceAPIStubStrategy: ProviderFetchStrategy {
    let recorder: HuggingFaceAuthorityFetchRecorder
    let composedBalanceUSD: Double = 42

    let id = "huggingface-api-stub"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        await self.recorder.recordAPI(context)
        if await self.recorder.shouldCancelAPI(for: context.selectedTokenAccountID) {
            throw CancellationError()
        }
        guard await !self.recorder.apiFailureMode else {
            throw ProviderPluginError.script("fixture API outage")
        }
        let isComposedMatch = await self.recorder.composedAccountID == context.selectedTokenAccountID
        if isComposedMatch {
            let observedAt = Date()
            let cost = ProviderCostSnapshot(
                used: 12,
                limit: 0,
                currencyCode: "USD",
                period: "Current billing period",
                balance: self.composedBalanceUSD,
                balanceUpdatedAt: observedAt,
                updatedAt: observedAt)
            let usage = UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: cost,
                updatedAt: observedAt,
                identity: nil)
            return self.makeResult(usage: usage, sourceLabel: "api+web")
                .replacingWalletOutcome(.localMatchComposed(
                    balanceUSD: self.composedBalanceUSD,
                    observedAt: observedAt))
        }
        let cost = ProviderCostSnapshot(
            used: 12,
            limit: 0,
            currencyCode: "USD",
            period: "Current billing period",
            updatedAt: Date())
        let usage = UsageSnapshot(primary: nil, secondary: nil, providerCost: cost, updatedAt: Date(), identity: nil)
        let unverified = await self.recorder.composedAccountID != nil
        return self.makeResult(usage: usage, sourceLabel: "api")
            .replacingWalletOutcome(unverified
                ? .providerLevel(HuggingFaceBrowserWalletPublication(
                    balanceUSD: self.composedBalanceUSD,
                    observedAt: Date(),
                    attribution: .unverified))
                : nil)
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
        guard await !self.recorder.webFailureMode else {
            throw ProviderPluginError.script("fixture Web outage")
        }
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
    func `partial stacked refresh reconciles retained wallet before publishing account snapshots`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-partial-refresh")
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        settings.addTokenAccount(provider: .huggingface, label: "Work", token: "hf_work_token")
        settings.setActiveTokenAccountIndex(0, for: .huggingface)
        let accounts = settings.tokenAccounts(for: .huggingface)
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)

        // First refresh: only Personal receives the locally matched composition.
        await recorder.setComposedAccountID(accounts[0].id)
        await store.refreshProvider(.huggingface)
        let initial = try #require(store.accountSnapshots[.huggingface])
        #expect(initial[0].snapshot?.providerCost?.balance == 42)
        #expect(initial[0].sourceLabel == "api+web")
        #expect(initial[1].snapshot?.providerCost?.balance == nil)
        #expect(initial[1].sourceLabel == "api")

        // Second refresh: Personal is cancelled while Work receives the fresh unique composition.
        await recorder.setComposedAccountID(accounts[1].id)
        await recorder.setAPICancellationAccountIDs([accounts[0].id])
        await store.refreshProvider(.huggingface)

        let refreshed = try #require(store.accountSnapshots[.huggingface])
        let personal = try #require(refreshed.first { $0.account.id == accounts[0].id })
        let work = try #require(refreshed.first { $0.account.id == accounts[1].id })
        // Cached API spend survives cancellation, but the old browser wallet attribution does not.
        #expect(personal.snapshot?.providerCost?.used == 12)
        #expect(personal.snapshot?.providerCost?.balance == nil)
        #expect(personal.sourceLabel == "api")
        #expect(work.snapshot?.providerCost?.balance == 42)
        #expect(work.sourceLabel == "api+web")
        #expect(refreshed.count(where: { $0.snapshot?.providerCost?.balance != nil }) == 1)
        let live = try #require(store.snapshot(for: .huggingface))
        #expect(live.accountEmail(for: .huggingface) == "Personal")
        #expect(live.providerCost?.used == 12)
        #expect(live.providerCost?.balance == nil)
        #expect(store.lastSourceLabels[.huggingface] == "api")
        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
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

    @Test
    func `successful web publication clears a prior auxiliary wallet and records the browser value`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-clears-auxiliary")
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)
        // A stale Auto provider-level auxiliary publication from a previous refresh.
        store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 7,
            observedAt: Date(),
            attribution: .unverified)

        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)

        // The fresh Web snapshot owns the visible wallet; the old auxiliary publication is gone
        // and the browser value is recorded for failure-time recovery.
        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
        let recorded = try #require(store.huggingFaceWebOwnedWallets[.huggingface])
        #expect(recorded.balanceUSD == 42)
        #expect(store.snapshot(for: .huggingface)?.providerCost?.balance == 42)
        #expect(store.lastSourceLabels[.huggingface] == "web")
    }

    @Test
    func `failed auto follow-up after web validation keeps the validated wallet visible`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-failed-follow-up")
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        settings.addTokenAccount(provider: .huggingface, label: "Work", token: "hf_work_token")
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)

        // Phase 1: an ordinary Auto refresh populates the stacked API account caches.
        await store.refreshProvider(.huggingface)
        let cachedSnapshots = try #require(store.accountSnapshots[.huggingface])
        #expect(cachedSnapshots.count == 2)

        // Phase 2: Cookie source Refresh validates the Web wallet in isolation.
        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        #expect(store.snapshot(for: .huggingface)?.providerCost?.balance == 42)
        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)

        // Phase 3: the best-effort ordinary Auto follow-up fails before wallet work while the
        // cached account snapshots are retained.
        await recorder.setAPIFailureMode(true)
        await store.refreshProvider(.huggingface)

        // The activated cached API snapshot has no wallet, so the validated Credits must stay
        // visible once at provider level with browser-session attribution.
        let snapshot = try #require(store.snapshot(for: .huggingface))
        #expect(snapshot.providerCost?.balance == nil)
        let publication = try #require(store.huggingFaceBrowserWallets[.huggingface])
        #expect(publication.balanceUSD == 42)
        #expect(publication.attribution == .webSession)
        #expect(store.accountSnapshots[.huggingface]?.count == 2)
    }

    @Test
    func `explicit web failure preserves Web snapshot over a populated selected API cache`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-explicit-web-failure")
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)

        // Populate the selected API-account cache through the production Auto route.
        await store.refreshProvider(.huggingface)
        let cached = try #require(store.accountSnapshots[.huggingface]?.first)
        #expect(cached.sourceLabel == "api")
        #expect(cached.snapshot?.accountEmail(for: .huggingface) == "Personal")

        // A successful explicit Web refresh becomes the provider-owned live authority.
        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        let priorWeb = try #require(store.snapshot(for: .huggingface))
        let priorWallet = try #require(store.huggingFaceWebOwnedWallets[.huggingface])
        #expect(priorWeb.providerCost?.balance == 42)
        #expect(store.lastSourceLabels[.huggingface] == "web")

        // A second explicit Web failure must not activate the selected API cache first.
        await recorder.setWebFailureMode(true)
        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)

        let retained = try #require(store.snapshot(for: .huggingface))
        #expect(retained.providerCost?.balance == priorWeb.providerCost?.balance)
        #expect(retained.updatedAt == priorWeb.updatedAt)
        #expect(retained.accountEmail(for: .huggingface) != "Personal")
        #expect(store.lastSourceLabels[.huggingface] == "web")
        #expect(store.accountSnapshots[.huggingface]?.first?.snapshot?.accountEmail(for: .huggingface) == "Personal")
        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
        #expect(store.huggingFaceWebOwnedWallets[.huggingface] == priorWallet)
        #expect(store.huggingFaceLiveWebSnapshotOwners == [.huggingface])
        #expect(store.huggingFacePendingWebSnapshotDisplacement.isEmpty)
    }

    @Test
    func `persisted web failure preserves Web snapshot over a populated selected API cache`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-persisted-web-failure")
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)

        // First populate the selected API-account cache while the persisted source is Auto.
        await store.refreshProvider(.huggingface)
        let cached = try #require(store.accountSnapshots[.huggingface]?.first)
        #expect(cached.sourceLabel == "api")
        #expect(cached.snapshot?.accountEmail(for: .huggingface) == "Personal")

        // Select Web through persisted provider configuration, then publish its live snapshot.
        settings.huggingFaceUsageDataSource = .web
        await store.refreshProvider(.huggingface, allowDisabled: true)
        let priorWeb = try #require(store.snapshot(for: .huggingface))
        let priorWallet = try #require(store.huggingFaceWebOwnedWallets[.huggingface])
        #expect(priorWeb.providerCost?.balance == 42)
        #expect(store.lastSourceLabels[.huggingface] == "web")

        // A later persisted-Web failure must retain Web authority and never reveal the API cache.
        await recorder.setWebFailureMode(true)
        await store.refreshProvider(.huggingface, allowDisabled: true)

        let retained = try #require(store.snapshot(for: .huggingface))
        #expect(retained.providerCost?.balance == priorWeb.providerCost?.balance)
        #expect(retained.updatedAt == priorWeb.updatedAt)
        #expect(retained.accountEmail(for: .huggingface) != "Personal")
        #expect(store.lastSourceLabels[.huggingface] == "web")
        #expect(store.accountSnapshots[.huggingface]?.first?.snapshot?.accountEmail(for: .huggingface) == "Personal")
        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
        #expect(store.huggingFaceWebOwnedWallets[.huggingface] == priorWallet)
        #expect(store.huggingFaceLiveWebSnapshotOwners == [.huggingface])
        #expect(store.huggingFacePendingWebSnapshotDisplacement.isEmpty)
    }

    @Test
    func `successful auto follow-up after web validation transitions to the composed state`() async throws {
        let settings = Self.makeSettings(suite: "hf-web-authority-successful-follow-up")
        settings.multiAccountMenuLayout = .stacked
        let recorder = HuggingFaceAuthorityFetchRecorder()
        let store = try Self.makeStore(settings: settings, recorder: recorder)
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        settings.addTokenAccount(provider: .huggingface, label: "Work", token: "hf_work_token")
        let accounts = settings.tokenAccounts(for: .huggingface)
        await recorder.setComposedAccountID(accounts[0].id)

        // Cookie source Refresh validates the Web wallet first.
        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        #expect(store.snapshot(for: .huggingface)?.providerCost?.balance == 42)

        // The ordinary Auto follow-up succeeds: the uniquely matching account composes the wallet
        // and both the provider-level wallet and the recorded Web value are superseded.
        await store.refreshProvider(.huggingface)

        let snapshots = try #require(store.accountSnapshots[.huggingface])
        #expect(snapshots[0].snapshot?.providerCost?.balance == 42)
        #expect(snapshots[0].sourceLabel == "api+web")
        #expect(snapshots[1].snapshot?.providerCost?.balance == nil)
        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
        #expect(store.huggingFaceWebOwnedWallets[.huggingface] == nil)
    }

    @Test
    func `web session recovery renders browser session attribution wording`() throws {
        let publication = HuggingFaceBrowserWalletPublication(
            balanceUSD: 42,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .webSession)
        let section = try #require(HuggingFaceWalletPresentation.detailSection(publication))
        #expect(section.rows.map(\.value) == ["$42.00", "From browser session · API account not verified"])

        // Token-relative wording is reserved for completed comparisons that failed to verify.
        let unverified = HuggingFaceBrowserWalletPublication(
            balanceUSD: 42,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .unverified)
        let unverifiedSection = try #require(HuggingFaceWalletPresentation.detailSection(unverified))
        #expect(unverifiedSection.rows.map(\.value) == ["$42.00", "Unverified against this API token"])
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
