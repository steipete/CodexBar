import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// FP-194 remediation: the provider-level Hugging Face browser wallet must render exactly once in
/// compact multi-account menus, stacked menus, and the live-card surface — including when no API
/// base snapshot exists. All fixtures are synthetic; nothing here touches the browser, Keychain,
/// or network.
@MainActor
@Suite(.serialized)
struct HuggingFaceMenuWalletPresentationTests {
    // MARK: Compact vs stacked live menus

    @Test
    func `compact layout renders one unverified provider wallet section`() throws {
        let fixture = try Self.makeFixture(suite: "hf-menu-compact-unverified", accountCount: 5)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 9.25,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .unverified)

        let menu = try Self.makeMenu(fixture: fixture)
        let ids = Self.menuCardItemIDs(menu)

        // Compact layout shows the folded account rows plus exactly one provider wallet card.
        #expect(ids.contains("huggingFaceBrowserWallet"))
        #expect(ids.count(where: { $0 == "huggingFaceBrowserWallet" }) == 1)
        #expect(!ids.contains(where: { $0.hasPrefix("menuCard-") }))
        #expect(ids.contains(where: { $0.hasPrefix("tokenAccountCompact-") }))
    }

    @Test
    func `compact layout renders one multi match provider wallet section`() throws {
        let fixture = try Self.makeFixture(suite: "hf-menu-compact-multi-match", accountCount: 5)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 9.25,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .multipleMatchingAccounts)

        let menu = try Self.makeMenu(fixture: fixture)
        let ids = Self.menuCardItemIDs(menu)

        #expect(ids.count(where: { $0 == "huggingFaceBrowserWallet" }) == 1)
    }

    @Test
    func `compact layout renders no provider wallet for a unique composition`() throws {
        let fixture = try Self.makeFixture(
            suite: "hf-menu-compact-composed",
            accountCount: 5,
            composedAccountIndex: 0)
        #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == nil)

        let menu = try Self.makeMenu(fixture: fixture)
        let ids = Self.menuCardItemIDs(menu)

        // The wallet lives on the matching account card; no provider-level duplicate may appear.
        #expect(!ids.contains("huggingFaceBrowserWallet"))
    }

    @Test
    func `stacked layout keeps rendering one provider wallet section`() throws {
        let fixture = try Self.makeFixture(suite: "hf-menu-stacked-unverified", accountCount: 2)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 9.25,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .unverified)

        let menu = try Self.makeMenu(fixture: fixture)
        let ids = Self.menuCardItemIDs(menu)

        #expect(ids.count(where: { $0 == "huggingFaceBrowserWallet" }) == 1)
        #expect(ids.count(where: { $0.hasPrefix("menuCard-") }) == 2)
    }

    @Test
    func `detached compact construction puts wallet only in scratch menu`() throws {
        let fixture = try Self.makeFixture(suite: "hf-menu-detached-compact", accountCount: 5)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 9.25,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .unverified)
        let liveMenu = NSMenu()
        let scratch = NSMenu()

        try fixture.controller.addSwitcherScopedMenuContent(
            into: scratch,
            captureMenu: liveMenu,
            context: Self.makeMenuUpdateContext(fixture: fixture))

        #expect(Self.menuCardItemIDs(scratch).count(where: { $0 == "huggingFaceBrowserWallet" }) == 1)
        #expect(!Self.menuCardItemIDs(liveMenu).contains("huggingFaceBrowserWallet"))
    }

    @Test
    func `compact smart reconciliation adds retains and removes wallet exactly once`() throws {
        let fixture = try Self.makeFixture(suite: "hf-menu-smart-compact", accountCount: 5)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 9.25,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .unverified)
        let menu = NSMenu()
        let context = try Self.makeMenuUpdateContext(fixture: fixture)

        fixture.controller.updateMenuContentPreservingSwitcher(menu, context: context)
        #expect(Self.menuCardItemIDs(menu).count(where: { $0 == "huggingFaceBrowserWallet" }) == 1)

        fixture.controller.updateMenuContentPreservingSwitcher(menu, context: context)
        #expect(Self.menuCardItemIDs(menu).count(where: { $0 == "huggingFaceBrowserWallet" }) == 1)

        fixture.store.huggingFaceBrowserWallets[.huggingface] = nil
        fixture.controller.updateMenuContentPreservingSwitcher(menu, context: context)
        #expect(!Self.menuCardItemIDs(menu).contains("huggingFaceBrowserWallet"))
    }

    // MARK: Live-card surface with a nil base snapshot

    @Test
    func `live card renders the recovery wallet on a carrier snapshot without an api snapshot`() throws {
        let fixture = try Self.makeFixture(suite: "hf-menu-carrier", accountCount: 1, cachedSnapshot: false)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 42,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .webSession)

        let model = try #require(HuggingFaceMenuWalletPresentationTests.liveMenuModelFixture(
            controller: fixture.controller))

        // Exactly one browser-session wallet, carried by a snapshot that manufactures no API spend
        // and no account identity.
        let sections = model.providerDetails.filter { $0.title == "Browser session wallet" }
        #expect(sections.count == 1)
        #expect(sections[0].rows.map(\.label) == ["Prepaid credits", "Account"])
        #expect(sections[0].rows.map(\.value) == ["$42.00", "From browser session · API account not verified"])
        #expect(model.providerCost?.spendLine == nil || !model.providerCost!.spendLine.contains("$"))
    }

    @Test
    func `live card appends the wallet to an existing api snapshot`() throws {
        let fixture = try Self.makeFixture(suite: "hf-menu-append", accountCount: 1)
        fixture.store.huggingFaceBrowserWallets[.huggingface] = HuggingFaceBrowserWalletPublication(
            balanceUSD: 42,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000),
            attribution: .webSession)

        let model = try #require(HuggingFaceMenuWalletPresentationTests.liveMenuModelFixture(
            controller: fixture.controller))

        let sections = model.providerDetails.filter { $0.title == "Browser session wallet" }
        #expect(sections.count == 1)
        #expect(sections[0].rows.map(\.label) == ["Prepaid credits", "Account"])
        #expect(sections[0].rows.map(\.value) == ["$42.00", "From browser session · API account not verified"])
        #expect(model.providerCost?.title == "API spend")
        #expect(model.providerCost?.spendLine == "Reported billing period: $12.00")
    }

    @Test
    func `live card without a wallet publication renders no browser wallet section`() throws {
        let fixture = try Self.makeFixture(suite: "hf-menu-no-wallet", accountCount: 1)
        #expect(fixture.store.huggingFaceBrowserWallets[.huggingface] == nil)

        let model = try #require(HuggingFaceMenuWalletPresentationTests.liveMenuModelFixture(
            controller: fixture.controller))
        #expect(!model.providerDetails.contains { $0.title == "Browser session wallet" })
    }

    // MARK: Displacement-provenance recovery matrix

    @Test
    func `explicit web failure never arms or recovers an auxiliary wallet`() async throws {
        let settings = Self.makeSettings(suite: "hf-menu-web-failure")
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        let webFailure = Self.failingAPIFlag()
        let store = try Self.makeStore(settings: settings, failingAPI: false, webFailureFlag: webFailure)

        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        #expect(store.snapshot(for: .huggingface)?.providerCost?.balance == 42)

        // A later explicit-Web failure must not duplicate the recorded wallet into auxiliary state.
        webFailure.setFailing(true)
        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
        #expect(store.huggingFaceWebOwnedWallets[.huggingface]?.balanceUSD == 42)
        #expect(store.huggingFaceLiveWebSnapshotOwners == [.huggingface])
        #expect(store.huggingFacePendingWebSnapshotDisplacement.isEmpty)
    }

    @Test
    func `web success then auto failure with cached snapshot publishes one web session wallet`() async throws {
        let settings = Self.makeSettings(suite: "hf-menu-auto-failure-cached")
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        settings.addTokenAccount(provider: .huggingface, label: "Work", token: "hf_work_token")
        let failure = Self.failingAPIFlag()
        let store = try Self.makeStore(settings: settings, failingAPI: false, apiFailureFlag: failure)

        await store.refreshProvider(.huggingface)
        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        failure.setFailing(true)
        await store.refreshProvider(.huggingface)

        let publication = try #require(store.huggingFaceBrowserWallets[.huggingface])
        #expect(publication.balanceUSD == 42)
        #expect(publication.attribution == .webSession)
    }

    @Test
    func `selected account web success then auto failure without cache recovers one wallet`() async throws {
        let settings = Self.makeSettings(suite: "hf-menu-auto-failure-uncached")
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        let failure = Self.failingAPIFlag()
        let store = try Self.makeStore(settings: settings, failingAPI: false, apiFailureFlag: failure)

        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        #expect(store.huggingFaceLiveWebSnapshotOwners == [.huggingface])
        failure.setFailing(true)
        await store.refreshProvider(.huggingface)

        let publication = try #require(store.huggingFaceBrowserWallets[.huggingface])
        #expect(publication.balanceUSD == 42)
        #expect(publication.attribution == .webSession)

        let controller = Self.makeController(store: store, settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let model = try #require(Self.liveMenuModelFixture(controller: controller))
        let sections = model.providerDetails.filter { $0.title == "Browser session wallet" }
        #expect(sections.count == 1)
        #expect(sections[0].rows.map(\.value) == [
            "$42.00",
            "From browser session · API account not verified",
        ])
        // The carrier manufactures no spend of its own.
        #expect(model.providerCost == nil)
    }

    @Test
    func `segmented uncached selection recovers one wallet after auto failure`() async throws {
        let settings = Self.makeSettings(suite: "hf-menu-auto-failure-segmented")
        settings.multiAccountMenuLayout = .segmented
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        settings.addTokenAccount(provider: .huggingface, label: "Work", token: "hf_work_token")
        let failure = Self.failingAPIFlag()
        let store = try Self.makeStore(settings: settings, failingAPI: false, apiFailureFlag: failure)

        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        failure.setFailing(true)
        await store.refreshProvider(.huggingface)

        let publication = try #require(store.huggingFaceBrowserWallets[.huggingface])
        #expect(publication.balanceUSD == 42)
        #expect(publication.attribution == .webSession)
        #expect(store.huggingFacePendingWebSnapshotDisplacement.isEmpty)
    }

    @Test
    func `web success then auto success clears the recovery state`() async throws {
        let settings = Self.makeSettings(suite: "hf-menu-auto-success")
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        let store = try Self.makeStore(settings: settings, failingAPI: false)

        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        await store.refreshProvider(.huggingface)

        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
        #expect(store.huggingFaceWebOwnedWallets[.huggingface] == nil)
        #expect(store.huggingFaceLiveWebSnapshotOwners.isEmpty)
        #expect(store.huggingFacePendingWebSnapshotDisplacement.isEmpty)
    }

    @Test
    func `auto without selected token never displaces a failing web refresh`() async throws {
        let settings = Self.makeSettings(suite: "hf-menu-auto-no-token")
        let webFailure = Self.failingAPIFlag()
        let store = try Self.makeStore(settings: settings, failingAPI: false, webFailureFlag: webFailure)

        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        #expect(store.snapshot(for: .huggingface)?.providerCost?.balance == 42)
        webFailure.setFailing(true)
        await store.refreshProvider(.huggingface)

        #expect(store.snapshot(for: .huggingface)?.providerCost?.balance == 42)
        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
        #expect(store.huggingFaceLiveWebSnapshotOwners == [.huggingface])
        #expect(store.huggingFacePendingWebSnapshotDisplacement.isEmpty)
        #expect(store.huggingFaceWebOwnedWallets[.huggingface]?.balanceUSD == 42)
    }

    @Test
    func `web success then explicit api refresh never resurrects a web wallet`() async throws {
        let settings = Self.makeSettings(suite: "hf-menu-api-clear")
        settings.multiAccountMenuLayout = .stacked
        settings.addTokenAccount(provider: .huggingface, label: "Personal", token: "hf_personal_token")
        let failure = Self.failingAPIFlag()
        let store = try Self.makeStore(settings: settings, failingAPI: false, apiFailureFlag: failure)

        await store.refreshProvider(.huggingface, allowDisabled: true, sourceModeOverride: .web)
        #expect(store.snapshot(for: .huggingface)?.providerCost?.balance == 42)

        // Explicit API configuration replaces the browser snapshot with the API authority.
        settings.huggingFaceUsageDataSource = .api
        failure.setFailing(true)
        await store.refreshProvider(.huggingface)

        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
        #expect(store.huggingFaceWebOwnedWallets[.huggingface] == nil)
        #expect(store.huggingFaceLiveWebSnapshotOwners.isEmpty)
        #expect(store.huggingFacePendingWebSnapshotDisplacement.isEmpty)
    }

    @Test
    func `cancellation after displacement manufactures no recovery transition`() {
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: Self.makeSettings(suite: "hf-menu-cancellation"),
            startupBehavior: .testing,
            environmentBase: [:])
        // Simulate a provisionally displaced Web-owned snapshot reached by cancellation.
        store.huggingFaceWebOwnedWallets[.huggingface] = HuggingFaceWalletSnapshot(
            balanceUSD: 42,
            observedAt: Date(timeIntervalSince1970: 1_777_000_000))
        store.huggingFacePendingWebSnapshotDisplacement = [.huggingface]

        store.reconcileHuggingFaceWalletAfterFetchFailure(provider: .huggingface, error: CancellationError())

        #expect(store.huggingFaceBrowserWallets[.huggingface] == nil)
    }

    // MARK: Fixtures

    private struct Fixture {
        let store: UsageStore
        let controller: StatusItemController
        let accounts: [ProviderTokenAccount]
    }

    private static func makeSettings(suite: String) -> SettingsStore {
        testSettingsStore(
            suiteName: "\(suite)-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
    }

    private static func makeController(store: UsageStore, settings: SettingsStore) -> StatusItemController {
        let fetcher = UsageFetcher(environment: [:])
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
    }

    private static func makeFixture(
        suite: String,
        accountCount: Int,
        composedAccountIndex: Int? = nil,
        cachedSnapshot: Bool = true) throws -> Fixture
    {
        let settings = Self.makeSettings(suite: suite)
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.multiAccountMenuLayout = .stacked
        for index in 0..<accountCount {
            settings.addTokenAccount(
                provider: .huggingface,
                label: "Account \(index)",
                token: "hf_menu_token_\(index)")
        }
        settings.setActiveTokenAccountIndex(0, for: .huggingface)
        let accounts = settings.tokenAccounts(for: .huggingface)
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        for (index, account) in accounts.enumerated() {
            let composed = composedAccountIndex == index
            let cost = ProviderCostSnapshot(
                used: 12,
                limit: 0,
                currencyCode: "USD",
                period: "Reported billing period",
                balance: composed ? 9.25 : nil,
                updatedAt: Date())
            let snapshot = UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: cost,
                updatedAt: Date(),
                identity: nil)
            let entry = TokenAccountUsageSnapshot(
                account: account,
                snapshot: cachedSnapshot ? snapshot : nil,
                error: nil,
                sourceLabel: composed ? "api+web" : "api",
                cacheKey: store.tokenAccountSnapshotCacheKey(provider: .huggingface, account: account))
            var snapshots = store.accountSnapshots[.huggingface] ?? []
            snapshots.append(entry)
            store.accountSnapshots[.huggingface] = snapshots
        }
        if accountCount == 1, cachedSnapshot, let liveSnapshot = store.accountSnapshots[.huggingface]?[0].snapshot {
            store._setSnapshotForTesting(liveSnapshot, provider: .huggingface)
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }
        return Fixture(store: store, controller: controller, accounts: accounts)
    }

    private static func makeMenu(fixture: Fixture) throws -> NSMenu {
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = false
            StatusItemController.setMenuRefreshEnabledForTesting(true)
        }
        let menu = fixture.controller.makeMenu(for: .huggingface)
        fixture.controller.menuWillOpen(menu)
        return menu
    }

    private static func makeMenuUpdateContext(fixture: Fixture) throws -> StatusItemController.MenuUpdateContext {
        let display = try #require(fixture.controller.tokenAccountMenuDisplay(for: .huggingface))
        return StatusItemController.MenuUpdateContext(
            provider: .huggingface,
            currentProvider: .huggingface,
            switcherSelection: .provider(.huggingface),
            menuWidth: StatusItemController.menuCardBaseWidth,
            codexAccountDisplay: nil,
            tokenAccountDisplay: display,
            openAIContext: fixture.controller.openAIWebContext(
                currentProvider: .huggingface,
                showAllAccounts: true),
            descriptor: fixture.controller.makeMenuDescriptor(
                provider: .huggingface,
                includeContextualActions: true))
    }

    private static func menuCardItemIDs(_ menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }
            .filter { $0.hasPrefix("tokenAccount") || $0.hasPrefix("menuCard") || $0 == "huggingFaceBrowserWallet" }
    }

    // MARK: Recovery-matrix fixtures

    /// Projects the live-card wallet surface for Hugging Face through the same seams as the real
    /// menu, using the full `menuCardModel(for:)` assembly so render-relevant fields such as the
    /// cost row and provider details are exercised end to end.
    private static func liveMenuModelFixture(
        controller: StatusItemController) -> UsageMenuCardView.Model?
    {
        controller.menuCardModel(for: .huggingface)
    }

    private final class APIFailureFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var failing = false

        func setFailing(_ value: Bool) {
            self.lock.withLock { self.failing = value }
        }

        var isFailing: Bool {
            self.lock.withLock { self.failing }
        }
    }

    private static func failingAPIFlag() -> APIFailureFlag {
        APIFailureFlag()
    }

    private struct WebStubStrategy: ProviderFetchStrategy {
        let failureFlag: APIFailureFlag
        let id = "huggingface-web-stub"
        let kind: ProviderFetchKind = .web

        func isAvailable(_: ProviderFetchContext) async -> Bool {
            true
        }

        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            guard !self.failureFlag.isFailing else {
                throw ProviderPluginError.script("fixture Web outage")
            }
            let observedAt = Date(timeIntervalSince1970: 1_777_000_000)
            let cost = ProviderCostSnapshot(
                used: 0,
                limit: 0,
                currencyCode: "USD",
                period: "Prepaid credits",
                balance: 42,
                updatedAt: observedAt)
            let usage = UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: cost,
                updatedAt: observedAt,
                identity: nil)
            return self.makeResult(usage: usage, sourceLabel: "web")
        }

        func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
            false
        }
    }

    private struct APIStubStrategy: ProviderFetchStrategy {
        let failureFlag: APIFailureFlag
        let id = "huggingface-api-stub"
        let kind: ProviderFetchKind = .apiToken

        func isAvailable(_: ProviderFetchContext) async -> Bool {
            true
        }

        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            guard !self.failureFlag.isFailing else {
                throw ProviderPluginError.script("fixture API outage")
            }
            let cost = ProviderCostSnapshot(
                used: 12,
                limit: 0,
                currencyCode: "USD",
                period: "Current billing period",
                updatedAt: Date())
            let usage = UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: cost,
                updatedAt: Date(),
                identity: nil)
            // API-kind successes carry an outcome payload in production (the Auto strategy always
            // tags successes, including plain API data). The stub matches that contract here so the
            // successful follow-up supersedes the recorded Web-owned wallet like a real strategy.
            return self.makeResult(usage: usage, sourceLabel: "api")
                .replacingWalletOutcome(.notAttempted)
        }

        func shouldFallback(on _: any Error, context _: ProviderFetchContext) -> Bool {
            false
        }
    }

    private static func makeStore(
        settings: SettingsStore,
        failingAPI: Bool,
        apiFailureFlag: APIFailureFlag? = nil,
        webFailureFlag: APIFailureFlag? = nil) throws -> UsageStore
    {
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let baseSpec = try #require(store.providerSpecs[.huggingface])
        let baseDescriptor = baseSpec.descriptor
        let flag = apiFailureFlag ?? APIFailureFlag()
        flag.setFailing(failingAPI)
        let apiStub = APIStubStrategy(failureFlag: flag)
        let webFlag = webFailureFlag ?? APIFailureFlag()
        let webStub = WebStubStrategy(failureFlag: webFlag)
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
                        case .auto where context.selectedTokenAccountID == nil:
                            [webStub]
                        default:
                            [apiStub]
                        }
                    }),
                cli: baseDescriptor.cli),
            makeFetchContext: baseSpec.makeFetchContext)
        return store
    }
}
