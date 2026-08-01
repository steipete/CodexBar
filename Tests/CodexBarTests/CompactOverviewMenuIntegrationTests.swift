import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct CompactOverviewMenuIntegrationTests {
    @Test
    func `all reduced overviews assemble variable lane rows with provider actions`() throws {
        try self.assertReducedOverview(layout: .compact)
        try self.assertReducedOverview(layout: .providerBars)
        try self.assertReducedOverview(layout: .barsOnly)
    }

    private func assertReducedOverview(layout: MergedOverviewLayout) throws {
        let fixture = self.makeFixture(layout: layout)
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
        let barsOnlySpacers = Self.barsOnlySpacers(in: menu)
        if layout == .barsOnly {
            #expect(claudeIndex == cursorIndex + 1)
            #expect(barsOnlySpacers.count == 2)
            #expect(menu.items.firstIndex(of: barsOnlySpacers[0]) == cursorIndex - 1)
            #expect(menu.items.firstIndex(of: barsOnlySpacers[1]) == claudeIndex + 1)
            for spacer in barsOnlySpacers {
                #expect(!spacer.isEnabled)
                #expect(spacer.action == nil)
                #expect(spacer.view?.frame.height == CompactOverviewLayout.barsOnlySectionSpacerHeight)
                #expect(spacer.view?.isAccessibilityElement() == false)
            }
        } else {
            #expect(barsOnlySpacers.isEmpty)
            #expect(claudeIndex == cursorIndex + 2)
            #expect(menu.items[cursorIndex + 1].isSeparatorItem)
        }

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

        let claudeView = try #require(claudeRow.view as? MenuRowContainerView)
        #expect(claudeView.usesGPUSelectionForTesting)
        #expect(claudeView.showsSubmenuIndicatorForTesting == (layout != .barsOnly))
        #expect(claudeView._test_simulateRuntimeClick())
        #expect(!fixture.settings.mergedMenuLastSelectedWasOverview)
        #expect(fixture.settings.selectedMenuProvider == .claude)
    }

    @Test
    func `all overview layouts use distinct cache geometry and ordered heights`() throws {
        let barsOnly = self.makeFixture(layout: .barsOnly)
        let providerBars = self.makeFixture(layout: .providerBars)
        let compact = self.makeFixture(layout: .compact)
        let detailed = self.makeFixture(layout: .detailed)
        defer {
            barsOnly.controller.releaseStatusItemsForTesting()
            providerBars.controller.releaseStatusItemsForTesting()
            compact.controller.releaseStatusItemsForTesting()
            detailed.controller.releaseStatusItemsForTesting()
        }

        let barsOnlyMenu = self.renderOverviewMenu(barsOnly.controller)
        let providerBarsMenu = self.renderOverviewMenu(providerBars.controller)
        let compactMenu = self.renderOverviewMenu(compact.controller)
        let detailedMenu = self.renderOverviewMenu(detailed.controller)
        let barsOnlyRows = Self.rowsByProvider(in: barsOnlyMenu)
        let providerBarsRows = Self.rowsByProvider(in: providerBarsMenu)
        let compactRows = Self.rowsByProvider(in: compactMenu)
        let detailedRows = Self.rowsByProvider(in: detailedMenu)
        let barsOnlyKeys = Self.cacheKeys(in: barsOnly.controller, section: "overviewBarsOnly")
        let providerBarsKeys = Self.cacheKeys(in: providerBars.controller, section: "overviewProviderBars")
        let compactKeys = Self.cacheKeys(in: compact.controller, section: "overviewCompact")
        let detailedKeys = Self.cacheKeys(in: detailed.controller, section: "overviewDetailed")

        let expectedScopes = Set([UsageProvider.cursor.rawValue, UsageProvider.claude.rawValue])
        #expect(Set(barsOnlyKeys.map(\.scope)) == expectedScopes)
        #expect(Set(providerBarsKeys.map(\.scope)) == expectedScopes)
        #expect(Set(compactKeys.map(\.scope)) == expectedScopes)
        #expect(Set(detailedKeys.map(\.scope)) == expectedScopes)

        for provider in [UsageProvider.cursor, .claude] {
            let barsOnlyRow = try #require(barsOnlyRows[provider])
            let providerBarsRow = try #require(providerBarsRows[provider])
            let compactRow = try #require(compactRows[provider])
            let detailedRow = try #require(detailedRows[provider])
            let barsOnlyKey = try #require(barsOnlyKeys.first { $0.scope == provider.rawValue })
            let providerBarsKey = try #require(providerBarsKeys.first { $0.scope == provider.rawValue })
            let compactKey = try #require(compactKeys.first { $0.scope == provider.rawValue })
            let detailedKey = try #require(detailedKeys.first { $0.scope == provider.rawValue })
            let barsOnlyHeight = try #require(barsOnlyRow.view?.frame.height)
            let providerBarsHeight = try #require(providerBarsRow.view?.frame.height)
            let compactHeight = try #require(compactRow.view?.frame.height)
            let detailedHeight = try #require(detailedRow.view?.frame.height)

            #expect(barsOnlyKey.id == providerBarsKey.id)
            #expect(providerBarsKey.id == compactKey.id)
            #expect(compactKey.id == detailedKey.id)
            #expect(barsOnlyKey.fingerprint != providerBarsKey.fingerprint)
            #expect(providerBarsKey.fingerprint != compactKey.fingerprint)
            #expect(compactKey.fingerprint != detailedKey.fingerprint)
            #expect(barsOnlyHeight < providerBarsHeight)
            #expect(providerBarsHeight < compactHeight)
            #expect(compactHeight < detailedHeight)
            let expectedBarsOnlyHeight: CGFloat = provider == .cursor ? 24 : 60
            let expectedProviderBarsHeight: CGFloat = provider == .cursor ? 57 : 93
            #expect(abs(barsOnlyHeight - expectedBarsOnlyHeight) <= 1)
            #expect(abs(providerBarsHeight - expectedProviderBarsHeight) <= 1)
        }

        let initialCursorFingerprint = try #require(
            compactKeys.first { $0.scope == UsageProvider.cursor.rawValue }?.fingerprint)
        compact.store._setSnapshotForTesting(
            Self.cursorSnapshot(primaryPercent: 81),
            provider: .cursor)

        _ = self.renderOverviewMenu(compact.controller)
        let cursorValueOnlyFingerprints = Set(Self.cacheKeys(
            in: compact.controller,
            section: "overviewCompact")
            .filter { $0.scope == UsageProvider.cursor.rawValue }
            .map(\.fingerprint))

        #expect(cursorValueOnlyFingerprints == [initialCursorFingerprint])

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
        #expect(cursorCompactFingerprints.count == 1)
    }

    @Test
    func `open overview rebuilds between provider bars and bars only`() async throws {
        let fixture = self.makeFixture(layout: .providerBars, menuRefreshEnabled: true)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        let menu = self.renderOverviewMenu(fixture.controller)
        let menuKey = ObjectIdentifier(menu)
        fixture.controller.mergedMenu = menu
        fixture.controller.openMenus[menuKey] = menu
        fixture.controller.markMenuFresh(menu)
        defer {
            fixture.controller.openMenus[menuKey] = nil
            fixture.controller._test_openMenuRebuildObserver = nil
        }

        func assertTopology(_ layout: MergedOverviewLayout) throws -> CGFloat {
            let rows = Self.overviewRows(in: menu)
            #expect(rows.map { $0.representedObject as? String } == [
                "overviewRow-cursor",
                "overviewRow-claude",
            ])
            let cursorIndex = try #require(menu.items.firstIndex(of: rows[0]))
            let claudeIndex = try #require(menu.items.firstIndex(of: rows[1]))
            if layout == .barsOnly {
                #expect(claudeIndex == cursorIndex + 1)
                #expect(Self.barsOnlySpacers(in: menu).count == 2)
            } else {
                #expect(Self.barsOnlySpacers(in: menu).isEmpty)
                #expect(claudeIndex == cursorIndex + 2)
                #expect(menu.items[cursorIndex + 1].isSeparatorItem)
            }
            let claudeView = try #require(rows[1].view as? MenuRowContainerView)
            #expect(claudeView.usesGPUSelectionForTesting)
            #expect(claudeView.showsSubmenuIndicatorForTesting == (layout != .barsOnly))
            return try #require(rows[1].view?.frame.height)
        }

        let initialProviderBarsHeight = try assertTopology(.providerBars)
        var rebuildCount = 0
        fixture.controller._test_openMenuRebuildObserver = { _ in rebuildCount += 1 }

        fixture.settings.mergedOverviewLayout = .barsOnly
        await Self.waitForRebuildCount(1, rebuildCount: { rebuildCount })
        let barsOnlyHeight = try assertTopology(.barsOnly)
        #expect(barsOnlyHeight < initialProviderBarsHeight)
        #expect(!Self.cacheKeys(in: fixture.controller, section: "overviewBarsOnly").isEmpty)

        fixture.settings.mergedOverviewLayout = .providerBars
        await Self.waitForRebuildCount(2, rebuildCount: { rebuildCount })
        let rebuiltProviderBarsHeight = try assertTopology(.providerBars)
        #expect(rebuiltProviderBarsHeight == initialProviderBarsHeight)
        #expect(!Self.cacheKeys(in: fixture.controller, section: "overviewProviderBars").isEmpty)
    }

    @Test
    func `bars only outer spacers keep row heights and cache keys position independent`() throws {
        let fixture = self.makeFixture(
            layout: .barsOnly,
            providerOrder: [.cursor, .codex, .claude],
            usesOneLaneSnapshots: true)
        defer { fixture.controller.releaseStatusItemsForTesting() }

        func rowHeight(_ provider: UsageProvider, in menu: NSMenu) throws -> CGFloat {
            let row = try #require(Self.rowsByProvider(in: menu)[provider])
            return try #require(row.view?.frame.height)
        }

        func fingerprints(_ provider: UsageProvider) -> Set<String> {
            Set(Self.cacheKeys(in: fixture.controller, section: "overviewBarsOnly")
                .filter { $0.scope == provider.rawValue }
                .map(\.fingerprint))
        }

        let threeProviderMenu = self.renderOverviewMenu(fixture.controller)
        let cursorFirstHeight = try rowHeight(.cursor, in: threeProviderMenu)
        let codexInteriorHeight = try rowHeight(.codex, in: threeProviderMenu)
        let claudeLastHeight = try rowHeight(.claude, in: threeProviderMenu)
        #expect(abs(cursorFirstHeight - 24) <= 1)
        #expect(abs(codexInteriorHeight - 24) <= 1)
        #expect(abs(claudeLastHeight - 24) <= 1)
        #expect(Self.barsOnlySpacers(in: threeProviderMenu).count == 2)
        let interiorFingerprints = fingerprints(.codex)
        #expect(interiorFingerprints.count == 1)

        let activeProviders: [UsageProvider] = [.cursor, .codex, .claude]
        fixture.settings.setMergedOverviewProviderSelection(
            provider: .cursor,
            isSelected: false,
            activeProviders: activeProviders)
        let twoProviderMenu = self.renderOverviewMenu(fixture.controller)
        let codexFirstHeight = try rowHeight(.codex, in: twoProviderMenu)
        #expect(abs(codexFirstHeight - 24) <= 1)
        #expect(Self.barsOnlySpacers(in: twoProviderMenu).count == 2)
        let firstFingerprints = fingerprints(.codex)
        #expect(firstFingerprints == interiorFingerprints)

        fixture.settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)
        let oneProviderMenu = self.renderOverviewMenu(fixture.controller)
        let codexOnlyHeight = try rowHeight(.codex, in: oneProviderMenu)
        #expect(abs(codexOnlyHeight - 24) <= 1)
        #expect(Self.barsOnlySpacers(in: oneProviderMenu).count == 2)
        let soleFingerprints = fingerprints(.codex)
        #expect(soleFingerprints == firstFingerprints)
    }

    @Test
    func `structural signature distinguishes modes ignores values and detects lane shape`() {
        let fixture = self.makeFixture(layout: .compact)
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

        fixture.settings.mergedOverviewLayout = .providerBars
        let providerBars = fixture.controller.compactOverviewStructuralSignature()
        #expect(providerBars != peerTitleChanged)
        #expect(providerBars.contains("layout=providerBars"))

        fixture.settings.mergedOverviewLayout = .barsOnly
        let barsOnly = fixture.controller.compactOverviewStructuralSignature()
        #expect(barsOnly != providerBars)
        #expect(barsOnly.contains("layout=barsOnly"))
    }

    private struct Fixture {
        let settings: SettingsStore
        let store: UsageStore
        let controller: StatusItemController
    }

    private func makeFixture(
        layout: MergedOverviewLayout,
        providerOrder: [UsageProvider] = [.cursor, .claude],
        usesOneLaneSnapshots: Bool = false,
        menuRefreshEnabled: Bool = false) -> Fixture
    {
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
        settings.mergedOverviewLayout = layout
        settings.historicalTrackingEnabled = false
        settings.showOptionalCreditsAndExtraUsage = true
        settings.providerStorageFootprintsEnabled = false
        settings.costUsageEnabled = false
        settings.setProviderOrder(providerOrder)
        settings.mergedOverviewSelectedProviders = providerOrder
        self.enableOnly(Set(providerOrder), settings: settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        if usesOneLaneSnapshots {
            for (index, provider) in providerOrder.enumerated() {
                store._setSnapshotForTesting(
                    Self.cursorSnapshot(primaryPercent: Double(10 + index)),
                    provider: provider)
            }
        } else {
            store._setSnapshotForTesting(Self.cursorSnapshot(primaryPercent: 10), provider: .cursor)
            store._setSnapshotForTesting(
                Self.claudeSnapshot(
                    primaryPercent: 10,
                    secondaryPercent: 20,
                    extraPercent: 30,
                    extraTitle: "Peer"),
                provider: .claude)
        }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            menuCardRenderingEnabled: true,
            menuRefreshEnabled: menuRefreshEnabled,
            observeProviderConfigNotifications: false)
        return Fixture(settings: settings, store: store, controller: controller)
    }

    private static func waitForRebuildCount(
        _ expected: Int,
        rebuildCount: () -> Int) async
    {
        for _ in 0..<100 where rebuildCount() < expected {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(rebuildCount() == expected)
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

    private static func barsOnlySpacers(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter {
            ($0.representedObject as? String)?
                .hasPrefix(StatusItemController.overviewBarsOnlySpacerIdentifierPrefix) == true
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
