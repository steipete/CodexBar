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
        StatusItemController.setMenuRefreshEnabledForTesting(false)
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
        .system
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

    private func representedIDs(in menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }
    }

    private func snapshot(email: String, percent: Double = 12) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: percent,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(300),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "Plus"))
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
    func `codex segmented multi account layout shows account switcher`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .segmented
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
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        #expect(menu.items.compactMap { $0.view as? CodexAccountSwitcherView }.first != nil)
        #expect(self.representedIDs(in: menu).filter { $0.hasPrefix("menuCard") } == ["menuCard"])
    }

    @Test
    func `codex stacked multi account layout shows account cards`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .stacked
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
        store.codexAccountSnapshots = projection.visibleAccounts.enumerated().map { index, account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(email: account.email, percent: Double(10 + index)),
                error: nil,
                sourceLabel: "test")
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        #expect(menu.items.compactMap { $0.view as? CodexAccountSwitcherView }.first == nil)
        #expect(self.representedIDs(in: menu).filter { $0.hasPrefix("menuCard") } == ["menuCard-0", "menuCard-1"])
    }

    @Test
    func `codex stacked multi account layout shows account cards before per account snapshots load`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .stacked
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
        store._setSnapshotForTesting(self.snapshot(email: "live@example.com"), provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        #expect(menu.items.compactMap { $0.view as? CodexAccountSwitcherView }.first == nil)
        #expect(self.representedIDs(in: menu).filter { $0.hasPrefix("menuCard") } == ["menuCard-0", "menuCard-1"])
    }

    @Test
    func `codex switcher suppresses personal labels while preserving team workspace tooltips`() {
        let accounts = [
            CodexVisibleAccount(
                id: "live:provider:account-personal",
                email: "pl.fr@yandex.com",
                workspaceLabel: "Personal",
                workspaceAccountID: "account-personal",
                storedAccountID: nil,
                selectionSource: .liveSystem,
                isActive: true,
                isLive: true,
                canReauthenticate: true,
                canRemove: false),
            CodexVisibleAccount(
                id: "managed:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                email: "pl.fr@yandex.com",
                workspaceLabel: "IDconcepts",
                workspaceAccountID: "account-team",
                storedAccountID: UUID(),
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
        #expect(titles.allSatisfy { $0.lowercased().contains("pl.") })
        #expect(titles[0].contains("|") == false)
        #expect(titles[0].lowercased().contains("pers") == false)
        #expect(titles[1].lowercased().contains("id"))
        #expect(toolTips == accounts.map(\.menuDisplayName))
        #expect(accounts[0].displayName == "pl.fr@yandex.com — Personal")
        #expect(accounts[0].menuDisplayName == "pl.fr@yandex.com")
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
    func `codex menu switcher can select managed row when same email rows split by identity`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let managedHome = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true)
        let managedAccountID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-222222222222"))
        let managedAccount = ManagedCodexAccount(
            id: managedAccountID,
            email: "same@example.com",
            managedHomePath: managedHome.path,
            createdAt: 1,
            updatedAt: 2,
            lastAuthenticatedAt: 2)
        try Self.writeCodexAuthFile(
            homeURL: managedHome,
            email: "same@example.com",
            plan: "pro",
            accountID: "account-managed")
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [managedAccount])
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: managedHome)
        }

        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "SAME@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .emailOnly(normalizedEmail: "same@example.com"))
        settings.codexActiveSource = .liveSystem

        let projection = settings.codexVisibleAccountProjection
        #expect(projection.visibleAccounts.count == 2)
        let managedVisibleAccount = try #require(projection.visibleAccounts
            .first { $0.storedAccountID == managedAccountID })

        #expect(settings.selectCodexVisibleAccount(id: managedVisibleAccount.id))
        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountID))
    }
}

extension StatusMenuCodexSwitcherTests {
    private static func writeCodexAuthFile(
        homeURL: URL,
        email: String,
        plan: String,
        accountID: String? = nil) throws
    {
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        var tokens: [String: Any] = [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": Self.fakeJWT(email: email, plan: plan, accountID: accountID),
        ]
        if let accountID {
            tokens["account_id"] = accountID
        }
        let auth = ["tokens": tokens]
        let data = try JSONSerialization.data(withJSONObject: auth)
        try data.write(to: homeURL.appendingPathComponent("auth.json"))
    }

    private static func fakeJWT(email: String, plan: String, accountID: String? = nil) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        var payloadObject: [String: Any] = [
            "email": email,
            "chatgpt_plan_type": plan,
        ]
        if let accountID {
            payloadObject["https://api.openai.com/auth"] = [
                "chatgpt_account_id": accountID,
            ]
        }
        let payload = (try? JSONSerialization.data(withJSONObject: payloadObject)) ?? Data()

        func base64URL(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }

        return "\(base64URL(header)).\(base64URL(payload))."
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

private struct TestManagedCodexHomeFactoryForStatusMenuTests: ManagedCodexHomeProducing {
    let root: URL

    func makeHomeURL() -> URL {
        self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func validateManagedHomeForDeletion(_ url: URL) throws {
        try ManagedCodexHomeFactory(root: self.root).validateManagedHomeForDeletion(url)
    }
}

private struct StubManagedCodexIdentityReaderForStatusMenuTests: ManagedCodexIdentityReading {
    let email: String

    func loadAccountIdentity(homePath _: String) throws -> CodexAuthBackedAccount {
        CodexAuthBackedAccount(
            identity: CodexIdentityResolver.resolve(accountId: nil, email: self.email),
            email: self.email,
            plan: "Pro")
    }
}
