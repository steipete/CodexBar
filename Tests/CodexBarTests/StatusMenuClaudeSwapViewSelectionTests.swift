import AppKit
import CodexBarCore
import Foundation
import Testing
import XCTest
@testable import CodexBar

/// Menu-model coverage for view-only claude-swap account selection: clicking a segment changes
/// which account's details the menu renders and never asks the adapter to activate that slot.
/// No real `cswap` executable, provider probe, or Keychain read is involved.
@MainActor
final class StatusMenuClaudeSwapViewSelectionTests: XCTestCase {
    private static let executablePath = "/private/tmp/codexbar-tests/does-not-exist/cswap"

    private func makeController(
        accounts: [ProviderAccountUsageSnapshot],
        layout: MultiAccountMenuLayout = .segmented) -> (controller: StatusItemController, store: UsageStore)
    {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = testSettingsStore(
            suiteName: "StatusMenuClaudeSwapViewSelectionTests",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = layout
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .claude)
        }
        // The adapter is configured, never executed: every test drives snapshots directly.
        settings.claudeSwapEnabled = true
        settings.claudeSwapExecutablePath = Self.executablePath

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.claudeSwapAccountSnapshots = accounts
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (controller, store)
    }

    private func account(
        slot: Int,
        email: String,
        isActive: Bool = false,
        canActivate: Bool = true,
        hasUsage: Bool = true) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: String(slot)),
            provider: .claude,
            displayLabel: email,
            isActive: isActive,
            canActivate: !isActive && canActivate,
            snapshot: hasUsage
                ? UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 10,
                        windowMinutes: 300,
                        resetsAt: Date().addingTimeInterval(3600),
                        resetDescription: nil),
                    secondary: RateWindow(
                        usedPercent: 20,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: Date().addingTimeInterval(86400),
                        resetDescription: nil),
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .claude,
                        accountEmail: email,
                        accountOrganization: nil,
                        loginMethod: "claude-swap"))
                : nil,
            error: nil,
            sourceLabel: "claude-swap")
    }

    private func activeAndInactive() -> [ProviderAccountUsageSnapshot] {
        [
            self.account(slot: 2, email: "active@example.com", isActive: true),
            self.account(slot: 7, email: "healthy@example.com"),
        ]
    }

    private func cardIDs(in menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }.filter { $0.hasPrefix("menuCard") }
    }

    private func assertNoActivationStarted(_ store: UsageStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(store.claudeSwapTransientState.task, file: file, line: line)
        XCTAssertNil(store.claudeSwapTransientState.switchingAccountID, file: file, line: line)
        XCTAssertNil(store.claudeSwapTransientState.lastError, file: file, line: line)
        XCTAssertNil(store.claudeSwapTransientState.lastErrorAccountID, file: file, line: line)
    }

    /// Requirement 1: a segment click is view-only, even for a healthy inactive account.
    func test_viewingHealthyInactiveAccountNeverStartsActivation() {
        let accounts = self.activeAndInactive()
        let (controller, store) = self.makeController(accounts: accounts)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        let revision = store.claudeSwapRevision

        controller.handleClaudeSwapAccountSelection(accounts[1].id, menu: nil)

        XCTAssertEqual(controller.claudeSwapViewedAccountID, accounts[1].id)
        self.assertNoActivationStarted(store)
        XCTAssertEqual(store.claudeSwapRevision, revision)

        controller.populateMenu(menu, provider: .claude)
        // The highlighted segment identifies the viewed account; no redundant heading is added.
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Details for") })
        XCTAssertEqual(self.cardIDs(in: menu), ["menuCard-0"])
    }

    /// Requirement 2: the card keeps its explicit activation action, still gated by validation
    /// and by the single-transaction serialization guard.
    func test_explicitSwitchActionStaysAvailableAndGated() {
        let unavailable = self.account(slot: 3, email: "expired@example.com", canActivate: false)
        let accounts = self.activeAndInactive() + [unavailable]
        let (controller, store) = self.makeController(accounts: accounts)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)

        XCTAssertEqual(controller.claudeSwapAccountActionLabel(accounts[0]), "Active")
        XCTAssertEqual(controller.claudeSwapAccountActionLabel(accounts[1]), "Switch Account...")
        XCTAssertNil(controller.claudeSwapAccountActionLabel(unavailable))
        XCTAssertNotNil(controller.claudeSwapAccountSwitchAction(accounts[1], menu: menu))
        XCTAssertNil(controller.claudeSwapAccountSwitchAction(unavailable, menu: menu))
        XCTAssertNil(controller.claudeSwapAccountSwitchAction(accounts[0], menu: menu))

        // A pending transaction serializes activation without blocking inspection.
        store.claudeSwapTransientState.switchingAccountID = accounts[1].id
        store.claudeSwapTransientState.task = Task {}
        defer { store.claudeSwapTransientState.task = nil }
        XCTAssertEqual(controller.claudeSwapAccountActionLabel(accounts[1]), "Loading…")
        XCTAssertNil(controller.claudeSwapAccountSwitchAction(accounts[1], menu: menu))
        controller.handleClaudeSwapAccountSelection(unavailable.id, menu: nil)
        XCTAssertEqual(controller.claudeSwapViewedAccountID, unavailable.id)
    }

    /// Requirement 2: the store rejects activation of a slot the adapter did not mark actionable,
    /// so no subprocess is ever launched for it.
    func test_storeRejectsActivationOfUnavailableSlot() {
        let unavailable = self.account(slot: 3, email: "expired@example.com", canActivate: false)
        let (_, store) = self.makeController(accounts: [self.activeAndInactive()[0], unavailable])

        store.switchClaudeSwapAccount(unavailable.id)
        self.assertNoActivationStarted(store)

        store.switchClaudeSwapAccount(ProviderAccountIdentity(source: "claude-swap", opaqueID: "42"))
        self.assertNoActivationStarted(store)
    }

    /// Requirements 4 and 5: the selection is identity-based, so it survives menu closes,
    /// adapter refreshes, and list reordering within the session.
    func test_viewSelectionSurvivesMenuCloseRefreshAndReordering() {
        let accounts = self.activeAndInactive()
        let (controller, store) = self.makeController(accounts: accounts)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)
        controller.providerMenus[.claude] = menu
        controller.menuWillOpen(menu)
        controller.handleClaudeSwapAccountSelection(accounts[1].id, menu: nil)

        controller.menuDidClose(menu)
        XCTAssertEqual(controller.claudeSwapViewedAccountID, accounts[1].id)

        // A refresh that reorders the list and rewrites labels keeps the same stable slot viewed.
        store.claudeSwapAccountSnapshots = [
            self.account(slot: 7, email: "renamed@example.com"),
            self.account(slot: 2, email: "active@example.com", isActive: true),
        ]
        controller.menuWillOpen(menu)
        controller.populateMenu(menu, provider: .claude)
        XCTAssertEqual(controller.claudeSwapViewedAccountID, accounts[1].id)
        XCTAssertEqual(self.cardIDs(in: menu), ["menuCard-0"])
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Details for") })
        self.assertNoActivationStarted(store)
    }

    /// Requirement 5: the selection belongs to one adapter configuration. Drives the real
    /// teardown the provider runtime performs, rather than calling the cleanup helper directly —
    /// an earlier version of this test did the latter and hid that nothing in production ran it.
    func test_adapterConfigurationChangeClearsViewSelection() {
        for change in ["disable", "path", "disableThenReEnableSamePath"] {
            let accounts = self.activeAndInactive()
            let (controller, store) = self.makeController(accounts: accounts)
            defer { controller.releaseStatusItemsForTesting() }
            controller.handleClaudeSwapAccountSelection(accounts[1].id, menu: nil)
            XCTAssertEqual(controller.claudeSwapViewedAccountID, accounts[1].id, change)

            switch change {
            case "disable":
                controller.settings.claudeSwapEnabled = false
                store.clearClaudeSwapAccountState()
            case "path":
                controller.settings.claudeSwapExecutablePath = Self.executablePath + "-other"
                store.clearClaudeSwapAccountState()
            default:
                // Disable and re-enable on the same executable: the configuration key must not
                // return to its previous value and restore the discarded selection.
                controller.settings.claudeSwapEnabled = false
                store.clearClaudeSwapAccountState()
                controller.settings.claudeSwapEnabled = true
                store.claudeSwapAccountSnapshots = accounts
            }

            XCTAssertNil(controller.claudeSwapViewedAccountID, change)
            controller.discardStaleClaudeSwapViewSelection()
            XCTAssertNil(controller.claudeSwapViewSelection, change)
        }
    }

    /// Requirement 5: a slot that leaves the list falls back to the source-reported active
    /// account, and to nothing at all when the adapter reports no active account.
    func test_removedViewedSlotFallsBackToSourceActiveAccount() {
        let accounts = self.activeAndInactive()
        let (controller, store) = self.makeController(accounts: accounts)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        controller.handleClaudeSwapAccountSelection(accounts[1].id, menu: nil)

        store.claudeSwapAccountSnapshots = [
            accounts[0],
            self.account(slot: 8, email: "new@example.com"),
        ]
        controller.populateMenu(menu, provider: .claude)
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Details for") })
        XCTAssertFalse(menu.items.contains { $0.title == "No active account" })

        store.claudeSwapAccountSnapshots = [
            self.account(slot: 5, email: "one@example.com"),
            self.account(slot: 8, email: "new@example.com"),
        ]
        controller.populateMenu(menu, provider: .claude)
        XCTAssertTrue(menu.items.contains { $0.title == "No active account" })
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Details for") })
        self.assertNoActivationStarted(store)
    }

    /// Requirement 6: unavailable accounts stay inspectable, and their card offers no activation.
    func test_unavailableAccountIsViewableWithoutActivation() {
        let unavailable = self.account(
            slot: 9, email: "expired@example.com", canActivate: false, hasUsage: false)
        let accounts = [self.activeAndInactive()[0], unavailable]
        let (controller, store) = self.makeController(accounts: accounts)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)

        controller.handleClaudeSwapAccountSelection(unavailable.id, menu: nil)

        XCTAssertEqual(controller.claudeSwapViewedAccountID, unavailable.id)
        self.assertNoActivationStarted(store)
        controller.settings.hidePersonalInfo = true
        controller.populateMenu(menu, provider: .claude)
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Details for") })
        XCTAssertFalse(menu.items.contains { $0.title.contains("expired@example.com") })
        XCTAssertNil(controller.claudeSwapCardModel(for: unavailable)?.planText)
    }

    /// Requirement 7: a later view selection wins over pending/failed activation state, while the
    /// activation error stays attached to the account it belongs to.
    func test_viewSelectionOutranksFailedActivationWhoseErrorStaysOnItsAccount() throws {
        let accounts = self.activeAndInactive()
        let failed = self.account(slot: 4, email: "failed@example.com")
        let (controller, store) = self.makeController(accounts: accounts + [failed])
        defer { controller.releaseStatusItemsForTesting() }
        store.claudeSwapTransientState.lastError = "switch failed"
        store.claudeSwapTransientState.lastErrorAccountID = failed.id
        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)

        controller.handleClaudeSwapAccountSelection(accounts[1].id, menu: nil)
        controller.populateMenu(menu, provider: .claude)

        XCTAssertEqual(controller.claudeSwapViewedAccountID, accounts[1].id)
        XCTAssertEqual(store.claudeSwapTransientState.lastErrorAccountID, failed.id)
        let failedCard = try XCTUnwrap(controller.claudeSwapCardModel(for: failed))
        XCTAssertTrue(failedCard.subtitleText.contains("switch failed"), failedCard.subtitleText)
        let healthyCard = try XCTUnwrap(controller.claudeSwapCardModel(for: accounts[1]))
        XCTAssertFalse(healthyCard.subtitleText.contains("switch failed"), healthyCard.subtitleText)
    }

    /// Requirement 8: the stacked layout still renders one card per account and never consults the
    /// view selection.
    func test_stackedLayoutIgnoresViewSelection() {
        let accounts = self.activeAndInactive()
        let (controller, store) = self.makeController(accounts: accounts, layout: .stacked)
        defer { controller.releaseStatusItemsForTesting() }
        controller.handleClaudeSwapAccountSelection(accounts[1].id, menu: nil)

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)

        XCTAssertEqual(
            menu.items.compactMap { $0.representedObject as? String }.filter { $0.hasPrefix("menuCard") },
            ["menuCard-0", "menuCard-1"])
        XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Details for") })
        self.assertNoActivationStarted(store)
    }
}

/// Coverage for treating the settings placeholder (`~/.local/bin/cswap`) as a real default, so
/// enabling the adapter works without also typing the path. The filesystem probe is injected, so
/// these never depend on whether the running machine has claude-swap installed.
@MainActor
struct ClaudeSwapDefaultExecutablePathTests {
    private let defaultPath = "/Users/example/.local/bin/cswap"

    private func resolve(configured: String, installed: Set<String>) -> String {
        ClaudeSwapExecutableResolver.resolve(
            configured: configured,
            defaultPath: self.defaultPath,
            isExecutable: { installed.contains($0) })
    }

    @Test
    func `an unset path falls back to the default location when claude-swap is installed there`() {
        #expect(self.resolve(configured: "", installed: [self.defaultPath]) == self.defaultPath)
        #expect(self.resolve(configured: "   ", installed: [self.defaultPath]) == self.defaultPath)
    }

    @Test
    func `an unset path stays empty when nothing is installed at the default location`() {
        // Users without claude-swap must keep seeing no adapter activity and no recurring error.
        #expect(self.resolve(configured: "", installed: []).isEmpty)
    }

    @Test
    func `an explicitly configured path always wins over the default`() {
        let custom = "/opt/homebrew/bin/cswap"
        #expect(self.resolve(configured: custom, installed: [self.defaultPath, custom]) == custom)
        // Even an explicit path that is missing wins, so the user sees an error about their choice
        // rather than silently running a different executable.
        #expect(self.resolve(configured: custom, installed: [self.defaultPath]) == custom)
        #expect(self.resolve(configured: "  \(custom)  ", installed: []) == custom)
    }

    @Test
    func `the default matches the path advertised as the settings placeholder`() {
        #expect(ClaudeSwapExecutableResolver.defaultExecutablePath.hasSuffix("/.local/bin/cswap"))
        #expect(!ClaudeSwapExecutableResolver.defaultExecutablePath.hasPrefix("~"))
    }
}

/// Coverage for the grouped claude-swap settings section that replaced the separate toggle and
/// path field, so its guidance text matches what the adapter will actually do.
@MainActor
struct ClaudeSwapSectionStateTests {
    private func state(
        enabled: Bool = true,
        configured: String = "",
        resolved: String = "/Users/example/.local/bin/cswap",
        version: String? = nil,
        refreshedAt: Date? = nil,
        error: String? = nil,
        accounts: [ClaudeSwapSectionAccountRow] = []) -> ClaudeSwapSectionState
    {
        ClaudeSwapSectionState(
            isEnabled: enabled,
            configuredPath: configured,
            resolvedPath: resolved,
            defaultPath: "/Users/example/.local/bin/cswap",
            detectedVersion: version,
            lastRefreshAt: refreshedAt,
            lastError: error,
            accounts: accounts)
    }

    @Test
    func `the status line never repeats the path the field already shows`() {
        // The field shows the default as its placeholder (or the chosen path as its value), so
        // printing it again below crowded the row.
        let usingDefault = self.state(version: "0.24.1", refreshedAt: Date())
        #expect(usingDefault.usesDefaultPath)
        let status = usingDefault.statusText ?? ""
        #expect(!status.contains("/Users/example"))
        #expect(status.contains("claude-swap 0.24.1"))

        let explicit = self.state(
            configured: "/opt/homebrew/bin/cswap",
            resolved: "/opt/homebrew/bin/cswap",
            version: "0.24.1",
            refreshedAt: Date())
        #expect(!explicit.usesDefaultPath)
        #expect(explicit.statusText?.contains("/opt/homebrew") == false)
    }

    @Test
    func `a missing executable names the default location in its short form`() {
        let state = self.state(resolved: "")
        #expect(state.needsPath)
        #expect(state.statusText == "No cswap executable at ~/.local/bin/cswap.")
        // Placeholder and message agree, and neither uses the expanded absolute path.
        #expect(ClaudeSwapSectionState.defaultPathPlaceholder == "~/.local/bin/cswap")
    }

    @Test
    func `status reports version, account count and errors only once usable`() {
        let refreshed = Date()
        let rows = [
            ClaudeSwapSectionAccountRow(
                id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "1"),
                label: "Account 1",
                isActive: true,
                note: nil),
            ClaudeSwapSectionAccountRow(
                id: ProviderAccountIdentity(source: "claude-swap", opaqueID: "2"),
                label: "Account 2",
                isActive: false,
                note: "Credentials expired"),
        ]
        let ok = self.state(version: "0.24.1", refreshedAt: refreshed, accounts: rows)
        let status = try? #require(ok.statusText)
        #expect(status?.contains("claude-swap 0.24.1") == true)
        #expect(status?.contains("2 accounts") == true)

        let failed = self.state(version: "0.24.1", refreshedAt: refreshed, error: "store locked", accounts: rows)
        #expect(failed.statusText?.contains("store locked") == true)
        #expect(failed.statusText?.contains("2 accounts") == false)

        // A disabled adapter says nothing at all.
        #expect(self.state(enabled: false, version: "0.24.1").statusText == nil)
    }
}
