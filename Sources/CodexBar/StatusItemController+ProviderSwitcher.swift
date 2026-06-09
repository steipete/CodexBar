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

    init(events: NSEvent.EventTypeMask, callback: @escaping @MainActor (NSEvent) -> Bool) {
        self.callback = callback

        self.observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeSources.rawValue,
            true,
            0)
        { [events, callback] _, _ in
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
            self.navigateProviderSwitcher(direction)
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
