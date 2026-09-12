import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

/// Menu-structure coverage for the compact claude-swap layout: with four or more
/// accounts the active account keeps its card, inactive accounts become compact
/// rows, the healthy tail collapses, and expansion state restores full cards.
@MainActor
final class StatusMenuClaudeSwapCompactTests: XCTestCase {
    private func makeController(
        accounts: [ProviderAccountUsageSnapshot],
        layout: MultiAccountMenuLayout = .stacked) -> (controller: StatusItemController, store: UsageStore)
    {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = testSettingsStore(
            suiteName: "StatusMenuClaudeSwapCompactTests",
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
        sessionUsed: Double,
        weeklyUsed: Double,
        canActivate: Bool = true) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: String(slot)),
            provider: .claude,
            displayLabel: email,
            isActive: isActive,
            canActivate: !isActive && canActivate,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: sessionUsed,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: weeklyUsed,
                    windowMinutes: 7 * 24 * 60,
                    resetsAt: Date().addingTimeInterval(86400),
                    resetDescription: nil),
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: email,
                    accountOrganization: nil,
                    loginMethod: "claude-swap")),
            error: nil,
            sourceLabel: "claude-swap")
    }

    private func sixAccounts() -> [ProviderAccountUsageSnapshot] {
        [
            self.account(slot: 1, email: "active@example.com", isActive: true, sessionUsed: 4, weeklyUsed: 1),
            self.account(slot: 2, email: "healthy-a@example.com", sessionUsed: 3, weeklyUsed: 5),
            self.account(slot: 3, email: "best@example.com", sessionUsed: 0, weeklyUsed: 0),
            self.account(slot: 4, email: "healthy-b@example.com", sessionUsed: 8, weeklyUsed: 4),
            self.account(slot: 5, email: "constrained@example.com", sessionUsed: 20, weeklyUsed: 97),
            self.account(slot: 6, email: "healthy-c@example.com", sessionUsed: 0, weeklyUsed: 2),
        ]
    }

    private func representedIDs(in menu: NSMenu) -> [String] {
        menu.items.compactMap { $0.representedObject as? String }
    }

    func test_segmentedRefreshKeepsOneSwitcherAndOneCard() {
        let accounts = Array(self.sixAccounts().prefix(2))
        let (controller, store) = self.makeController(accounts: accounts, layout: .segmented)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        for _ in 0..<2 {
            XCTAssertEqual(menu.items.count(where: { $0.view is ClaudeSwapAccountSwitcherView }), 1)
            XCTAssertEqual(self.representedIDs(in: menu).filter { $0.hasPrefix("menuCard") }, ["menuCard-0"])
            store.claudeSwapAccountSnapshots.reverse()
            controller.populateMenu(menu, provider: .claude)
        }
    }

    func test_segmentedSentinelInspectionNeverStartsActivationAndResetsOnClose() {
        let sentinel = self.account(
            slot: 9, email: "expired@example.com", sessionUsed: 0, weeklyUsed: 0, canActivate: false)
        let (controller, store) = self.makeController(
            accounts: [self.sixAccounts()[0], sentinel], layout: .segmented)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        controller.handleClaudeSwapAccountSelection(sentinel.id, menu: nil)
        XCTAssertEqual(controller.claudeSwapInspectedAccountID, sentinel.id)
        XCTAssertNil(store.claudeSwapTransientState.task)
        XCTAssertNil(store.claudeSwapTransientState.switchingAccountID)
        controller.settings.hidePersonalInfo = true
        controller.populateMenu(menu, provider: .claude)
        XCTAssertTrue(menu.items.contains { $0.title == "Details for Account 9" })
        XCTAssertFalse(menu.items.contains { $0.title.contains("expired@example.com") })
        controller.menuDidClose(menu)
        XCTAssertNil(controller.claudeSwapInspectedAccountID)
    }

    func test_segmentedFreshPersistentMenuDropsInspectionOnReopenWithoutRefresh() {
        for merged in [false, true] {
            let sentinel = self.account(
                slot: 9, email: "expired@example.com", sessionUsed: 0, weeklyUsed: 0, canActivate: false)
            let (controller, store) = self.makeController(
                accounts: [self.sixAccounts()[0], sentinel], layout: .segmented)
            defer { controller.releaseStatusItemsForTesting() }
            controller.settings.mergeIcons = merged
            let menu = controller.makeMenu(for: .claude)
            if merged {
                controller.mergedMenu = menu
            } else {
                controller.providerMenus[.claude] = menu
            }
            controller.menuWillOpen(menu)
            controller.handleClaudeSwapAccountSelection(sentinel.id, menu: nil)
            controller.populateMenu(menu, provider: .claude)
            controller.markMenuFresh(menu)
            XCTAssertTrue(menu.items.contains { $0.title.hasPrefix("Details for") })
            XCTAssertFalse(controller.menuNeedsRefresh(menu))
            let revision = store.claudeSwapRevision

            controller.menuDidClose(menu)
            controller.refreshMenuForOpenIfNeeded(menu, provider: .claude)

            XCTAssertNil(controller.claudeSwapInspectedAccountID)
            XCTAssertFalse(menu.items.contains { $0.title.hasPrefix("Details for") })
            XCTAssertFalse(controller.menuNeedsRefresh(menu))
            XCTAssertEqual(store.claudeSwapRevision, revision)
        }
    }

    func test_segmentedNoActiveAccountDoesNotDisplayAmbientUsage() {
        let inactive = self.account(slot: 7, email: "inactive@example.com", sessionUsed: 10, weeklyUsed: 20)
        let other = self.account(slot: 9, email: "other@example.com", sessionUsed: 30, weeklyUsed: 40)
        let (controller, store) = self.makeController(accounts: [inactive, other], layout: .segmented)
        defer { controller.releaseStatusItemsForTesting() }
        store.snapshots[.claude] = self.sixAccounts()[0].snapshot
        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        XCTAssertTrue(menu.items.contains { $0.title == "No active account" })
        XCTAssertFalse(self.representedIDs(in: menu).contains { $0.hasPrefix("menuCard") })
    }

    func test_segmentedInspectionPreservesNoActiveAccountNotice() {
        let sentinel = self.account(
            slot: 9, email: "expired@example.com", sessionUsed: 0, weeklyUsed: 0, canActivate: false)
        let inactive = self.account(slot: 7, email: "inactive@example.com", sessionUsed: 10, weeklyUsed: 20)
        let (controller, _) = self.makeController(accounts: [inactive, sentinel], layout: .segmented)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        controller.handleClaudeSwapAccountSelection(sentinel.id, menu: nil)
        controller.populateMenu(menu, provider: .claude)
        XCTAssertTrue(menu.items.contains { $0.title == "No active account" })
        XCTAssertEqual(self.representedIDs(in: menu).filter { $0.hasPrefix("menuCard") }, ["menuCard-0"])
    }

    func test_manyAccountsRenderCompactLayoutRows() {
        let (controller, _) = self.makeController(accounts: self.sixAccounts())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)

        let ids = self.representedIDs(in: menu).filter {
            $0.hasPrefix("claudeSwap") || $0.hasPrefix("menuCard")
        }
        XCTAssertEqual(ids, [
            "claudeSwapCard-1",
            "claudeSwapCompact-5",
            "claudeSwapCompact-3",
            "claudeSwapCollapsed",
        ])
    }

    func test_expandedAccountRendersFullCard() {
        let accounts = self.sixAccounts()
        let (controller, _) = self.makeController(accounts: accounts)
        defer { controller.releaseStatusItemsForTesting() }
        controller.compactAccountExpandedIDs = [accounts[4].id]

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)

        let ids = self.representedIDs(in: menu).filter { $0.hasPrefix("claudeSwap") }
        XCTAssertEqual(ids, [
            "claudeSwapCard-1",
            "claudeSwapCard-5",
            "claudeSwapCompact-3",
            "claudeSwapCollapsed",
        ])
    }

    func test_expandedHealthyTailShowsAllCompactRows() {
        let (controller, _) = self.makeController(accounts: self.sixAccounts())
        defer { controller.releaseStatusItemsForTesting() }
        controller.compactAccountExpandedHealthyTailProviders = [.claude]

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)

        let ids = self.representedIDs(in: menu).filter { $0.hasPrefix("claudeSwap") }
        XCTAssertEqual(ids, [
            "claudeSwapCard-1",
            "claudeSwapCompact-5",
            "claudeSwapCompact-4",
            "claudeSwapCompact-2",
            "claudeSwapCompact-6",
            "claudeSwapCompact-3",
        ])
    }

    func test_fewAccountsKeepStackedCards() {
        let (controller, _) = self.makeController(accounts: Array(self.sixAccounts().prefix(3)))
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)

        let ids = self.representedIDs(in: menu).filter {
            $0.hasPrefix("claudeSwap") || $0.hasPrefix("menuCard")
        }
        XCTAssertEqual(ids, ["menuCard-0", "menuCard-1", "menuCard-2"])
    }

    func test_menuCloseResetsExpansionState() {
        let accounts = self.sixAccounts()
        let (controller, _) = self.makeController(accounts: accounts)
        defer { controller.releaseStatusItemsForTesting() }
        controller.compactAccountExpandedIDs = [accounts[4].id]
        controller.compactAccountExpandedHealthyTailProviders = [.claude]

        let menu = controller.makeMenu(for: .claude)
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)

        XCTAssertTrue(controller.compactAccountExpandedIDs.isEmpty)
        XCTAssertTrue(controller.compactAccountExpandedHealthyTailProviders.isEmpty)
    }
}
