import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct StatusMenuOverviewScrollTests {
    private func makeController(suiteName: String) -> StatusItemController {
        _ = NSApplication.shared
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func makeOverviewMenu() -> NSMenu {
        let menu = NSMenu()
        for provider in ["claude", "codex"] {
            let item = NSMenuItem()
            item.representedObject = "\(StatusItemController.overviewRowIdentifierPrefix)\(provider)"
            item.isEnabled = true
            menu.addItem(item)
        }
        return menu
    }

    private func makeScrollEvent(deltaY: Double, precise: Bool) -> NSEvent? {
        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 1,
            wheel1: Int32(deltaY),
            wheel2: 0,
            wheel3: 0)
        else { return nil }
        return NSEvent(cgEvent: cgEvent)
    }

    @Test
    func `coarse wheel steps move highlight and respect direction`() throws {
        let controller = self.makeController(suiteName: "OverviewScroll-Direction")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let scrollUp = try #require(self.makeScrollEvent(deltaY: 1, precise: false))
        #expect(controller.handleOverviewScrollWheel(scrollUp, menu: menu))
        #expect(steps == [.up])

        steps = []
        let scrollDown = try #require(self.makeScrollEvent(deltaY: -1, precise: false))
        #expect(controller.handleOverviewScrollWheel(scrollDown, menu: menu))
        #expect(steps == [.down])
    }

    @Test
    func `navigation targets only overview rows`() {
        let controller = self.makeController(suiteName: "OverviewScroll-Targets")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let refresh = NSMenuItem(title: "Refresh", action: nil, keyEquivalent: "")
        refresh.isEnabled = true
        menu.addItem(refresh)
        let rows = Array(menu.items.prefix(2))

        #expect(controller.overviewScrollTargetItem(in: menu, step: .down) === rows[0])
        #expect(controller.overviewScrollTargetItem(in: menu, step: .up) === rows[1])

        controller.highlightedMenuItems[ObjectIdentifier(menu)] = rows[0]
        #expect(controller.overviewScrollTargetItem(in: menu, step: .down) === rows[1])
        #expect(controller.overviewScrollTargetItem(in: menu, step: .up) === rows[0])

        controller.highlightedMenuItems[ObjectIdentifier(menu)] = rows[1]
        #expect(controller.overviewScrollTargetItem(in: menu, step: .down) === rows[1])
        #expect(controller.overviewScrollTargetItem(in: menu, step: .up) === rows[0])

        controller.highlightedMenuItems[ObjectIdentifier(menu)] = refresh
        #expect(controller.overviewScrollTargetItem(in: menu, step: .down) === rows[0])
    }

    @Test
    func `precise trackpad scrolling is passed through to native menu scrolling`() throws {
        let controller = self.makeController(suiteName: "OverviewScroll-Precise")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let scroll = try #require(self.makeScrollEvent(deltaY: 30, precise: true))
        #expect(!controller.handleOverviewScrollWheel(scroll, menu: menu))
        #expect(steps.isEmpty)
    }

    @Test
    func `precise trackpad scrolling clears wheel accumulation`() throws {
        let controller = self.makeController(suiteName: "OverviewScroll-PreciseReset")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        controller.overviewScrollAccumulatedDelta = 0.5
        let scroll = try #require(self.makeScrollEvent(deltaY: 30, precise: true))
        #expect(!controller.handleOverviewScrollWheel(scroll, menu: menu))
        #expect(steps.isEmpty)
        #expect(controller.overviewScrollAccumulatedDelta == 0)
    }

    @Test
    func `coarse wheel lines step immediately`() throws {
        let controller = self.makeController(suiteName: "OverviewScroll-Wheel")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let wheelNotch = try #require(self.makeScrollEvent(deltaY: -1, precise: false))
        #expect(controller.handleOverviewScrollWheel(wheelNotch, menu: menu))
        #expect(steps == [.down])
    }

    @Test
    func `fast flick is capped per event`() throws {
        let controller = self.makeController(suiteName: "OverviewScroll-Cap")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let flick = try #require(self.makeScrollEvent(deltaY: 500, precise: false))
        #expect(controller.handleOverviewScrollWheel(flick, menu: menu))
        #expect(steps == [.up, .up, .up])
    }

    @Test
    func `precise flick is passed through instead of being capped into highlight jumps`() throws {
        let controller = self.makeController(suiteName: "OverviewScroll-PreciseFlick")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let flick = try #require(self.makeScrollEvent(deltaY: 500, precise: true))
        #expect(!controller.handleOverviewScrollWheel(flick, menu: menu))
        #expect(steps.isEmpty)
    }

    @Test
    func `open submenu suspends scroll navigation`() throws {
        let controller = self.makeController(suiteName: "OverviewScroll-Submenu")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let submenu = NSMenu()
        controller.openMenus[ObjectIdentifier(menu)] = menu
        controller.openMenus[ObjectIdentifier(submenu)] = submenu
        defer { controller.openMenus.removeAll() }

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let scroll = try #require(self.makeScrollEvent(deltaY: 1, precise: false))
        #expect(!controller.handleOverviewScrollWheel(scroll, menu: menu))
        #expect(steps.isEmpty)
    }

    @Test
    func `menus without overview rows ignore scrolling`() throws {
        let controller = self.makeController(suiteName: "OverviewScroll-NonOverview")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh", action: nil, keyEquivalent: ""))

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let scroll = try #require(self.makeScrollEvent(deltaY: 1, precise: false))
        #expect(!controller.handleOverviewScrollWheel(scroll, menu: menu))
        #expect(steps.isEmpty)
        #expect(!menu.items.isEmpty)
    }
}
