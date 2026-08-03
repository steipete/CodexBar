import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

/// The merged menu pre-builds sibling switcher tabs after opening so a tab
/// switch attaches cached, pre-laid-out rows (flicker fix follow-up).
@MainActor
final class StatusMenuSwitcherWarmupTests: XCTestCase {
    private func makeController() -> (controller: StatusItemController, menu: NSMenu) {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = testSettingsStore(
            suiteName: "StatusMenuSwitcherWarmupTests",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .claude || provider == .codex)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        return (controller, menu)
    }

    func test_warmupCachesSiblingSelections() {
        let (controller, menu) = self.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        guard menu.items.first?.view is ProviderSwitcherView else {
            return XCTFail("expected merged menu with provider switcher")
        }

        controller.warmMergedSwitcherSiblingContent(in: menu)

        let caches = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)] ?? [:]
        let enabledProviders = controller.store.enabledProvidersForDisplay()
        let cachedSelections = Set(caches.keys)
        let siblingProviders = enabledProviders.filter { cachedSelections.contains(.provider($0)) }
        // Every non-visible provider tab gets a cache entry; the visible tab is
        // cached separately by the populate path.
        XCTAssertGreaterThanOrEqual(siblingProviders.count, enabledProviders.count - 1)
        for (_, entry) in caches {
            XCTAssertFalse(entry.items.isEmpty)
        }
    }

    func test_stableHeightPaddingEqualizesProviderTabs() {
        let (controller, menu) = self.makeController()
        defer { controller.releaseStatusItemsForTesting() }

        controller.warmMergedSwitcherSiblingContent(in: menu)

        // Overview is excluded from equalization by design; compare provider tabs only.
        var totals: [CGFloat] = []
        let visibleSelection = controller.lastMergedMenuContentSelection
        if let visibleSelection, visibleSelection != .overview {
            let contentStartIndex = controller.providerSwitcherContentStartIndex(in: menu)
            let visible = controller.measureTab(items: Array(menu.items[contentStartIndex...]))
            totals.append(visible.contentHeight + (visible.spacer?.view?.frame.height ?? 0))
        }
        let caches = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)] ?? [:]
        for (selection, entry) in caches where selection != .overview {
            if selection == visibleSelection {
                continue
            }
            let tab = controller.measureTab(items: entry.items)
            XCTAssertNotNil(tab.spacer, "provider tab content must carry a stable-height spacer")
            totals.append(tab.contentHeight + (tab.spacer?.view?.frame.height ?? 0))
        }
        XCTAssertGreaterThan(totals.count, 1)
        let reference = totals[0]
        for total in totals {
            XCTAssertEqual(total, reference, accuracy: 0.5)
        }
    }

    func test_stableHeightPaddingPublishesSpacerHeightThroughIntrinsicSize() {
        let (controller, menu) = self.makeController()
        defer { controller.releaseStatusItemsForTesting() }

        controller.warmMergedSwitcherSiblingContent(in: menu)

        let caches = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)] ?? [:]
        let providerSpacers = caches.compactMap { selection, entry -> StableMenuHeightSpacerView? in
            guard selection != .overview else { return nil }
            return controller.measureTab(items: entry.items).spacer?.view as? StableMenuHeightSpacerView
        }
        XCTAssertFalse(providerSpacers.isEmpty)
        for spacer in providerSpacers {
            XCTAssertEqual(spacer.intrinsicContentSize.height, spacer.frame.height, accuracy: 0.5)
        }
    }

    func test_warmupSkipsSelectionsAlreadyCached() {
        let (controller, menu) = self.makeController()
        defer { controller.releaseStatusItemsForTesting() }

        controller.warmMergedSwitcherSiblingContent(in: menu)
        let firstItems = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)]?
            .mapValues { $0.items }

        controller.warmMergedSwitcherSiblingContent(in: menu)
        let secondItems = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)]?
            .mapValues { $0.items }

        // Re-warming with unchanged inputs must reuse the cached items, not rebuild them.
        XCTAssertEqual(firstItems?.count, secondItems?.count)
        for (selection, items) in firstItems ?? [:] {
            XCTAssertTrue(secondItems?[selection]?.elementsEqual(items, by: ===) == true)
        }
    }
}
