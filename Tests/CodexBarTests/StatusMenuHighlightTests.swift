import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
extension StatusMenuTests {
    final class HighlightProbeView: NSView, MenuCardHighlighting {
        private(set) var states: [Bool] = []

        func setHighlighted(_ highlighted: Bool) {
            self.states.append(highlighted)
        }
    }

    @Test
    func `menu highlight updates only previous and current custom rows`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let firstView = HighlightProbeView()
        let secondView = HighlightProbeView()
        let thirdView = HighlightProbeView()
        let first = NSMenuItem()
        first.view = firstView
        first.isEnabled = true
        let second = NSMenuItem()
        second.view = secondView
        second.isEnabled = true
        let third = NSMenuItem()
        third.view = thirdView
        third.isEnabled = true
        menu.addItem(first)
        menu.addItem(second)
        menu.addItem(third)

        controller.menu(menu, willHighlight: first)
        controller.menu(menu, willHighlight: second)
        controller.menu(menu, willHighlight: second)

        #expect(firstView.states == [true, false])
        #expect(secondView.states == [true])
        #expect(thirdView.states.isEmpty)
    }
}
