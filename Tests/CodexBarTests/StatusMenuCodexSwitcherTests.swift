import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusMenuCodexSwitcherTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.menuRefreshEnabled = false
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuCodexSwitcherTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    private func makeController(
        settings: SettingsStore,
        store: UsageStore,
        fetcher: UsageFetcher) -> StatusItemController
    {
        StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
    }

    private func representedIDs(in menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func makeManagedAccountStoreURL(accounts: [ManagedCodexAccount]) throws -> URL {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts))
        return storeURL
    }

    private func actionLabels(in descriptor: MenuDescriptor) -> [String] {
        descriptor.sections.flatMap(\.entries).compactMap { entry in
            guard case let .action(label, _) = entry else { return nil }
            return label
        }
    }

    private func selectCodexVisibleAccountForStatusMenu(
        id: String,
        settings: SettingsStore,
        store: UsageStore) -> Task<Void, Never>?
    {
        guard settings.selectCodexVisibleAccount(id: id) else { return nil }
        _ = store.prepareCodexAccountScopedRefreshIfNeeded()
        return Task { @MainActor in
            await store.refreshCodexAccountScopedState(allowDisabled: true)
        }
    }

    private func installBlockingCodexProvider(on store: UsageStore, blocker: BlockingStatusMenuCodexFetchStrategy) {
        let baseSpec = store.providerSpecs[.codex]!
        store.providerSpecs[.codex] = Self.makeCodexProviderSpec(baseSpec: baseSpec) {
            try await blocker.awaitResult()
        }
    }

    private static func makeCodexProviderSpec(
        baseSpec: ProviderSpec,
        loader: @escaping @Sendable () async throws -> UsageSnapshot) -> ProviderSpec
    {
        let baseDescriptor = baseSpec.descriptor
        let strategy = StatusMenuTestCodexFetchStrategy(loader: loader)
        let descriptor = ProviderDescriptor(
            id: .codex,
            metadata: baseDescriptor.metadata,
            branding: baseDescriptor.branding,
            tokenCost: baseDescriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .oauth],
                pipeline: ProviderFetchPipeline { _ in [strategy] }),
            cli: baseDescriptor.cli)
        return ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: descriptor,
            makeFetchContext: baseSpec.makeFetchContext)
    }

    @Test
    func `codex menu shows account switcher and add account action for multiple visible accounts`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let projection = settings.codexVisibleAccountProjection
        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false)

        #expect(projection.visibleAccounts.map(\.email) == ["live@example.com", "managed@example.com"])
        #expect(projection.activeVisibleAccountID == "live@example.com")
        let actionLabels = self.actionLabels(in: descriptor)
        #expect(actionLabels.contains("Add Account..."))
        #expect(actionLabels.contains("Switch Account...") == false)
    }

    @Test
    func `codex menu hides account switcher when only one visible account exists`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "solo@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        defer { settings._test_liveSystemCodexAccount = nil }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let descriptor = MenuDescriptor.build(
            provider: .codex,
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updateReady: false)

        #expect(settings.codexVisibleAccountProjection.visibleAccounts.map(\.email) == ["solo@example.com"])
        #expect(self.actionLabels(in: descriptor).contains("Add Account..."))
    }

    @Test
    func `codex switcher compacts same email pills while preserving email and workspace`() {
        let accounts = [
            CodexVisibleAccount(
                id: "pl.fr@yandex.com\naccount:personal",
                email: "pl.fr@yandex.com",
                workspaceLabel: "Personal",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: true,
                isLive: true,
                canReauthenticate: true,
                canRemove: false),
            CodexVisibleAccount(
                id: "pl.fr@yandex.com\naccount:idconcepts",
                email: "pl.fr@yandex.com",
                workspaceLabel: "IDconcepts",
                storedAccountID: nil,
                selectionSource: .managedAccount(id: UUID()),
                isActive: false,
                isLive: false,
                canReauthenticate: true,
                canRemove: true),
        ]

        let view = CodexAccountSwitcherView(
            accounts: accounts,
            selectedAccountID: accounts.first?.id,
            width: 220,
            onSelect: { _ in })

        let titles = view._test_buttonTitles()
        let toolTips = view._test_buttonToolTips()

        #expect(titles.count == 2)
        #expect(titles[0] != titles[1])
        #expect(titles.allSatisfy { $0.contains("|") })
        #expect(titles.allSatisfy { $0.lowercased().contains("pl.") })
        #expect(titles[0].lowercased().contains("pers"))
        #expect(titles[1].lowercased().contains("id"))
        #expect(toolTips == accounts.map(\.displayName))
    }

    @Test
    func `codex all mode toggle renders all before single`() {
        let view = CodexMenuDisplayModeToggleView(selectedMode: .all, width: 220, onSelect: { _ in })

        #expect(view._test_buttonTitles() == ["All", "Single"])
    }

    @Test
    func `codex all mode display hides switcher while keeping sort available`() {
        let accounts = [
            CodexVisibleAccount(
                id: "live@example.com",
                email: "live@example.com",
                workspaceLabel: "Personal",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: true,
                isLive: true,
                canReauthenticate: true,
                canRemove: false),
            CodexVisibleAccount(
                id: "managed@example.com",
                email: "managed@example.com",
                workspaceLabel: "Team Alpha",
                storedAccountID: UUID(),
                selectionSource: .managedAccount(id: UUID()),
                isActive: false,
                isLive: false,
                canReauthenticate: true,
                canRemove: true),
        ]
        let display = CodexAccountMenuDisplay(
            accounts: accounts,
            cachedSnapshots: [:],
            activeVisibleAccountID: accounts.first?.id,
            displayMode: .all)

        #expect(display.showAll)
        #expect(display.showSwitcher == false)
        #expect(display.showSortControl)
    }

    @Test
    func `codex menu switcher selection activates the visible managed account`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        #expect(settings.selectCodexVisibleAccount(id: "managed@example.com"))

        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountID))
    }

    @Test
    func `codex menu switcher clears stale account state on the first click`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = false
        settings.codexCookieSource = .off
        self.enableOnlyCodex(settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "live@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")),
            provider: .codex)
        store.lastCodexAccountScopedRefreshGuard = store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)

        let blocker = BlockingStatusMenuCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        let refreshTask = try #require(
            self.selectCodexVisibleAccountForStatusMenu(
                id: "managed@example.com",
                settings: settings,
                store: store))

        await blocker.waitUntilStarted()
        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountID))
        #expect(store.snapshots[.codex] == nil)

        await blocker.resume(with: .success(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 9, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "managed@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro"))))
        for _ in 0..<10 where store.snapshots[.codex]?.accountEmail(for: .codex) != "managed@example.com" {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await refreshTask.value
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "managed@example.com")
    }

    @Test
    func `codex account state disables add account while managed authentication is in flight`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        defer { settings._test_liveSystemCodexAccount = nil }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = BlockingManagedCodexLoginRunnerForStatusMenuTests()
        let service = ManagedCodexAccountService(
            store: InMemoryManagedCodexAccountStoreForStatusMenuTests(),
            homeFactory: TestManagedCodexHomeFactoryForStatusMenuTests(root: root),
            loginRunner: runner,
            identityReader: StubManagedCodexIdentityReaderForStatusMenuTests(email: "managed@example.com"))
        let coordinator = ManagedCodexAccountCoordinator(service: service)
        let authTask = Task { try await coordinator.authenticateManagedAccount() }
        await runner.waitUntilStarted()

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let pane = ProvidersPane(
            settings: settings,
            store: store,
            managedCodexAccountCoordinator: coordinator)
        let state = try #require(pane._test_codexAccountsSectionState())

        #expect(state.canAddAccount == false)
        #expect(state.isAuthenticatingManagedAccount)
        #expect(state.addAccountTitle == "Adding Account…")

        await runner.resume()
        _ = try await authTask.value
    }

    @Test
    func `codex account state disables add account when managed store is unreadable`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings._test_unreadableManagedCodexAccountStore = true
        defer {
            settings._test_liveSystemCodexAccount = nil
            settings._test_unreadableManagedCodexAccountStore = false
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let pane = ProvidersPane(settings: settings, store: store)
        let state = try #require(pane._test_codexAccountsSectionState())

        #expect(state.hasUnreadableManagedAccountStore)
        #expect(state.canAddAccount == false)
    }

    @Test
    func `codex menu state helpers show grouped controls only for multi account all mode`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            workspaceLabel: "Team Alpha",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            workspaceLabel: "Personal",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())

        settings.codexMenuDisplayMode = .single
        #expect(settings.shouldShowCodexMenuDisplayModeToggle(for: .codex))
        #expect(settings.shouldShowCodexMenuSortControl(for: .codex) == false)

        settings.codexMenuDisplayMode = .all
        #expect(settings.shouldShowCodexMenuDisplayModeToggle(for: .codex))
        #expect(settings.shouldShowCodexMenuSortControl(for: .codex))
    }

    @Test
    func `codex menu state helpers hide grouped controls when only one visible account exists`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.codexMenuDisplayMode = .all
        self.enableOnlyCodex(settings)
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "solo@example.com",
            workspaceLabel: "Personal",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        defer { settings._test_liveSystemCodexAccount = nil }

        #expect(settings.shouldShowCodexMenuDisplayModeToggle(for: .codex) == false)
        #expect(settings.shouldShowCodexMenuSortControl(for: .codex) == false)
    }

    @Test
    func `codex all accounts sort orders cached cards by session remaining`() {
        self.disableMenuCardsForTesting()
        let accounts = [
            CodexVisibleAccount(
                id: "alpha@example.com\naccount:one",
                email: "alpha@example.com",
                workspaceLabel: "One",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: true,
                isLive: true,
                canReauthenticate: true,
                canRemove: false),
            CodexVisibleAccount(
                id: "beta@example.com\naccount:two",
                email: "beta@example.com",
                workspaceLabel: "Two",
                storedAccountID: nil,
                selectionSource: .managedAccount(id: UUID()),
                isActive: false,
                isLive: false,
                canReauthenticate: true,
                canRemove: true),
        ]
        let cached: [String: CodexVisibleAccountUsageSnapshot] = [
            accounts[0].id: CodexVisibleAccountUsageSnapshot(
                visibleAccountID: accounts[0].id,
                snapshot: UsageSnapshot(
                    primary: RateWindow(usedPercent: 60, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: accounts[0].email,
                        accountOrganization: accounts[0].workspaceLabel,
                        loginMethod: "Team")),
                error: nil,
                sourceLabel: nil),
            accounts[1].id: CodexVisibleAccountUsageSnapshot(
                visibleAccountID: accounts[1].id,
                snapshot: UsageSnapshot(
                    primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: accounts[1].email,
                        accountOrganization: accounts[1].workspaceLabel,
                        loginMethod: "Team")),
                error: nil,
                sourceLabel: nil),
        ]

        let sorted = StatusItemController.sortedCodexVisibleAccounts(
            accounts,
            cachedSnapshots: cached,
            mode: .sessionLeftHighToLow)

        #expect(sorted.map(\.id) == [accounts[1].id, accounts[0].id])
    }

    @Test
    func `codex switch applies cached visible-account snapshot immediately before refresh completes`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = false
        settings.codexCookieSource = .off
        self.enableOnlyCodex(settings)

        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-111111111111"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "managed@example.com",
            managedHomePath: "/tmp/managed-home",
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let cachedManagedSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 22, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: "managed@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
        store.codexAllAccountsSnapshotCache["managed@example.com"] = CodexVisibleAccountUsageSnapshot(
            visibleAccountID: "managed@example.com",
            snapshot: cachedManagedSnapshot,
            error: nil,
            sourceLabel: "cached")
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "live@example.com",
                    accountOrganization: nil,
                    loginMethod: "Pro")),
            provider: .codex)
        store.lastCodexAccountScopedRefreshGuard = store
            .currentCodexAccountScopedRefreshGuard(preferCurrentSnapshot: false)

        let blocker = BlockingStatusMenuCodexFetchStrategy()
        self.installBlockingCodexProvider(on: store, blocker: blocker)

        #expect(settings.selectCodexVisibleAccount(id: "managed@example.com"))
        _ = store.prepareCodexAccountScopedRefreshIfNeeded()
        #expect(store.applyCachedCodexVisibleAccountSnapshotIfAvailable(visibleAccountID: "managed@example.com"))
        let refreshTask = Task { @MainActor in
            await store.refreshCodexAccountScopedState(allowDisabled: true)
        }

        await blocker.waitUntilStarted()
        #expect(store.snapshots[.codex]?.accountEmail(for: .codex) == "managed@example.com")

        await blocker.resume(with: .success(cachedManagedSnapshot))
        await refreshTask.value
    }
}

private struct StatusMenuTestCodexFetchStrategy: ProviderFetchStrategy {
    let loader: @Sendable () async throws -> UsageSnapshot

    var id: String {
        "status-menu-test-codex"
    }

    var kind: ProviderFetchKind {
        .cli
    }

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try await self.loader()
        return self.makeResult(usage: snapshot, sourceLabel: "status-menu-test-codex")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private actor BlockingStatusMenuCodexFetchStrategy {
    private var waiters: [CheckedContinuation<Result<UsageSnapshot, Error>, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func awaitResult() async throws -> UsageSnapshot {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        let result = await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
        return try result.get()
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume(with result: Result<UsageSnapshot, Error>) {
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

private actor BlockingManagedCodexLoginRunnerForStatusMenuTests: ManagedCodexLoginRunning {
    private var waiters: [CheckedContinuation<CodexLoginRunner.Result, Never>] = []
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didStart = false

    func run(homePath _: String, timeout _: TimeInterval) async -> CodexLoginRunner.Result {
        self.didStart = true
        self.startedWaiters.forEach { $0.resume() }
        self.startedWaiters.removeAll()
        return await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        if self.didStart { return }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(continuation)
        }
    }

    func resume() {
        let result = CodexLoginRunner.Result(outcome: .success, output: "ok")
        self.waiters.forEach { $0.resume(returning: result) }
        self.waiters.removeAll()
    }
}

private final class InMemoryManagedCodexAccountStoreForStatusMenuTests: ManagedCodexAccountStoring,
@unchecked Sendable {
    private var snapshot = ManagedCodexAccountSet(version: 1, accounts: [])

    func loadAccounts() throws -> ManagedCodexAccountSet {
        self.snapshot
    }

    func storeAccounts(_ accounts: ManagedCodexAccountSet) throws {
        self.snapshot = accounts
    }

    func ensureFileExists() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private struct TestManagedCodexHomeFactoryForStatusMenuTests: ManagedCodexHomeProducing, Sendable {
    let root: URL

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct StubManagedCodexIdentityReaderForStatusMenuTests: ManagedCodexIdentityReading, Sendable {
    let email: String

    func loadAccountInfo(homePath _: String) throws -> AccountInfo {
        AccountInfo(email: self.email, plan: "Pro")
    }
}
