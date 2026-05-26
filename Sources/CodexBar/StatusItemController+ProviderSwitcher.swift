import AppKit
import CodexBarCore

final class ProviderSwitcherShortcutEventMonitor {
    private let events: NSEvent.EventTypeMask
    private let callback: @MainActor (NSEvent) -> NSEvent?
    private let observer: CFRunLoopObserver
    private var isActive = false

    init(events: NSEvent.EventTypeMask, callback: @escaping @MainActor (NSEvent) -> NSEvent?) {
        self.events = events
        self.callback = callback

        self.observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeSources.rawValue,
            true,
            0)
        { [events, callback] _, _ in
            MainActor.assumeIsolated {
                var queuedEvents: [NSEvent] = []
                while let event = NSApp.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) {
                    queuedEvents.append(event)
                }

                for event in queuedEvents {
                    let eventMask = NSEvent.EventTypeMask(rawValue: 1 << event.type.rawValue)
                    let eventToPost = if events.contains(eventMask) {
                        callback(event)
                    } else {
                        event
                    }
                    guard let eventToPost else { continue }
                    NSApp.postEvent(eventToPost, atStart: false)
                }
            }
        }
    }

    deinit {
        self.stop()
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
        guard Self.menuRefreshEnabled,
              self.shouldMergeIcons,
              menu.items.first?.view is ProviderSwitcherView
        else {
            return
        }

        self.removeProviderSwitcherShortcutMonitor()
        let monitor = ProviderSwitcherShortcutEventMonitor(events: [.keyDown]) { [weak self, weak menu] event in
            guard let self,
                  let menu,
                  self.openMenus[ObjectIdentifier(menu)] != nil,
                  menu.items.first?.view is ProviderSwitcherView
            else {
                return event
            }

            return self.handleProviderSwitcherShortcut(event, menu: menu) ? nil : event
        }
        monitor.start()
        self.providerSwitcherShortcutEventMonitor = monitor
        self.providerSwitcherShortcutMenuID = ObjectIdentifier(menu)
    }

    func removeProviderSwitcherShortcutMonitor() {
        self.providerSwitcherShortcutEventMonitor?.stop()
        self.providerSwitcherShortcutEventMonitor = nil
        self.providerSwitcherShortcutMenuID = nil
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
    private func selectProviderSwitcherSegment(at index: Int, menu: NSMenu) -> Bool {
        guard let switcherView = menu.items.first?.view as? ProviderSwitcherView,
              switcherView.handleKeyboardSelection(at: index)
        else {
            return false
        }
        self.applyIcon(phase: nil)
        return true
    }
}
