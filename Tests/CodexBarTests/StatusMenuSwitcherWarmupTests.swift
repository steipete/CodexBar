import AppKit
import CodexBarCore
import Foundation
import XCTest
@testable import CodexBar

/// The merged menu pre-builds sibling switcher tabs after opening so a tab
/// switch attaches cached, pre-laid-out rows (flicker fix follow-up).
@MainActor
final class StatusMenuSwitcherWarmupTests: XCTestCase {
    private func makeController(
        selectedProvider: UsageProvider = .codex,
        statusChecksEnabled: Bool = false) -> (controller: StatusItemController, menu: NSMenu)
    {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = testSettingsStore(
            suiteName: "StatusMenuSwitcherWarmupTests",
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = statusChecksEnabled
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = selectedProvider.instanceID
        settings.mergedMenuLastSelectedWasOverview = false
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: [.claude, .codex, .grok].contains(provider))
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
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

    func test_warmupDoesNotAddFlexibleProviderPadding() {
        let (controller, menu) = self.makeController()
        defer { controller.releaseStatusItemsForTesting() }

        controller.warmMergedSwitcherSiblingContent(in: menu)

        let caches = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)] ?? [:]
        let providerEntries = caches.filter { $0.key != .overview }
        XCTAssertFalse(providerEntries.isEmpty)
        for (_, entry) in providerEntries {
            XCTAssertFalse(entry.items.contains { item in
                item.title.isEmpty && item.view?.frame.height == 0
            }, "provider tabs must size to their content instead of carrying a flexible blank row")
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

    func test_warmedStatusSubmenusRemainScopedAcrossSwitchesAndReopen() throws {
        for initialProvider: UsageProvider in [.claude, .codex, .grok] {
            for provider: UsageProvider in [.grok, .codex, .claude] where provider != initialProvider {
                let (controller, menu) = self.makeController(
                    selectedProvider: initialProvider,
                    statusChecksEnabled: true)
                defer { controller.releaseStatusItemsForTesting() }
                controller.warmMergedSwitcherSiblingContent(in: menu)
                let caches = try XCTUnwrap(controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)])
                let cached = try XCTUnwrap(caches[.provider(provider.instanceID)])
                let cachedStatus = try XCTUnwrap(cached.items.first { $0.title == L("Status Page") })
                try self.assertStatusProvider(provider, item: cachedStatus, controller: controller)

                controller.preservingMergedSwitcherContentCachesDuringInvalidation {
                    controller.selectedMenuProvider = provider.instanceID
                }
                controller.updateMenuContentPreservingSwitcher(
                    menu,
                    context: StatusItemController.MenuUpdateContext(
                        provider: provider,
                        currentProvider: provider,
                        switcherSelection: .provider(provider.instanceID),
                        menuWidth: controller.menuCardWidth(
                            for: controller.store.enabledFirstPartyProvidersForDisplay(),
                            selectedProvider: provider,
                            descriptor: controller.makeMenuDescriptor(
                                provider: provider, includeContextualActions: true)),
                        codexAccountDisplay: nil,
                        tokenAccountDisplay: nil,
                        openAIContext: controller.openAIWebContext(currentProvider: provider, showAllAccounts: false),
                        descriptor: controller.makeMenuDescriptor(provider: provider, includeContextualActions: true)))
                let liveStatus = try XCTUnwrap(menu.items.first { $0.title == L("Status Page") })
                XCTAssertTrue(liveStatus.submenu === cachedStatus.submenu)
                try self.assertStatusProvider(provider, item: liveStatus, controller: controller)

                controller.menuDidClose(menu)
                controller.menuWillOpen(menu)
                try self.assertStatusProvider(
                    provider,
                    item: XCTUnwrap(menu.items.first { $0.title == L("Status Page") }),
                    controller: controller)
            }
        }
    }

    private func assertStatusProvider(
        _ provider: UsageProvider,
        item: NSMenuItem,
        controller: StatusItemController) throws
    {
        if provider == .grok {
            XCTAssertNil(item.submenu, "Grok has a website link, not another provider's components")
            XCTAssertEqual(item.action, #selector(StatusItemController.openStatusPage))
        } else {
            let submenu = try XCTUnwrap(item.submenu)
            if submenu.items.first?.identifier == nil {
                XCTAssertTrue(controller.hydrateHostedSubviewMenuIfNeeded(submenu))
            }
            let link = try XCTUnwrap(submenu.items.last)
            XCTAssertEqual(link.identifier?.rawValue, provider.rawValue)
            XCTAssertEqual(link.action, #selector(StatusItemController.openStatusPageFromMenuItem(_:)))
            XCTAssertTrue(link.target === controller)
        }
    }
}
