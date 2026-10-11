import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

private final class OverviewScrollEvent: NSEvent {
    private let delta: CGFloat
    private let precise: Bool
    private let momentum: NSEvent.Phase

    init(deltaY: CGFloat, precise: Bool, momentumPhase: NSEvent.Phase = []) {
        self.delta = deltaY
        self.precise = precise
        self.momentum = momentumPhase
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
        self.momentum
    }
}

private final class DeferredOverviewScrollView: NSScrollView {
    var pendingDocumentHeight: CGFloat?

    override func layout() {
        super.layout()
        if let height = self.pendingDocumentHeight, let documentView {
            self.pendingDocumentHeight = nil
            documentView.setFrameSize(NSSize(width: documentView.frame.width, height: height))
        }
    }
}

@MainActor
@Suite(.serialized)
struct StatusMenuOverviewScrollTests {
    private func makeController(suiteName: String, renderCards: Bool = false) throws -> StatusItemController {
        let suite = "\(suiteName)-\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults()
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
            menuCardRenderingEnabled: renderCards,
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

    private func makeScrollEvent(
        deltaY: CGFloat,
        precise: Bool,
        momentumPhase: NSEvent.Phase = []) -> NSEvent
    {
        // CGEvent line-scroll conversion can yield zero deltas depending on host state.
        // Supply the handler's NSEvent inputs directly without posting an event.
        OverviewScrollEvent(deltaY: deltaY, precise: precise, momentumPhase: momentumPhase)
    }

    private func attachMenuViewport(
        to menu: NSMenu,
        horizontalOverflow: Bool = false,
        verticalOverflow: Bool = false,
        itemIndex: Int = 0,
        viewport: NSScrollView? = nil) -> NSScrollView
    {
        let scrollView = viewport ?? NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let clipSize = scrollView.contentView.bounds.size
        let documentView = NSView(frame: NSRect(
            origin: .zero,
            size: NSSize(
                width: clipSize.width + (horizontalOverflow ? 200 : 0),
                height: clipSize.height + (verticalOverflow ? 400 : 0))))
        scrollView.documentView = documentView

        let hostedItemView = menu.items[itemIndex].view ?? NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        menu.items[itemIndex].view = hostedItemView
        documentView.addSubview(hostedItemView)
        return scrollView
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
    func `overflowing menu leaves coarse wheel events unhandled`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-OverflowWheel")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let scrollView = self.attachMenuViewport(to: menu, verticalOverflow: true)
        #expect(StatusItemController.attachedMenuScrollView(in: menu) === scrollView)

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let wheelNotch = self.makeScrollEvent(deltaY: -1, precise: false)
        #expect(!controller.handleOverviewScrollWheel(wheelNotch, menu: menu))
        #expect(steps.isEmpty)
        #expect(StatusItemController.attachedMenuScrollView(in: menu) === scrollView)
    }

    @Test
    func `overflowing menu leaves coarse momentum events unhandled`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-OverflowMomentum")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let scrollView = self.attachMenuViewport(to: menu, verticalOverflow: true)

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let momentum = self.makeScrollEvent(deltaY: -1, precise: false, momentumPhase: .changed)
        #expect(!controller.handleOverviewScrollWheel(momentum, menu: menu))
        #expect(steps.isEmpty)
        #expect(StatusItemController.attachedMenuScrollView(in: menu) === scrollView)
    }

    @Test
    func `non overflowing menu keeps coarse wheel highlight navigation`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-NoOverflow")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let scrollView = self.attachMenuViewport(to: menu)

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let wheelNotch = self.makeScrollEvent(deltaY: -1, precise: false)
        #expect(controller.handleOverviewScrollWheel(wheelNotch, menu: menu))
        #expect(steps == [.down])
        #expect(StatusItemController.attachedMenuScrollView(in: menu) === scrollView)
    }

    @Test
    func `non overflowing menu keeps coarse momentum swallowed`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-NoOverflowMomentum")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let scrollView = self.attachMenuViewport(to: menu)

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let momentum = self.makeScrollEvent(deltaY: -1, precise: false, momentumPhase: .changed)
        #expect(controller.handleOverviewScrollWheel(momentum, menu: menu))
        #expect(steps.isEmpty)
        #expect(StatusItemController.attachedMenuScrollView(in: menu) === scrollView)
    }

    @Test
    func `horizontal overflow keeps coarse wheel highlight navigation`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-HorizontalOverflow")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let scrollView = self.attachMenuViewport(to: menu, horizontalOverflow: true)

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let wheelNotch = self.makeScrollEvent(deltaY: -1, precise: false)
        #expect(controller.handleOverviewScrollWheel(wheelNotch, menu: menu))
        #expect(steps == [.down])
        #expect(StatusItemController.attachedMenuScrollView(in: menu) === scrollView)
    }

    @Test
    func `becoming vertically overflowed clears accumulated wheel distance`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-OverflowTransition")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let scrollView = self.attachMenuViewport(to: menu)

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let partialNotch = self.makeScrollEvent(deltaY: -0.5, precise: false)
        #expect(controller.handleOverviewScrollWheel(partialNotch, menu: menu))
        #expect(controller.overviewScrollAccumulatedDelta == -0.5)
        #expect(steps.isEmpty)

        let clipHeight = scrollView.contentView.bounds.height
        scrollView.documentView?.setFrameSize(NSSize(width: 200, height: clipHeight + 400))

        let overflowNotch = self.makeScrollEvent(deltaY: -1, precise: false)
        #expect(!controller.handleOverviewScrollWheel(overflowNotch, menu: menu))
        #expect(controller.overviewScrollAccumulatedDelta == 0)
        #expect(steps.isEmpty)
    }

    @Test
    func `pending viewport layout settles before coarse wheel routing`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-PendingLayout")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let viewport = DeferredOverviewScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let scrollView = self.attachMenuViewport(to: menu, viewport: viewport)
        viewport.pendingDocumentHeight = 500
        viewport.needsLayout = true

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }
        #expect(!controller.handleOverviewScrollWheel(self.makeScrollEvent(deltaY: -1, precise: false), menu: menu))
        #expect(steps.isEmpty)
        #expect(scrollView.documentView?.frame.height == 500)
    }

    @Test
    func `precise input bypasses pending viewport layout`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-PreciseLayout")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let viewport = DeferredOverviewScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let scrollView = self.attachMenuViewport(to: menu, viewport: viewport)
        viewport.pendingDocumentHeight = 500
        viewport.needsLayout = true
        controller.overviewScrollAccumulatedDelta = -0.5

        #expect(!controller.handleOverviewScrollWheel(self.makeScrollEvent(deltaY: -1, precise: true), menu: menu))
        #expect(viewport.pendingDocumentHeight == 500)
        #expect(controller.overviewScrollAccumulatedDelta == 0)
        #expect(StatusItemController.attachedMenuScrollView(in: menu) === scrollView)
    }

    @Test
    func `zero height viewport falls back until usable geometry arrives`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-ZeroHeight")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let scrollView = self.attachMenuViewport(to: menu, verticalOverflow: true)
        let viewportSize = scrollView.frame.size
        scrollView.setFrameSize(NSSize(width: viewportSize.width, height: 0))
        scrollView.layoutSubtreeIfNeeded()
        #expect(scrollView.contentView.bounds.height == 0)

        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }
        let partialNotch = self.makeScrollEvent(deltaY: -0.5, precise: false)
        #expect(controller.handleOverviewScrollWheel(partialNotch, menu: menu))
        #expect(controller.overviewScrollAccumulatedDelta == -0.5)
        scrollView.setFrameSize(viewportSize)
        #expect(!controller.handleOverviewScrollWheel(partialNotch, menu: menu))
        #expect(controller.overviewScrollAccumulatedDelta == 0)
        #expect(steps.isEmpty)
    }

    @Test
    func `momentum tail is swallowed without highlight movement after menu refits`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-RefitMomentum")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let scrollView = self.attachMenuViewport(to: menu, verticalOverflow: true)
        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }

        let beginning = self.makeScrollEvent(deltaY: -1, precise: false, momentumPhase: .began)
        #expect(!controller.handleOverviewScrollWheel(beginning, menu: menu))
        scrollView.documentView?.setFrameSize(scrollView.contentView.bounds.size)
        for phase: NSEvent.Phase in [.changed, .ended, .cancelled] {
            let tail = self.makeScrollEvent(deltaY: -1, precise: false, momentumPhase: phase)
            #expect(controller.handleOverviewScrollWheel(tail, menu: menu))
        }
        #expect(steps.isEmpty)
        #expect(controller.overviewScrollAccumulatedDelta == 0)
        #expect(controller.handleOverviewScrollWheel(self.makeScrollEvent(deltaY: -0.5, precise: false), menu: menu))
        #expect(steps.isEmpty)
    }

    @Test
    func `reopened menu uses its replacement viewport size`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-Reopen")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let oldViewport = self.attachMenuViewport(to: menu, verticalOverflow: true)
        let wheel = self.makeScrollEvent(deltaY: -1, precise: false)
        var steps: [OverviewScrollStep] = []
        controller.overviewScrollNavigationHandlerForTesting = { steps.append($0) }
        #expect(!controller.handleOverviewScrollWheel(wheel, menu: menu))

        let fittedViewport = self.attachMenuViewport(to: menu)
        #expect(oldViewport !== fittedViewport)
        #expect(controller.handleOverviewScrollWheel(wheel, menu: menu))
        #expect(steps == [.down])
        menu.items[0].view?.removeFromSuperview()
        #expect(StatusItemController.attachedMenuScrollView(in: menu) == nil)
        #expect(controller.handleOverviewScrollWheel(wheel, menu: menu))
        #expect(steps == [.down, .down])
    }

    @Test(arguments: [false, true])
    func `overflow routing through detached switcher still records user scrolling`(precise: Bool) throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-Switcher")
        defer { controller.releaseStatusItemsForTesting() }
        let menu = self.makeOverviewMenu()
        let switcherItem = NSMenuItem()
        switcherItem.isEnabled = false
        switcherItem.view = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .overview,
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { _ in })
        menu.insertItem(switcherItem, at: 0)
        menu.insertItem(.separator(), at: 1)
        let scrollView = self.attachMenuViewport(to: menu, verticalOverflow: true, itemIndex: 2)
        let menuID = ObjectIdentifier(menu)
        controller.openMenus[menuID] = menu
        let generation = controller.menuSession.beginTrackingSession(menuID)
        defer { controller.openMenus.removeAll() }

        let wheel = self.makeScrollEvent(deltaY: -1, precise: precise)
        #expect(!controller.handleMenuTrackingShortcutEvent(wheel, menu: menu))
        #expect(controller.menuSession.menuInteractionGeneration(for: menuID) == generation + 1)
        #expect(StatusItemController.attachedMenuScrollView(in: menu) === scrollView)
        #expect(switcherItem.view?.enclosingScrollView == nil)
    }

    @Test
    func `wheel at an overview boundary clears keyboard only highlighting`() throws {
        let controller = try self.makeController(suiteName: #function, renderCards: true)
        defer { controller.releaseStatusItemsForTesting() }
        controller.settings.highlightMenuCardsOnHover = false
        let menu = NSMenu()
        let item = controller.makeMenuCardItem(
            Text("Codex"), id: "overviewRow-codex", width: 200, usesGPUSelection: true, onClick: {})
        menu.addItem(item)
        let row = try #require(item.view as? MenuRowContainerView)
        controller.menu(menu, willHighlight: item, eventType: .keyDown)
        #expect(row.isHighlightedForTesting)
        #expect(controller.handleOverviewScrollWheel(self.makeScrollEvent(deltaY: 1, precise: false), menu: menu))
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] === item)
        #expect(!row.isHighlightedForTesting)
    }

    @Test
    func `custom provider highlight skips disabled sections without revealing a detached row`() throws {
        let controller = try self.makeController(suiteName: "OverviewScroll-CustomRows", renderCards: true)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = NSMenu()
        let first = controller.makeMenuCardItem(
            Text("First provider"), id: "overviewRow-claude", width: 200, usesGPUSelection: true, onClick: {})
        let last = controller.makeMenuCardItem(
            Text("Last provider"), id: "overviewRow-codex", width: 200, usesGPUSelection: true, onClick: {})
        menu.addItem(first)
        for index in 0..<3 {
            let section = controller.makeMenuCardItem(Text("Section"), id: "section-\(index)", width: 200)
            #expect(!section.isEnabled)
            menu.addItem(section)
        }
        menu.addItem(last)
        let scrollView = self.attachMenuViewport(to: menu, verticalOverflow: true)
        let lastView = try #require(last.view as? MenuRowContainerView)
        let origin = scrollView.contentView.bounds.origin
        #expect(first.isEnabled && last.isEnabled)
        #expect(first is MenuCardMenuItem && last is MenuCardMenuItem)
        #expect(lastView.window == nil)
        controller.menu(menu, willHighlight: first)
        #expect(controller.overviewScrollTargetItem(in: menu, step: .down) === last)
        controller.menu(menu, willHighlight: last)
        #expect(lastView.isHighlightedForTesting)
        #expect(!last.isHighlighted)
        #expect(scrollView.contentView.bounds.origin == origin)
        #expect(lastView.window == nil)
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
