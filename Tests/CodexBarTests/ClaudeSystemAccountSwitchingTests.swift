import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// System Account switching for claude-swap through the shared provider hooks. Every executable is a local stub;
/// the follow-up Claude refresh is replaced, so no real account, credential or provider probe is involved.
@MainActor
struct ClaudeSystemAccountSwitchingTests {
    @Test
    func `entries mark the active slot as system and honor hide personal info`() throws {
        let (settings, store) = self.makeStore()
        try self.configure(settings, executable: "/path/to/cswap")
        settings.hidePersonalInfo = true
        store.claudeSwapAccountSnapshots = [
            self.account("1", active: true),
            self.account("2"),
            self.account("9", canActivate: false),
        ]

        let entries = try #require(ClaudeProviderImplementation().systemAccountMenuEntries(
            context: self.context(settings, store)))

        #expect(entries.cliName == "Claude Code")
        #expect(!entries.isBlocked)
        #expect(entries.entries == [
            .init(accountID: "1", title: "Account 1", isSystem: true, isSwitchable: false),
            .init(accountID: "2", title: "Account 2", isSystem: false, isSwitchable: true),
            .init(accountID: "9", title: "Account 9", isSystem: false, isSwitchable: false),
        ])
    }

    @Test
    func `no entries while claude swap does not own account presentation`() throws {
        let (settings, store) = self.makeStore()
        try self.configure(settings, executable: "/path/to/cswap")
        store.claudeSwapAccountSnapshots = [self.account("1", active: true)]
        #expect(ClaudeProviderImplementation().systemAccountMenuEntries(context: self.context(settings, store)) == nil)
    }

    @Test
    func `successful switch reports succeeded`() async throws {
        let (settings, store) = self.makeStore()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cswap-\(UUID().uuidString)")
        try self.configure(settings, executable: self.makeSwitchExecutable(marker: marker))
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("2")]
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }

        let outcome = await ClaudeProviderImplementation().switchSystemAccount(
            accountID: "2",
            context: self.context(settings, store))

        #expect(outcome == .succeeded)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "--switch-to\n2\n--json\n")
    }

    @Test
    func `failed switch reports the claude swap error`() async throws {
        let (settings, store) = self.makeStore()
        try self.configure(settings, executable: self.makeFailedSwitchExecutable())
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("2")]
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }

        let outcome = await ClaudeProviderImplementation().switchSystemAccount(
            accountID: "2",
            context: self.context(settings, store))

        guard case let .failed(title, message) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(title == "Could not switch system account")
        #expect(message.contains("credentials missing"))
    }

    @Test
    func `unavailable slot reports failed without running cswap`() async throws {
        let (settings, store) = self.makeStore()
        try self.configure(settings, executable: "/path/to/cswap")
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("9", canActivate: false)]

        let outcome = await ClaudeProviderImplementation().switchSystemAccount(
            accountID: "9",
            context: self.context(settings, store))

        #expect(outcome == .failed(
            title: "Could not switch system account",
            message: "That account can no longer be switched to."))
        #expect(store.claudeSwapTransientState.task == nil)
    }

    @Test
    func `controller switch posts a success notice when no menu is open`() async throws {
        let (settings, store) = self.makeStore()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cswap-\(UUID().uuidString)")
        try self.configure(settings, executable: self.makeSwitchExecutable(marker: marker))
        settings.hidePersonalInfo = true
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("2")]
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }
        var notices: [SystemAccountSwitchFeedback.Notice] = []
        controller._test_systemAccountNoticeObserver = { _, notice in notices.append(notice) }

        let task = try #require(controller.startSystemAccountSwitch(provider: .claude, accountID: "2"))
        #expect(controller.systemAccountSwitchFeedback.isSwitching(.claude))
        #expect(controller.startSystemAccountSwitch(provider: .claude, accountID: "2") == nil)
        await task.value

        #expect(notices == [.init(title: "System account switched", body: "Claude Code now uses Account 2")])
        #expect(controller.systemAccountSwitchFeedback.subtitle(for: .claude, accountID: "2")
            == .init(text: "Account 2 is now the System account", style: .info))
    }

    @Test
    func `a published switch error outranks switching progress on the card`() throws {
        let (settings, store) = self.makeStore()
        try self.configure(settings, executable: "/path/to/cswap")
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("2")]
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }
        let target = store.claudeSwapAccountSnapshots[1]

        controller.systemAccountSwitchFeedback.begin(
            provider: .claude, accountID: "2", label: "Account 2", cliName: "Claude Code")
        #expect(try #require(controller.claudeSwapCardModel(for: target)).subtitleStyle == .loading)

        // claude-swap publishes its error before the follow-up Claude refresh finishes.
        store.claudeSwapTransientState.lastError = "credentials missing"
        store.claudeSwapTransientState.lastErrorAccountID = target.id
        let failed = try #require(controller.claudeSwapCardModel(for: target))
        #expect(failed.subtitleStyle == .error)
        #expect(failed.subtitleText.contains("credentials missing"))
    }

    @Test
    func `an undelivered failure notice falls back to an alert`() async throws {
        let (settings, store) = self.makeStore()
        try self.configure(settings, executable: self.makeFailedSwitchExecutable())
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("2")]
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }
        var alerts: [(String, String)] = []
        controller._test_systemAccountNoticeDelivery = { _ in false }
        controller._test_systemAccountAlertObserver = { alerts.append(($0, $1)) }

        let task = try #require(controller.startSystemAccountSwitch(provider: .claude, accountID: "2"))
        await task.value

        #expect(alerts.count == 1)
        #expect(alerts.first?.0 == "Could not switch system account")
        #expect(alerts.first?.1.contains("credentials missing") == true)
    }

    @Test
    func `an undelivered success notice does not raise an alert`() async throws {
        let (settings, store) = self.makeStore()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cswap-\(UUID().uuidString)")
        try self.configure(settings, executable: self.makeSwitchExecutable(marker: marker))
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("2")]
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }
        var alerts = 0
        controller._test_systemAccountNoticeDelivery = { _ in false }
        controller._test_systemAccountAlertObserver = { _, _ in alerts += 1 }

        let task = try #require(controller.startSystemAccountSwitch(provider: .claude, accountID: "2"))
        await task.value

        #expect(alerts == 0)
    }

    @Test
    func `pending switch cards honor privacy enabled after switching starts`() throws {
        let (settings, store) = self.makeStore()
        try self.configure(settings, executable: "/path/to/cswap")
        settings.hidePersonalInfo = false
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("2")]
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }
        let target = store.claudeSwapAccountSnapshots[1]
        controller.systemAccountSwitchFeedback.begin(
            provider: .claude, accountID: "2", label: "person.2@example.com", cliName: "Claude Code")

        settings.hidePersonalInfo = true

        let card = try #require(controller.claudeSwapCardModel(for: target))
        #expect(card.subtitleText == "Switching Claude Code to Account 2…")
    }

    @Test
    func `completion notices honor privacy enabled during a switch`() async throws {
        let (settings, store) = self.makeStore()
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("cswap-\(UUID().uuidString)")
        try self.configure(settings, executable: self.makeSwitchExecutable(marker: marker))
        settings.hidePersonalInfo = false
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("2")]
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }
        var notices: [SystemAccountSwitchFeedback.Notice] = []
        controller._test_systemAccountNoticeObserver = { _, notice in notices.append(notice) }

        let task = try #require(controller.startSystemAccountSwitch(provider: .claude, accountID: "2"))
        settings.hidePersonalInfo = true
        await task.value

        #expect(notices == [.init(title: "System account switched", body: "Claude Code now uses Account 2")])
    }

    @Test
    func `retained success uses a generic private label after the account disappears`() throws {
        let (settings, store) = self.makeStore()
        try self.configure(settings, executable: "/path/to/cswap")
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }
        controller.systemAccountSwitchFeedback.begin(
            provider: .claude, accountID: "2", label: "person.2@example.com", cliName: "Claude Code")
        controller.systemAccountSwitchFeedback.finish(provider: .claude, outcome: .succeeded)

        settings.hidePersonalInfo = true
        store.claudeSwapAccountSnapshots = []

        let feedback = controller.systemAccountSwitchDisplayFeedback(for: .claude)
        #expect(feedback.subtitle(for: .claude, accountID: "2")?.text == "Account is now the System account")
        #expect(feedback.notification(for: .claude)?.body == "Claude Code now uses Account")
    }

    @Test
    func `deferred notice retains its transaction while using current privacy`() throws {
        let (settings, store) = self.makeStore()
        try self.configure(settings, executable: "/path/to/cswap")
        settings.hidePersonalInfo = false
        store.claudeSwapAccountSnapshots = [self.account("1", active: true), self.account("2")]
        let controller = self.makeController(settings: settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }
        controller.systemAccountSwitchFeedback.begin(
            provider: .claude, accountID: "2", label: "person.2@example.com", cliName: "Claude Code")
        controller.systemAccountSwitchFeedback.finish(provider: .claude, outcome: .succeeded)
        let pendingNoticeFeedback = controller.systemAccountSwitchFeedback

        controller.systemAccountSwitchFeedback.menuDidClose()
        settings.hidePersonalInfo = true

        let notice = controller.systemAccountSwitchDisplayFeedback(for: .claude, feedback: pendingNoticeFeedback)
            .notification(for: .claude)
        #expect(notice?.body == "Claude Code now uses Account 2")
    }

    // MARK: - Fixtures

    private func makeController(settings: SettingsStore, store: UsageStore) -> StatusItemController {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        return StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
    }

    private func context(_ settings: SettingsStore, _ store: UsageStore) -> SystemAccountSwitchContext {
        SystemAccountSwitchContext(store: store, settings: settings, codexAccountPromotionCoordinator: nil)
    }

    private func configure(_ settings: SettingsStore, executable: String) throws {
        let metadata = try #require(ProviderRegistry.shared.metadata[.claude])
        settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        settings.claudeSwapExecutablePath = executable
        settings.claudeSwapEnabled = true
    }

    private func account(_ slot: String, active: Bool = false, canActivate: Bool = true)
        -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: ClaudeSwapAccountProjection.sourceName, opaqueID: slot),
            provider: .claude,
            displayLabel: "person.\(slot)@example.com",
            isActive: active,
            canActivate: !active && canActivate,
            snapshot: nil,
            error: nil,
            sourceLabel: ClaudeSwapAccountProjection.sourceLabel)
    }

    private func makeStore() -> (SettingsStore, UsageStore) {
        let suite = "ClaudeSystemAccountSwitchingTests-\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults()
        defaults.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
        defaults.set(true, forKey: "codexbar.legacySecretsMigrationCompleted")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        return (settings, store)
    }

    private func makeSwitchExecutable(marker: URL) throws -> String {
        try self.writeExecutable(
            prefix: "claude-system-switch",
            body: """
            printf '%s\\n' "$@" > '\(marker.path)'
            echo '{"schemaVersion":1,"switched":true,"from":{"number":1},"to":{"number":2},"reason":"switched"}'
            """)
    }

    private func makeFailedSwitchExecutable() throws -> String {
        try self.writeExecutable(
            prefix: "claude-system-switch-failed",
            body: """
            echo '{"schemaVersion":1,"error":{"type":"SwitchError","message":"credentials missing"}}'
            exit 1
            """)
    }

    private func writeExecutable(prefix: String, body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cswap")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}
