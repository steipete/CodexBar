import AppKit
import CodexBarCore

struct PendingProviderSwitcherRebuild {
    let menu: NSMenu
    let provider: UsageProvider?
}

/// Skips the event-queue peek on run-loop passes where no event of the monitored kinds
/// can possibly be pending. The menu-tracking run loop spins on every mouse move, and the
/// session-wide event counters for keys and clicks are far cheaper to read than
/// `NSApp.nextEvent` is to call, so gating on them removes the per-pass peek cost from
/// hover-heavy menu interaction (mouse moves never advance these counters).
@MainActor
final class ProviderSwitcherEventPeekGate {
    private let eventTypes: [CGEventType]
    private let counterProvider: (CGEventType) -> UInt32
    private var lastCounters: [UInt32]?
    private var heldKeyCodes: Set<UInt16> = []
    private var emptyPeekBudget = 0

    init(
        eventTypes: [CGEventType],
        counterProvider: @escaping (CGEventType) -> UInt32 = { type in
            CGEventSource.counterForEventType(.combinedSessionState, eventType: type)
        })
    {
        self.eventTypes = eventTypes
        self.counterProvider = counterProvider
    }

    /// True when an event of a monitored kind may have been posted since the last check.
    func shouldPeek() -> Bool {
        let counters = self.eventTypes.map(self.counterProvider)
        let countersChanged = self.lastCounters.map { counters != $0 } ?? true
        self.lastCounters = counters
        if countersChanged {
            // The observer runs before run-loop sources. WindowServer can advance a counter
            // one pass before AppKit queues the NSEvent, so require two empty peeks before
            // considering the queue caught up.
            self.emptyPeekBudget = max(self.emptyPeekBudget, 2)
        }
        // CoreGraphics does not count key autorepeat events. Keep peeking while a key is
        // held so repeated provider-navigation events are still handled.
        if !self.heldKeyCodes.isEmpty { return true }
        return self.emptyPeekBudget > 0
    }

    func observe(_ event: NSEvent) {
        // An unhandled event stays queued until AppKit processes it after this observer.
        // Keep peeking until a later pass proves the matching queue is empty.
        self.emptyPeekBudget = max(self.emptyPeekBudget, 1)
        switch event.type {
        case .keyDown:
            self.heldKeyCodes.insert(event.keyCode)
        case .keyUp:
            self.heldKeyCodes.remove(event.keyCode)
        default:
            break
        }
    }

    func observeQueueEmpty(afterFindingEvent: Bool) {
        if afterFindingEvent {
            // A counter snapshot can represent multiple events that AppKit delivers across
            // run-loop passes. Keep one empty proof pending after draining available events.
            self.emptyPeekBudget = max(self.emptyPeekBudget - 1, 1)
        } else if self.emptyPeekBudget > 0 {
            self.emptyPeekBudget -= 1
        }
    }
}

@MainActor
final class ProviderSwitcherShortcutEventMonitor {
    private let callback: @MainActor (NSEvent) -> Bool
    private let observer: CFRunLoopObserver
    private var isActive = false

    init(
        events: NSEvent.EventTypeMask,
        peekGate: ProviderSwitcherEventPeekGate = ProviderSwitcherEventPeekGate(
            eventTypes: [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp]),
        callback: @escaping @MainActor (NSEvent) -> Bool)
    {
        self.callback = callback

        self.observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeSources.rawValue,
            true,
            0)
        { [events, peekGate, callback] _, _ in
            MainActor.assumeIsolated {
                guard peekGate.shouldPeek() else { return }
                var foundEvent = false
                var blockedByUnhandledEvent = false
                while let event = NSApp.nextEvent(
                    matching: events,
                    until: .distantPast,
                    inMode: .eventTracking,
                    dequeue: false)
                {
                    foundEvent = true
                    peekGate.observe(event)
                    guard callback(event) else {
                        blockedByUnhandledEvent = true
                        break
                    }
                    _ = NSApp.nextEvent(
                        matching: events,
                        until: .distantPast,
                        inMode: .eventTracking,
                        dequeue: true)
                }
                if !blockedByUnhandledEvent {
                    peekGate.observeQueueEmpty(afterFindingEvent: foundEvent)
                }
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            self.stop()
        }
    }

    func start() {
        guard !self.isActive else { return }
        CFRunLoopAddObserver(
            RunLoop.main.getCFRunLoop(),
            self.observer,
            CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        self.isActive = true
    }

    func stop() {
        guard self.isActive else { return }
        CFRunLoopRemoveObserver(
            RunLoop.main.getCFRunLoop(),
            self.observer,
            CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        self.isActive = false
    }
}

extension StatusItemController {
    func installProviderSwitcherShortcutMonitorIfNeeded(for menu: NSMenu) {
        guard self.isMenuRefreshEnabled,
              self.shouldMergeIcons,
              menu.items.first?.view is ProviderSwitcherView
        else {
            return
        }

        self.removeProviderSwitcherShortcutMonitor()
        self.resetOverviewScrollAccumulation()
        let monitor = ProviderSwitcherShortcutEventMonitor(
            events: [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .scrollWheel],
            peekGate: ProviderSwitcherEventPeekGate(
                eventTypes: [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .scrollWheel]))
        { [weak self, weak menu] event in
            guard let self,
                  let menu,
                  self.openMenus[ObjectIdentifier(menu)] != nil,
                  menu.items.first?.view is ProviderSwitcherView
            else {
                return false
            }

            return self.handleProviderSwitcherTrackingEvent(event, menu: menu)
        }
        monitor.start()
        self.providerSwitcherShortcutEventMonitor = monitor
        self.providerSwitcherShortcutMenuID = ObjectIdentifier(menu)
    }

    func removeProviderSwitcherShortcutMonitor() {
        self.providerSwitcherShortcutEventMonitor?.stop()
        self.providerSwitcherShortcutEventMonitor = nil
        self.providerSwitcherShortcutMenuID = nil
        self.clearProviderSwitcherPointerInteraction()
    }

    func providerSwitcherContentStartIndex(in menu: NSMenu) -> Int {
        menu.items.first?.view is ProviderSwitcherView ? 2 : 0
    }

    @discardableResult
    func handleProviderSwitcherShortcut(_ event: NSEvent, menu: NSMenu) -> Bool {
        if let index = StatusItemMenu.providerSelectionIndex(for: event) {
            return self.selectProviderSwitcherSegment(at: index, menu: menu)
        }
        if let direction = StatusItemMenu.providerNavigationDirection(for: event) {
            self.navigateProviderSwitcher(direction, menu: menu)
            return true
        }
        return false
    }

    @discardableResult
    func handleProviderSwitcherTrackingEvent(_ event: NSEvent, menu: NSMenu) -> Bool {
        switch event.type {
        case .keyDown:
            return self.handleProviderSwitcherShortcut(event, menu: menu)
        case .leftMouseDown:
            guard let switcher = menu.items.first?.view as? ProviderSwitcherView else { return false }
            self.beginProviderSwitcherPointerInteraction(in: menu)
            let handled = switcher.handleMenuTrackingMouseDown(event)
            if !handled {
                self.clearProviderSwitcherPointerInteraction(in: menu)
            }
            return handled
        case .leftMouseUp:
            guard self.providerSwitcherPointerInteractionMenuID == ObjectIdentifier(menu) else {
                return false
            }
            guard let switcher = menu.items.first?.view as? ProviderSwitcherView else {
                self.clearProviderSwitcherPointerInteraction(in: menu)
                return true
            }
            _ = switcher.handleMenuTrackingMouseUp(event)
            self.finishProviderSwitcherPointerInteraction(in: menu)
            return true
        case .scrollWheel:
            return self.handleOverviewScrollWheel(event, menu: menu)
        default:
            return false
        }
    }

    func requestProviderSwitcherMenuRebuild(_ menu: NSMenu, provider: UsageProvider?) {
        guard self.providerSwitcherPointerInteractionMenuID == ObjectIdentifier(menu) else {
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: provider)
            return
        }
        self.pendingProviderSwitcherPointerRebuild = PendingProviderSwitcherRebuild(
            menu: menu,
            provider: provider)
    }

    private func beginProviderSwitcherPointerInteraction(in menu: NSMenu) {
        let menuID = ObjectIdentifier(menu)
        if self.providerSwitcherPointerInteractionMenuID != menuID {
            self.pendingProviderSwitcherPointerRebuild = nil
        }
        self.providerSwitcherPointerInteractionMenuID = menuID
    }

    private func finishProviderSwitcherPointerInteraction(in menu: NSMenu) {
        let menuID = ObjectIdentifier(menu)
        guard self.providerSwitcherPointerInteractionMenuID == menuID else { return }
        self.providerSwitcherPointerInteractionMenuID = nil
        guard let pending = self.pendingProviderSwitcherPointerRebuild,
              pending.menu === menu
        else {
            self.pendingProviderSwitcherPointerRebuild = nil
            return
        }
        self.pendingProviderSwitcherPointerRebuild = nil
        self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: pending.provider)
    }

    private func clearProviderSwitcherPointerInteraction(in menu: NSMenu? = nil) {
        if let menu,
           self.providerSwitcherPointerInteractionMenuID != ObjectIdentifier(menu)
        {
            return
        }
        self.providerSwitcherPointerInteractionMenuID = nil
        self.pendingProviderSwitcherPointerRebuild = nil
    }

    @discardableResult
    private func selectProviderSwitcherSegment(at index: Int, menu: NSMenu) -> Bool {
        guard let switcherView = menu.items.first?.view as? ProviderSwitcherView,
              switcherView.handleKeyboardSelection(at: index)
        else {
            return false
        }
        return true
    }
}
