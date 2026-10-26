import AppKit

enum OverviewScrollStep {
    case up
    case down
}

extension StatusItemController {
    /// Line distance per highlight step for classic scroll wheels.
    private static let lineScrollStepThreshold: CGFloat = 0.9
    /// A single fast flick should not race the highlight through the whole list.
    private static let maxScrollStepsPerEvent = 3

    /// Classic scroll wheels keep row-to-row overview navigation while the whole menu fits.
    /// Overflowing menus and precise trackpad scrolling are left to AppKit's native scroller so
    /// content follows the user's input instead of jumping only the highlighted row.
    @discardableResult
    func handleOverviewScrollWheel(_ event: NSEvent, menu: NSMenu) -> Bool {
        // Only the root overview list translates coarse scrolling into highlight movement;
        // row submenus (e.g. scrollable charts) and precise input stay with AppKit.
        guard menu.items.contains(where: self.isOverviewRow),
              self.openMenus.count <= 1,
              !event.hasPreciseScrollingDeltas
        else {
            self.overviewScrollAccumulatedDelta = 0
            return false
        }
        // Highlighting a custom row does not reveal it. Let AppKit move overflowing content,
        // using settled geometry from this presentation rather than a cached menu size.
        if let scrollView = Self.attachedMenuScrollView(in: menu) {
            scrollView.layoutSubtreeIfNeeded()
            if let geometry = Self.menuViewportGeometry(in: scrollView),
               geometry.clipSize.height > 0,
               geometry.documentSize.height - geometry.clipSize.height > 0.5
            {
                self.overviewScrollAccumulatedDelta = 0
                return false
            }
        }
        // Precise trackpad/Magic Mouse scrolling already returned above, so this only guards
        // non-precise devices that still report a momentum phase: swallow that flick tail so the
        // highlight does not keep stepping after the fingers lift.
        guard event.momentumPhase.isEmpty else { return true }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return false }

        if self.overviewScrollAccumulatedDelta != 0,
           (delta > 0) != (self.overviewScrollAccumulatedDelta > 0)
        {
            self.overviewScrollAccumulatedDelta = 0
        }
        self.overviewScrollAccumulatedDelta += delta

        let threshold = Self.lineScrollStepThreshold
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

    private func isOverviewRow(_ item: NSMenuItem) -> Bool {
        (item.representedObject as? String)?.hasPrefix(Self.overviewRowIdentifierPrefix) == true
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
        let changesRow = self.highlightedMenuItems[menuID] !== target

        // Advance local state immediately so a capped multi-step flick can target successive rows
        // before AppKit drains the synthetic mouse-move events.
        self.menu(menu, willHighlight: target, eventType: .scrollWheel)
        guard changesRow else { return }

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
        let rows = menu.items.filter(self.isOverviewRow)
        guard !rows.isEmpty else { return nil }

        guard let current = self.highlightedMenuItems[ObjectIdentifier(menu)],
              let currentIndex = rows.firstIndex(where: { $0 === current })
        else {
            return step == .down ? rows.first : rows.last
        }

        let offset = step == .up ? -1 : 1
        let targetIndex = min(rows.count - 1, max(0, currentIndex + offset))
        return rows[targetIndex]
    }
}
