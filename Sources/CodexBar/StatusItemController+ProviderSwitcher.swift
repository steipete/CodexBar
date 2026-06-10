import AppKit
import CodexBarCore

struct PendingProviderSwitcherRebuild {
    let menu: NSMenu
    let provider: UsageProvider?
}

@MainActor
final class ProviderSwitcherShortcutEventMonitor {
    private let callback: @MainActor (NSEvent) -> Bool
    private let observer: CFRunLoopObserver
    private var isActive = false

    /// Hardware-event counters for exactly the event types the monitor handles. The run-loop
    /// observer fires on every cycle of the menu-tracking loop, and each `nextEvent` peek
    /// re-enters the run loop; doing that continuously while the pointer moves multiplies
    /// WindowServer traffic enough to overflow every other application's event buffers and
    /// freeze the desktop system-wide (#1399). Peeking only when one of these counters has
    /// changed keeps delivery semantics identical while reducing the pump from once per
    /// run-loop cycle to once per actual click or key press.
    private final class EventCounterGate: @unchecked Sendable {
        private var lastCounts: (UInt32, UInt32, UInt32)?
        private var lastCheckUptime: TimeInterval = 0

        func hasNewMatchingEvent() -> Bool {
            // Pure-userspace time bound so the counter queries themselves cannot run more than
            // ~125 times per second no matter how hot the tracking loop spins.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastCheckUptime >= 0.008 else { return false }
            self.lastCheckUptime = now
            let counts = (
                CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown),
                CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseUp),
                CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown))
            guard let last = self.lastCounts else {
                self.lastCounts = counts
                return true
            }
            guard counts != last else { return false }
            self.lastCounts = counts
            return true
        }
    }

    init(events: NSEvent.EventTypeMask, callback: @escaping @MainActor (NSEvent) -> Bool) {
        self.callback = callback

        let counterGate = EventCounterGate()
        self.observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeSources.rawValue,
            true,
            0)
        { [events, callback] _, _ in
            guard counterGate.hasNewMatchingEvent() else { return }
            MainActor.assumeIsolated {
                while let event = NSApp.nextEvent(
                    matching: events,
                    until: .distantPast,
                    inMode: .eventTracking,
                    dequeue: false)
                {
                    guard callback(event) else { break }
                    _ = NSApp.nextEvent(
                        matching: events,
                        until: .distantPast,
                        inMode: .eventTracking,
                        dequeue: true)
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
        let monitor = ProviderSwitcherShortcutEventMonitor(
            events: [.keyDown, .leftMouseDown, .leftMouseUp])
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
