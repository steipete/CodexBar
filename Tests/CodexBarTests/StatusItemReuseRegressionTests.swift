import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemReuseRegressionTests {
    @Test
    func `usage update during vending reuses the provider status item`() throws {
        let suite = "StatusItemReuseRegressionTests-\(UUID().uuidString)"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.providerDetectionCompleted = true
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .percent

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let initialItem = try #require(controller.statusItems[.codex])
        controller.statusItems.removeValue(forKey: .codex)
        controller.statusBar.removeStatusItem(initialItem)

        var itemSeenByUpdate: NSStatusItem?
        let vendedItem = controller._test_vendStatusItem(for: .codex) { _ in
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 23,
                        windowMinutes: 300,
                        resetsAt: nil,
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                provider: .codex)
            controller.updateIcons()
            itemSeenByUpdate = controller.statusItems[.codex]
        }
        defer {
            if let itemSeenByUpdate, itemSeenByUpdate !== vendedItem {
                controller.statusBar.removeStatusItem(itemSeenByUpdate)
            }
        }

        let updatedItem = try #require(itemSeenByUpdate)
        #expect(updatedItem === vendedItem)
        #expect(controller.statusItems.count == 1)
        #expect(controller.statusItems[.codex] === vendedItem)
        #expect(vendedItem.button?.title.contains("77%") == true)
    }
}
