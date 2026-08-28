import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `reopening root menu resyncs readiness baseline so reverted store data still refreshes`() {
        // Regression for the readiness-signature optimization (#1351): the baseline is no longer
        // recomputed on every store change while menus are closed, so it must be re-anchored when a
        // root menu opens. Otherwise a closed-then-reopened menu built from new data, followed by an
        // open-menu change that reverts to the *previous* baseline value, would be treated as
        // "unchanged" and skip the rebuild, leaving the visible menu showing stale content.
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()

        // Root open anchors the baseline to snapshot A. Normalize via an explicit comparison so the
        // assertion below is independent of whatever the controller's initial baseline happened to be.
        controller.menuWillOpen(menu)
        _ = controller.didMenuAdjunctReadinessChange()
        controller.menuDidClose(menu)

        // Closed store change to B: the optimization intentionally skips recomputing the baseline here.
        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)

        // Reopening the root menu rebuilds from B and must re-anchor the baseline to B.
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)

        // Reverting to A (the value the *first* baseline held) must still register as a change.
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        #expect(controller.didMenuAdjunctReadinessChange())
    }

    @Test
    func `root open during in flight refresh preserves stale content and does not resync baseline`() {
        // When `refreshMenuForOpenIfNeeded` keeps existing menu content during an in-flight provider
        // refresh, the readiness baseline must not be re-anchored to live store data. Otherwise the
        // refresh-completion store mutation would compare equal against the prematurely resynced baseline
        // and skip the rebuild, leaving stale content visible (#1351).
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        let openedVersion = controller.menuVersions[key]

        store.isRefreshing = true
        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)

        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] == openedVersion)

        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        // Stale content was preserved: the menu is still behind the current content version.
        #expect(controller.menuNeedsRefresh(menu))

        store.isRefreshing = false
        // Refresh completion must still register as a readiness change so the open menu can rebuild.
        #expect(controller.didMenuAdjunctReadinessChange())
    }

    @Test
    func `native merged menu preparation during in flight refresh preserves stale menu freshness`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)
        if let claudeMetadata = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: true)
        }

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = try #require(controller.statusItem.menu)
        #expect(menu === controller.mergedMenu)
        controller.menuNeedsUpdate(menu)
        let key = ObjectIdentifier(menu)
        let preparedVersion = controller.menuVersions[key]

        store.isRefreshing = true
        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)
        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)

        controller.menuNeedsUpdate(menu)

        #expect(controller.menuVersions[key] == preparedVersion)
        #expect(controller.menuNeedsRefresh(menu))
    }

    @Test
    func `root open before deferred store observation rebuilds and refreshes matching observer`() {
        // Store observation invalidates menus from a deferred main-actor task. If a closed menu opens after
        // live data changes but before that task runs, it must rebuild from live data and let the matching
        // observer invalidate any coalesced non-readiness menu state without losing the readiness baseline.
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        controller.resyncMenuAdjunctReadinessBaseline()

        // Simulate the live store mutation being visible before the observation task has invalidated menus.
        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let key = ObjectIdentifier(menu)
        let versionAfterOpen = controller.menuContentVersion
        let menuVersionAfterOpen = controller.menuVersions[key]
        #expect(!controller.menuNeedsRefresh(menu))

        controller.handleObservedStoreMenuChange()

        #expect(controller.menuContentVersion != versionAfterOpen)
        #expect(controller.menuVersions[key] == menuVersionAfterOpen)
        #expect(controller.menuNeedsRefresh(menu))
        #expect(!controller.didMenuAdjunctReadinessChange())
    }

    @Test
    func `root open before deferred store observation during refresh leaves observer pending`() {
        // The pre-observer root-open repair must not bypass the in-flight refresh stale-content path.
        // While data is refreshing, the deferred observer should still invalidate the open menu and defer
        // parent rebuild instead of marking an intermediate snapshot fresh.
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        controller.resyncMenuAdjunctReadinessBaseline()

        store.isRefreshing = true
        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let versionAfterOpen = controller.menuContentVersion
        #expect(!controller.menuNeedsRefresh(menu))

        controller.handleObservedStoreMenuChange()

        #expect(controller.menuContentVersion != versionAfterOpen)
        #expect(controller.menuNeedsRefresh(menu))
        #expect(!controller.didMenuAdjunctReadinessChange())
    }

    @Test
    func `fresh newer-version root open during unrelated refresh still reanchors baseline`() {
        // An in-flight refresh elsewhere must not block re-anchoring when this menu was already rebuilt for
        // a newer menuContentVersion. Otherwise the stale baseline can still hide a later reverted update.
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        controller.resyncMenuAdjunctReadinessBaseline()

        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)
        controller.invalidateMenus()
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)

        store.isRefreshing = true
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        #expect(controller.didMenuAdjunctReadinessChange())
    }

    @Test
    func `equal-signature root open advances baseline version before next pre-observer change`() {
        // A root open whose signature still equals the baseline can nevertheless confirm that the visible
        // menu is fresh for a newer menuContentVersion. Record that version so a later live-data change before
        // its deferred observer does not look like already-rendered data.
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu(for: .codex)
        controller.providerMenus[.codex] = menu
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        controller.resyncMenuAdjunctReadinessBaseline()

        controller.invalidateMenus()
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)

        let versionBeforeChange = controller.menuContentVersion
        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuContentVersion != versionBeforeChange)
        #expect(!controller.menuNeedsRefresh(menu))
        #expect(!controller.didMenuAdjunctReadinessChange())
    }

    @Test
    func `newer-version root open rebuilds when rendered signature is older than live data`() {
        // A menu can be fresh for the current menuContentVersion while still having rendered an older
        // readiness signature than the current live store. Root open must rebuild in that pre-observer gap.
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))
        let snapshotC = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 333,
            sessionCostUSD: 3.33,
            last30DaysTokens: 3333,
            last30DaysCostUSD: 33.33,
            updatedAt: Date(timeIntervalSince1970: 300))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu(for: .codex)
        controller.providerMenus[.codex] = menu
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        controller.resyncMenuAdjunctReadinessBaseline()

        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)
        controller.invalidateMenus()
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        controller.menuWillOpen(menu)
        controller.menuDidClose(menu)

        let versionBeforeChange = controller.menuContentVersion
        store._setTokenSnapshotForTesting(snapshotC, provider: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuContentVersion != versionBeforeChange)
        #expect(!controller.menuNeedsRefresh(menu))
        #expect(!controller.didMenuAdjunctReadinessChange())
    }

    @Test
    func `equal-signature root open rebuilds when rendered signature reverted before observer`() {
        // A closed provider menu can be rebuilt from B while the readiness baseline remains A. If live data
        // reverts to A before the deferred observer runs, root open must still repair the B-rendered menu.
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableOnlyCodexForReadinessBaseline(settings)

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let menu = controller.makeMenu(for: .codex)
        controller.providerMenus[.codex] = menu
        let key = ObjectIdentifier(menu)
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        controller.resyncMenuAdjunctReadinessBaseline()

        store._setTokenSnapshotForTesting(snapshotB, provider: .codex)
        controller.invalidateMenus()
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)

        let renderedBSignature = controller.menuReadinessSignatures[key]
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let versionBeforeOpen = controller.menuContentVersion
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        #expect(controller.menuContentVersion != versionBeforeOpen)
        #expect(controller.menuReadinessSignatures[key] != renderedBSignature)
        #expect(controller.menuReadinessSignatures[key] == controller.menuAdjunctReadinessSignature())
        #expect(!controller.didMenuAdjunctReadinessChange())
    }

    @Test
    func `provider root open before deferred store observation leaves sibling provider menu stale`() {
        // The readiness signature is global across enabled providers. In split-icon mode, opening one
        // provider's menu must not consume a pending global observation while leaving sibling menus marked
        // fresh even though their provider data changed.
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.costUsageEnabled = true
        self.enableProvidersForReadinessBaseline(settings, providers: [.claude, .codex])

        let snapshotA = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 111,
            sessionCostUSD: 1.11,
            last30DaysTokens: 1111,
            last30DaysCostUSD: 11.11,
            updatedAt: Date(timeIntervalSince1970: 100))
        let snapshotB = self.makeReadinessBaselineTokenSnapshot(
            sessionTokens: 222,
            sessionCostUSD: 2.22,
            last30DaysTokens: 2222,
            last30DaysCostUSD: 22.22,
            updatedAt: Date(timeIntervalSince1970: 200))

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setTokenSnapshotForTesting(snapshotA, provider: .claude)
        store._setTokenSnapshotForTesting(snapshotA, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true

        let claudeMenu = controller.makeMenu(for: .claude)
        controller.populateMenu(claudeMenu, provider: .claude)
        controller.markMenuFresh(claudeMenu)
        let codexMenu = controller.makeMenu(for: .codex)
        controller.populateMenu(codexMenu, provider: .codex)
        controller.markMenuFresh(codexMenu)
        controller.resyncMenuAdjunctReadinessBaseline()

        store._setTokenSnapshotForTesting(snapshotB, provider: .claude)
        controller.menuWillOpen(codexMenu)
        defer { controller.menuDidClose(codexMenu) }

        let versionAfterOpen = controller.menuContentVersion
        #expect(!controller.menuNeedsRefresh(codexMenu))
        #expect(controller.menuNeedsRefresh(claudeMenu))

        controller.handleObservedStoreMenuChange()

        #expect(controller.menuContentVersion != versionAfterOpen)
        #expect(controller.menuNeedsRefresh(codexMenu))
        #expect(controller.menuNeedsRefresh(claudeMenu))
        #expect(!controller.didMenuAdjunctReadinessChange())
    }

    private func enableOnlyCodexForReadinessBaseline(_ settings: SettingsStore) {
        self.enableProvidersForReadinessBaseline(settings, providers: [.codex])
    }

    private func enableProvidersForReadinessBaseline(_ settings: SettingsStore, providers: Set<UsageProvider>) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
    }

    private func makeReadinessBaselineTokenSnapshot(
        sessionTokens: Int,
        sessionCostUSD: Double,
        last30DaysTokens: Int,
        last30DaysCostUSD: Double,
        updatedAt: Date) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: sessionTokens,
            sessionCostUSD: sessionCostUSD,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-24",
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: sessionTokens,
                    costUSD: last30DaysCostUSD,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: updatedAt)
    }
}
