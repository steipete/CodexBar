import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `merged menu prewarms MiniMax content before first switch`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableProvidersForInstantOpenTesting([.codex, .minimax], settings: settings)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._setSnapshotForTesting(
            MiniMaxUsageSnapshot(
                planName: "Plus",
                availablePrompts: 100,
                currentPrompts: 25,
                remainingPrompts: 75,
                windowMinutes: 300,
                usedPercent: 25,
                resetsAt: nil,
                updatedAt: Date())
                .toUsageSnapshot(),
            provider: .minimax)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu
        controller.populateMenu(menu, provider: nil)
        controller.prewarmMiniMaxMergedMenuContent(in: menu)

        let cached = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)]?[.provider(.minimax)]
        #expect(cached?.items.contains { $0.representedObject as? String == "menuCard" } == true)
    }
}
