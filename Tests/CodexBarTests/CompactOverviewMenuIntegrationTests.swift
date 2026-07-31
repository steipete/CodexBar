import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CompactOverviewMenuIntegrationTests {
    @Test
    func `compact overview assembles variable lane rows in provider order`() throws {
        let fixture = self.makeFixture(compact: true)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let cursorModel = try #require(fixture.controller.menuCardModel(for: .cursor))
        let claudeModel = try #require(fixture.controller.menuCardModel(for: .claude))
        #expect(CompactOverviewProjection(model: cursorModel).lanes.count == 1)
        #expect(CompactOverviewProjection(model: claudeModel).lanes.count == 3)

        let menu = self.renderOverviewMenu(fixture.controller)
        let rows = Self.overviewRows(in: menu)
        #expect(rows.map { $0.representedObject as? String } == [
            "overviewRow-cursor",
            "overviewRow-claude",
        ])

        let cursorIndex = try #require(menu.items.firstIndex(of: rows[0]))
        let claudeIndex = try #require(menu.items.firstIndex(of: rows[1]))
        #expect(claudeIndex == cursorIndex + 2)
        #expect(menu.items[cursorIndex + 1].isSeparatorItem)

        let cursorRow = rows[0]
        #expect(cursorRow.submenu == nil)
        #expect(try NSStringFromSelector(#require(cursorRow.action)) == "selectOverviewProvider:")
        #expect((cursorRow.target as AnyObject?) === fixture.controller)
        #expect(cursorRow.view?.accessibilityLabel() == cursorModel.providerName)
        #expect(cursorRow.view?.accessibilityHelp() == L("Show details"))

        let claudeRow = rows[1]
        let claudeSubmenu = try #require(claudeRow.submenu)
        #expect(claudeSubmenu.items.first?.representedObject as? String == StatusItemController.usageHistoryChartID)
        #expect(claudeSubmenu.items.first?.toolTip == UsageProvider.claude.rawValue)
        #expect(try NSStringFromSelector(#require(claudeRow.action)) == "menuCardNoOp:")
        #expect((claudeRow.target as AnyObject?) === fixture.controller)
        #expect(claudeRow.view?.accessibilityLabel() == claudeModel.providerName)
        #expect(claudeRow.view?.accessibilityHelp() == L("Show details"))

        let cursorHeight = try #require(cursorRow.view?.frame.height)
        let claudeHeight = try #require(claudeRow.view?.frame.height)
        #expect(cursorHeight > 0)
        #expect(cursorHeight < claudeHeight)

        let claudeView = try #require(
            claudeRow.view as? GPUSelectionHostingView<OverviewMenuCardRowView>)
        #expect(claudeView._test_simulateRuntimeClick())
        #expect(!fixture.settings.mergedMenuLastSelectedWasOverview)
        #expect(fixture.settings.selectedMenuProvider == .claude)
    }

    @Test
    func `compact and detailed rows use distinct cache geometry`() throws {
        let compact = self.makeFixture(compact: true)
        let detailed = self.makeFixture(compact: false)
        defer {
            compact.controller.releaseStatusItemsForTesting()
            detailed.controller.releaseStatusItemsForTesting()
        }

        let compactMenu = self.renderOverviewMenu(compact.controller)
        let detailedMenu = self.renderOverviewMenu(detailed.controller)
        let compactRows = Self.rowsByProvider(in: compactMenu)
        let detailedRows = Self.rowsByProvider(in: detailedMenu)
        let compactKeys = Self.cacheKeys(in: compact.controller, section: "overviewCompact")
        let detailedKeys = Self.cacheKeys(in: detailed.controller, section: "overviewDetailed")

        let expectedScopes = Set([UsageProvider.cursor.rawValue, UsageProvider.claude.rawValue])
        #expect(Set(compactKeys.map(\.scope)) == expectedScopes)
        #expect(Set(detailedKeys.map(\.scope)) == expectedScopes)

        for provider in [UsageProvider.cursor, .claude] {
            let compactRow = try #require(compactRows[provider])
            let detailedRow = try #require(detailedRows[provider])
            let compactKey = try #require(compactKeys.first { $0.scope == provider.rawValue })
            let detailedKey = try #require(detailedKeys.first { $0.scope == provider.rawValue })
            let compactHeight = try #require(compactRow.view?.frame.height)
            let detailedHeight = try #require(detailedRow.view?.frame.height)

            #expect(compactKey.id == detailedKey.id)
            #expect(compactKey.fingerprint != detailedKey.fingerprint)
            #expect(compactHeight < detailedHeight)
        }

        let initialCursorFingerprint = try #require(
            compactKeys.first { $0.scope == UsageProvider.cursor.rawValue }?.fingerprint)
        compact.store._setSnapshotForTesting(
            Self.claudeSnapshot(
                primaryPercent: 10,
                secondaryPercent: 20,
                extraPercent: 30,
                extraTitle: "A substantially longer peer quota lane title"),
            provider: .claude)

        _ = self.renderOverviewMenu(compact.controller)
        let cursorCompactFingerprints = Set(Self.cacheKeys(
            in: compact.controller,
            section: "overviewCompact")
            .filter { $0.scope == UsageProvider.cursor.rawValue }
            .map(\.fingerprint))

        #expect(cursorCompactFingerprints.contains(initialCursorFingerprint))
        #expect(cursorCompactFingerprints.count == 2)
    }

    @Test
    func `structural signature ignores values and detects lanes and peer titles`() {
        let fixture = self.makeFixture(compact: true)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let initial = fixture.controller.compactOverviewStructuralSignature()

        fixture.store._setSnapshotForTesting(
            Self.cursorSnapshot(primaryPercent: 81),
            provider: .cursor)
        fixture.store._setSnapshotForTesting(
            Self.claudeSnapshot(
                primaryPercent: 82,
                secondaryPercent: 83,
                extraPercent: 84,
                extraTitle: "Peer"),
            provider: .claude)
        let valueOnly = fixture.controller.compactOverviewStructuralSignature()
        #expect(valueOnly == initial)

        fixture.store._setSnapshotForTesting(
            Self.claudeSnapshot(
                primaryPercent: 82,
                secondaryPercent: 83,
                extraPercent: 84,
                extraTitle: "Peer",
                additionalExtraTitle: "Fourth lane"),
            provider: .claude)
        let laneAdded = fixture.controller.compactOverviewStructuralSignature()
        #expect(laneAdded != valueOnly)

        fixture.store._setSnapshotForTesting(
            Self.claudeSnapshot(
                primaryPercent: 82,
                secondaryPercent: 83,
                extraPercent: 84,
                extraTitle: "Renamed peer",
                additionalExtraTitle: "Fourth lane"),
            provider: .claude)
        let peerTitleChanged = fixture.controller.compactOverviewStructuralSignature()
        #expect(peerTitleChanged != laneAdded)
    }

    private struct Fixture {
        let settings: SettingsStore
        let store: UsageStore
        let controller: StatusItemController
    }

    private func makeFixture(compact: Bool) -> Fixture {
        let suite = "CompactOverviewMenuIntegrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.switcherShowsIcons = false
        settings.mergedMenuLastSelectedWasOverview = true
        settings.mergedOverviewUsesCompactLayout = compact
        settings.historicalTrackingEnabled = false
        settings.showOptionalCreditsAndExtraUsage = true
        settings.providerStorageFootprintsEnabled = false
        settings.costUsageEnabled = false
        settings.setProviderOrder([.cursor, .claude])
        self.enableOnly([.cursor, .claude], settings: settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(Self.cursorSnapshot(primaryPercent: 10), provider: .cursor)
        store._setSnapshotForTesting(
            Self.claudeSnapshot(
                primaryPercent: 10,
                secondaryPercent: 20,
                extraPercent: 30,
                extraTitle: "Peer"),
            provider: .claude)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            menuCardRenderingEnabled: true,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
        return Fixture(settings: settings, store: store, controller: controller)
    }

    private func enableOnly(_ enabled: Set<UsageProvider>, settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: enabled.contains(provider))
        }
    }

    private func renderOverviewMenu(_ controller: StatusItemController) -> NSMenu {
        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: nil)
        return menu
    }

    private static func overviewRows(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter {
            ($0.representedObject as? String)?.hasPrefix(StatusItemController.overviewRowIdentifierPrefix) == true
        }
    }

    private static func rowsByProvider(in menu: NSMenu) -> [UsageProvider: NSMenuItem] {
        Dictionary(uniqueKeysWithValues: self.overviewRows(in: menu).compactMap { item in
            guard let id = item.representedObject as? String else { return nil }
            let rawValue = String(id.dropFirst(StatusItemController.overviewRowIdentifierPrefix.count))
            guard let provider = UsageProvider(rawValue: rawValue) else { return nil }
            return (provider, item)
        })
    }

    private static func cacheKeys(
        in controller: StatusItemController,
        section: String) -> [StatusItemController.MenuCardHeightCacheKey]
    {
        controller.menuCardHeightCache.keys.filter { key in
            key.id.hasPrefix(StatusItemController.overviewRowIdentifierPrefix) &&
                key.fingerprint.contains(section)
        }
    }

    private static func cursorSnapshot(primaryPercent: Double) -> UsageSnapshot {
        UsageSnapshot(
            primary: self.window(percent: primaryPercent, minutes: 30 * 24 * 60),
            secondary: nil,
            updatedAt: self.snapshotDate)
    }

    private static func claudeSnapshot(
        primaryPercent: Double,
        secondaryPercent: Double,
        extraPercent: Double,
        extraTitle: String,
        additionalExtraTitle: String? = nil) -> UsageSnapshot
    {
        var extras = [NamedRateWindow(
            id: "peer-quota",
            title: extraTitle,
            window: Self.window(percent: extraPercent, minutes: 24 * 60))]
        if let additionalExtraTitle {
            extras.append(NamedRateWindow(
                id: "additional-quota",
                title: additionalExtraTitle,
                window: Self.window(percent: 45, minutes: 48 * 60)))
        }
        return UsageSnapshot(
            primary: Self.window(percent: primaryPercent, minutes: 5 * 60),
            secondary: Self.window(percent: secondaryPercent, minutes: 7 * 24 * 60),
            extraRateWindows: extras,
            updatedAt: Self.snapshotDate)
    }

    private static func window(percent: Double, minutes: Int) -> RateWindow {
        RateWindow(
            usedPercent: percent,
            windowMinutes: minutes,
            resetsAt: self.snapshotDate.addingTimeInterval(TimeInterval(minutes * 60)),
            resetDescription: nil)
    }

    private static let snapshotDate = Date(timeIntervalSince1970: 1_900_000_000)
}
