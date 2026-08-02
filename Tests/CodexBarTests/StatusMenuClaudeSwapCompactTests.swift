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
        accounts: [ProviderAccountUsageSnapshot]) -> (controller: StatusItemController, store: UsageStore)
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
        weeklyUsed: Double) -> ProviderAccountUsageSnapshot
    {
        ProviderAccountUsageSnapshot(
            id: ProviderAccountIdentity(source: "claude-swap", opaqueID: String(slot)),
            provider: .claude,
            displayLabel: email,
            isActive: isActive,
            canActivate: !isActive,
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
