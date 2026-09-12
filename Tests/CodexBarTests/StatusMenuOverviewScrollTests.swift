import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private final class OverviewScrollEvent: NSEvent {
    private let delta: CGFloat
    private let precise: Bool

    init(deltaY: CGFloat, precise: Bool) {
        self.delta = deltaY
        self.precise = precise
        super.init()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var type: NSEvent.EventType {
        .scrollWheel
    }

    override var scrollingDeltaY: CGFloat {
        self.delta
    }

    override var hasPreciseScrollingDeltas: Bool {
        self.precise
    }

    override var momentumPhase: NSEvent.Phase {
        []
    }
}

@MainActor
struct StatusMenuOverviewScrollTests {
    private func makeController(suiteName: String) throws -> StatusItemController {
        let suite = "\(suiteName)-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        // Scroll navigation needs neither saved app-group data nor legacy account migration.
        defaults.set(AppGroupSupport.migrationVersion, forKey: AppGroupSupport.migrationVersionKey)
        defaults.set(true, forKey: "codexbar.legacySecretsMigrationCompleted")
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0.instanceID, enabled: false)
        }))
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            performInitialProviderDetection: false)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        let fetcher = UsageFetcher(environment: [:])
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system,
            menuCardRenderingEnabled: false,
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
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

    private func makeScrollEvent(deltaY: CGFloat, precise: Bool) -> NSEvent {
        // CGEvent line-scroll conversion can yield zero deltas depending on host state.
        // Supply the handler's NSEvent inputs directly without posting an event.
        OverviewScrollEvent(deltaY: deltaY, precise: precise)
    }

    @Test(arguments: [CGFloat(-1), 0, 0.5, 1, 30, 500], [false, true])
    func `synthetic scroll events preserve handler inputs`(deltaY: CGFloat, precise: Bool) {
        let event = self.makeScrollEvent(deltaY: deltaY, precise: precise)
        #expect(event.type == .scrollWheel)
        #expect(event.scrollingDeltaY == deltaY)
        #expect(event.hasPreciseScrollingDeltas == precise)
        #expect(event.momentumPhase.isEmpty)
    }

    @Test
    func `coarse wheel steps move highlight and respect direction`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-Direction")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let scrollUp = self.makeScrollEvent(deltaY: 1, precise: false)
        let handledUp = controller.handleOverviewScrollWheel(scrollUp, menu: menu)
        #expect(handledUp)
        #expect(steps == [.up])

        steps = []
        let scrollDown = self.makeScrollEvent(deltaY: -1, precise: false)
        let handledDown = controller.handleOverviewScrollWheel(scrollDown, menu: menu)
        #expect(handledDown)
        #expect(steps == [.down])
    }

    @Test
    func `navigation targets only overview rows`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-Targets")
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
        let controller = try self.makeController(suiteName: "OverviewScroll-Precise")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let scroll = self.makeScrollEvent(deltaY: 30, precise: true)
        let handled = controller.handleOverviewScrollWheel(scroll, menu: menu)
        #expect(!handled)
        #expect(steps.isEmpty)
    }

    @Test
    func `precise trackpad scrolling clears wheel accumulation`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-PreciseReset")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        controller.overviewScrollAccumulatedDelta = 0.5
        let scroll = self.makeScrollEvent(deltaY: 30, precise: true)
        let handled = controller.handleOverviewScrollWheel(scroll, menu: menu)
        #expect(!handled)
        #expect(steps.isEmpty)
        #expect(controller.overviewScrollAccumulatedDelta == 0)
    }

    @Test
    func `coarse wheel lines step immediately`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-Wheel")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let wheelNotch = self.makeScrollEvent(deltaY: -1, precise: false)
        let handled = controller.handleOverviewScrollWheel(wheelNotch, menu: menu)
        #expect(handled)
        #expect(steps == [.down])
    }

    @Test
    func `fast flick is capped per event`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-Cap")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let flick = self.makeScrollEvent(deltaY: 500, precise: false)
        let handled = controller.handleOverviewScrollWheel(flick, menu: menu)
        #expect(handled)
        #expect(steps == [.up, .up, .up])
    }

    @Test
    func `precise flick is passed through instead of being capped into highlight jumps`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-PreciseFlick")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let flick = self.makeScrollEvent(deltaY: 500, precise: true)
        let handled = controller.handleOverviewScrollWheel(flick, menu: menu)
        #expect(!handled)
        #expect(steps.isEmpty)
    }

    @Test
    func `open submenu suspends scroll navigation`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-Submenu")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let submenu = NSMenu()
        controller.openMenus[ObjectIdentifier(menu)] = menu
        controller.openMenus[ObjectIdentifier(submenu)] = submenu
        defer { controller.openMenus.removeAll() }

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let scroll = self.makeScrollEvent(deltaY: 1, precise: false)
        let handled = controller.handleOverviewScrollWheel(scroll, menu: menu)
        #expect(!handled)
        #expect(steps.isEmpty)
    }

    @Test
    func `menus without overview rows ignore scrolling`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-NonOverview")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Refresh", action: nil, keyEquivalent: ""))

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let scroll = self.makeScrollEvent(deltaY: 1, precise: false)
        let handled = controller.handleOverviewScrollWheel(scroll, menu: menu)
        #expect(!handled)
        #expect(steps.isEmpty)
        #expect(!menu.items.isEmpty)
    }
}
