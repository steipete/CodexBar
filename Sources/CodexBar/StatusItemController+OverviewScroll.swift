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
    /// Steps are delivered as synthetic arrow-key events so AppKit's native menu highlight,
    /// submenu, and return-key activation behavior stay intact.
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
            self.postOverviewScrollNavigation(movingUp ? .up : .down)
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

    private func postOverviewScrollNavigation(_ step: OverviewScrollStep) {
        if let handler = self.overviewScrollNavigationHandlerForTesting {
            handler(step)
            return
        }
        let keyCode: UInt16 = step == .down ? 125 : 126
        guard let keyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode)
        else { return }
        NSApp.postEvent(keyEvent, atStart: true)
    }
}
