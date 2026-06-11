import AppKit

enum OverviewScrollStep {
    case up
    case down
}

extension StatusItemController {
    /// Pixel distance per highlight step for trackpads and other precise devices.
    private static let preciseScrollStepThreshold: CGFloat = 24
    /// Line distance per highlight step for classic scroll wheels.
    private static let lineScrollStepThreshold: CGFloat = 0.9
    /// A single fast flick should not race the highlight through the whole list.
    private static let maxScrollStepsPerEvent = 3

    /// Scrolling the wheel while the overview tab is open moves the row highlight up/down.
    /// Steps are delivered as mouse-move events over the custom card views so AppKit's
    /// native menu highlight and submenu behavior stay intact.
    @discardableResult
    func handleOverviewScrollWheel(_ event: NSEvent, menu: NSMenu) -> Bool {
        guard self.menuHasOverviewRows(menu) else {
            self.overviewScrollAccumulatedDelta = 0
            return false
        }
        // Leave the wheel alone while a row submenu is open (e.g. scrollable charts);
        // only the root overview list translates scrolling into highlight movement.
        guard self.openMenus.count <= 1 else {
            self.overviewScrollAccumulatedDelta = 0
            return false
        }
        // Momentum-phase events after a flick would keep moving the highlight long after
        // the fingers left the trackpad; swallow them without stepping.
        guard event.momentumPhase.isEmpty else { return true }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return false }

        if self.overviewScrollAccumulatedDelta != 0,
           (delta > 0) != (self.overviewScrollAccumulatedDelta > 0)
        {
            self.overviewScrollAccumulatedDelta = 0
        }
        self.overviewScrollAccumulatedDelta += delta

        let threshold = event.hasPreciseScrollingDeltas
            ? Self.preciseScrollStepThreshold
            : Self.lineScrollStepThreshold
        var steps = 0
        while abs(self.overviewScrollAccumulatedDelta) >= threshold, steps < Self.maxScrollStepsPerEvent {
            let movingUp = self.overviewScrollAccumulatedDelta > 0
            self.overviewScrollAccumulatedDelta += movingUp ? -threshold : threshold
            self.postOverviewScrollNavigation(movingUp ? .up : .down, menu: menu)
            steps += 1
        }
        // Discard the remainder once the cap is hit, otherwise the leftover delta from a
        // fast flick would keep emitting capped batches on the next small scroll.
        if steps == Self.maxScrollStepsPerEvent {
            self.overviewScrollAccumulatedDelta = 0
        }
        return true
    }

    func menuHasOverviewRows(_ menu: NSMenu) -> Bool {
        menu.items.contains { item in
            (item.representedObject as? String)?.hasPrefix(Self.overviewRowIdentifierPrefix) == true
        }
    }

    func resetOverviewScrollAccumulation() {
        self.overviewScrollAccumulatedDelta = 0
    }

    private func postOverviewScrollNavigation(_ step: OverviewScrollStep, menu: NSMenu) {
        if let handler = self.overviewScrollNavigationHandlerForTesting {
            handler(step)
            return
        }
        guard let target = self.overviewScrollTargetItem(in: menu, step: step) else { return }
        let menuID = ObjectIdentifier(menu)
        guard self.highlightedMenuItems[menuID] !== target else { return }

        // Advance local state immediately so a capped multi-step flick can target successive rows
        // before AppKit drains the synthetic mouse-move events.
        self.menu(menu, willHighlight: target)

        guard let view = target.view,
              let window = view.window
        else { return }
        let location = view.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0)
        else { return }
        NSApp.postEvent(event, atStart: false)
    }

    func overviewScrollTargetItem(in menu: NSMenu, step: OverviewScrollStep) -> NSMenuItem? {
        let rows = menu.items.filter { item in
            (item.representedObject as? String)?.hasPrefix(Self.overviewRowIdentifierPrefix) == true
        }
        guard !rows.isEmpty else { return nil }

        guard let current = self.highlightedMenuItems[ObjectIdentifier(menu)],
              let currentIndex = rows.firstIndex(where: { $0 === current })
        else {
            return step == .down ? rows.first : rows.last
        }

        let targetIndex: Int = switch step {
        case .up:
            max(0, currentIndex - 1)
        case .down:
            min(rows.count - 1, currentIndex + 1)
        }
        return rows[targetIndex]
    }
}
