import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

/// Coverage for the compact multi-account layout on the token-account and Codex
/// paths (the claude-swap path is covered by StatusMenuClaudeSwapCompactTests).
@MainActor
final class StatusMenuCompactAccountLayoutTests: XCTestCase {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
    }

    private func makeSettings() -> SettingsStore {
        let settings = testSettingsStore(
            suiteName: "StatusMenuCompactAccountLayoutTests",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .stacked
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .copilot)
        }
        return settings
    }

    private func snapshot(usedPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 300,
                resetsAt: Date().addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: Date(),
            identity: nil)
    }

    func test_tokenAccountsUseCompactLayoutAtFourOrMoreAccounts() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        for label in ["One", "Two", "Three", "Four", "Five"] {
            settings.addTokenAccount(provider: .copilot, label: label, token: "gh_\(label)")
        }
        settings.setActiveTokenAccountIndex(0, for: .copilot)
        let accounts = settings.tokenAccounts(for: .copilot)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let usedPercents: [Double] = [10, 95, 20, 30, 40]
        store.accountSnapshots[.copilot] = accounts.enumerated().map { index, account in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(usedPercent: usedPercents[index]),
                error: nil,
                sourceLabel: "test",
                cacheKey: store.tokenAccountSnapshotCacheKey(provider: .copilot, account: account))
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .copilot)
        controller.menuWillOpen(menu)

        // Active card + critical row + best-candidate row + two healthy rows folded.
        let ids = menu.items.compactMap { $0.representedObject as? String }
            .filter { $0.hasPrefix("tokenAccount") || $0.hasPrefix("menuCard") }
        XCTAssertEqual(ids, [
            "tokenAccountCard-\(accounts[0].id.uuidString)",
            "tokenAccountCompact-\(accounts[1].id.uuidString)",
            "tokenAccountCompact-\(accounts[2].id.uuidString)",
            "tokenAccountCollapsed",
        ])
    }

    func test_tokenAccountsBelowThresholdKeepStackedCards() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        for label in ["One", "Two", "Three"] {
            settings.addTokenAccount(provider: .copilot, label: label, token: "gh_\(label)")
        }
        let accounts = settings.tokenAccounts(for: .copilot)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.accountSnapshots[.copilot] = accounts.map { account in
            TokenAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(usedPercent: 10),
                error: nil,
                sourceLabel: "test",
                cacheKey: store.tokenAccountSnapshotCacheKey(provider: .copilot, account: account))
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu(for: .copilot)
        controller.menuWillOpen(menu)

        let ids = menu.items.compactMap { $0.representedObject as? String }
            .filter { $0.hasPrefix("tokenAccount") || $0.hasPrefix("menuCard") }
        XCTAssertEqual(ids, ["menuCard-0", "menuCard-1", "menuCard-2"])
    }

    func test_codexAccountProjectionMapsActiveHealthAndIdentity() {
        let accounts = (1...4).map { index in
            CodexVisibleAccount(
                id: "account-\(index)",
                email: "codex\(index)@example.com",
                // account-4: stored account without live auth → "Missing auth" health.
                storedAccountID: index == 4 ? UUID() : nil,
                selectionSource: .liveSystem,
                isActive: index == 2,
                isLive: index != 4,
                canReauthenticate: false,
                canRemove: false)
        }
        let snapshots = accounts.prefix(3).map { account in
            CodexAccountUsageSnapshot(
                account: account,
                snapshot: self.snapshot(usedPercent: 50),
                error: nil,
                sourceLabel: "test")
        }
        let display = CodexAccountMenuDisplay(
            accounts: accounts,
            snapshots: Array(snapshots),
            activeVisibleAccountID: "account-2",
            layout: .stacked)

        let projected = StatusItemController.projectedCodexAccounts(display: display)

        XCTAssertEqual(projected.map(\ProviderAccountUsageSnapshot.id.opaqueID), [
            "account-1", "account-2", "account-3", "account-4",
        ])
        XCTAssertEqual(projected.map(\ProviderAccountUsageSnapshot.isActive), [false, true, false, false])
        XCTAssertEqual(projected[0].id.source, "codex-account")
        XCTAssertEqual(projected[0].displayLabel, "codex1@example.com")
        // account-4 has no snapshot: unavailable health surfaces as an error row.
        XCTAssertNil(projected[3].snapshot)
        XCTAssertNotNil(projected[3].error)
        XCTAssertNil(projected[0].error)
    }
}
