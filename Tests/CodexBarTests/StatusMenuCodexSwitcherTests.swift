import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusMenuCodexSwitcherTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.menuRefreshEnabled = false
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
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

    private func codexSwitcherButtons(in menu: NSMenu) -> [NSButton] {
        guard let switcherView = menu.items.compactMap({ $0.view as? CodexAccountSwitcherView }).first
        else { return [] }
        return self.buttons(in: switcherView).sorted { $0.title < $1.title }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        let directButtons = view.subviews.compactMap { $0 as? NSButton }
        let nestedButtons = view.subviews.flatMap { self.buttons(in: $0) }
        return directButtons + nestedButtons
    }

    private func menuItem(titled title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
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
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let buttons = self.codexSwitcherButtons(in: menu)
        #expect(buttons.map(\.title) == ["live@example.com", "managed@example.com"])
        #expect(self.menuItem(titled: "Add Account...", in: menu) != nil)
        #expect(self.menuItem(titled: "Switch Account...", in: menu) == nil)
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
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        #expect(self.codexSwitcherButtons(in: menu).isEmpty)
        #expect(self.menuItem(titled: "Add Account...", in: menu) != nil)
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

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let managedButton = try #require(self.codexSwitcherButtons(in: menu)
            .first { $0.title == "managed@example.com" })
        managedButton.performClick(nil)

        #expect(settings.codexActiveSource == .managedAccount(id: managedAccountID))
    }

    @Test
    func `codex menu disables add account while managed authentication is in flight`() async throws {
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
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            managedCodexAccountCoordinator: coordinator,
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let addItem = try #require(self.menuItem(titled: "Add Account...", in: menu))
        #expect(addItem.isEnabled == false)
        if #available(macOS 14.4, *) {
            #expect(addItem.subtitle == "Managed Codex login in progress…")
        } else {
            #expect(addItem.toolTip?.contains("Managed Codex login in progress") == true)
        }

        await runner.resume()
        _ = try await authTask.value
    }

    @Test
    func `codex menu disables add account when managed store is unreadable`() {
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
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let addItem = try? #require(self.menuItem(titled: "Add Account...", in: menu))
        #expect(addItem?.isEnabled == false)
        if #available(macOS 14.4, *) {
            #expect(addItem?.subtitle == "Managed account storage unavailable")
        } else {
            #expect(addItem?.toolTip?.contains("Managed account storage unavailable") == true)
        }
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
