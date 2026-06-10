import AppKit

/// Pre-harvest snapshot of one live content row, captured before card views are detached
/// into the recycle pool so reconciliation can still compare row shapes afterwards.
struct MenuRowShape {
    let isSeparator: Bool
    let id: String?
    let viewClassName: String?
}

extension StatusItemController {
    func menuContentShapes(in menu: NSMenu, fromIndex: Int) -> [MenuRowShape] {
        guard fromIndex >= 0, fromIndex <= menu.items.count else { return [] }
        return menu.items[fromIndex...].map { item in
            MenuRowShape(
                isSeparator: item.isSeparatorItem,
                id: item.representedObject as? String,
                viewClassName: item.view.map { String(describing: type(of: $0)) })
        }
    }

    /// Position-wise in-place reconciliation: live rows whose shape matches the freshly
    /// built content (separator placement, card identifier, view class) are updated in
    /// place — views transplanted, plain rows recopied — and only the mismatched middle
    /// span is removed and reinserted. Matching runs from both ends, so the expensive card
    /// rows at the top and the shared action rows at the bottom survive even a provider
    /// switch whose middle sections differ; AppKit then relayouts the open tracked menu for
    /// the few changed rows instead of once per row.
    func reconcileMenuContent(
        _ menu: NSMenu,
        fromIndex: Int,
        shapes: [MenuRowShape],
        with scratch: NSMenu)
    {
        defer { self.finishReconciledHighlightTracking(in: menu) }
        let newItems = scratch.items
        scratch.removeAllItems()
        guard menu.items.count - fromIndex == shapes.count else {
            // The live region changed underneath the snapshot; replace it wholesale.
            self.replaceMenuContent(menu, fromIndex: fromIndex, with: newItems)
            return
        }

        func updatable(_ shape: MenuRowShape, _ newItem: NSMenuItem) -> Bool {
            guard shape.isSeparator == newItem.isSeparatorItem else { return false }
            if shape.isSeparator { return true }
            guard shape.id == newItem.representedObject as? String else { return false }
            return shape.viewClassName == newItem.view.map { String(describing: type(of: $0)) }
        }

        var prefix = 0
        while prefix < min(shapes.count, newItems.count), updatable(shapes[prefix], newItems[prefix]) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(shapes.count, newItems.count) - prefix,
              updatable(shapes[shapes.count - 1 - suffix], newItems[newItems.count - 1 - suffix])
        {
            suffix += 1
        }

        for offset in 0..<prefix {
            self.updateMenuItemInPlace(menu.items[fromIndex + offset], from: newItems[offset])
        }
        for offset in 0..<suffix {
            self.updateMenuItemInPlace(
                menu.items[menu.items.count - 1 - offset],
                from: newItems[newItems.count - 1 - offset])
        }

        let liveMiddleCount = shapes.count - prefix - suffix
        let insertionIndex = fromIndex + prefix
        for _ in 0..<liveMiddleCount {
            menu.removeItem(at: insertionIndex)
        }
        let newMiddle = newItems[prefix..<(newItems.count - suffix)]
        for (offset, item) in newMiddle.enumerated() {
            menu.insertItem(item, at: insertionIndex + offset)
        }
    }

    private func finishReconciledHighlightTracking(in menu: NSMenu) {
        let menuKey = ObjectIdentifier(menu)
        guard let highlightedItem = self.highlightedMenuItems[menuKey] else { return }
        guard highlightedItem.menu === menu else {
            self.highlightedMenuItems.removeValue(forKey: menuKey)
            (highlightedItem.view as? MenuCardHighlighting)?.setHighlighted(false)
            return
        }
        (highlightedItem.view as? MenuCardHighlighting)?.setHighlighted(true)
    }

    private func replaceMenuContent(_ menu: NSMenu, fromIndex: Int, with newItems: [NSMenuItem]) {
        while menu.items.count > fromIndex {
            menu.removeItem(at: fromIndex)
        }
        for item in newItems {
            menu.addItem(item)
        }
    }

    private func updateMenuItemInPlace(_ liveItem: NSMenuItem, from newItem: NSMenuItem) {
        if liveItem.isSeparatorItem { return }
        let remainsHighlighted = liveItem.menu.map {
            self.highlightedMenuItems[ObjectIdentifier($0)] === liveItem
        } ?? false
        // Detach from the scratch item first so a view or submenu is never referenced by
        // two menu items at once.
        let view = newItem.view
        newItem.view = nil
        let submenu = newItem.submenu
        newItem.submenu = nil
        liveItem.view = view
        (view as? MenuCardHighlighting)?.setHighlighted(remainsHighlighted)
        liveItem.submenu = submenu
        liveItem.title = newItem.title
        liveItem.attributedTitle = newItem.attributedTitle
        liveItem.action = newItem.action
        liveItem.target = newItem.target
        liveItem.representedObject = newItem.representedObject
        liveItem.state = newItem.state
        liveItem.isEnabled = newItem.isEnabled
        liveItem.image = newItem.image
        liveItem.toolTip = newItem.toolTip
        liveItem.keyEquivalent = newItem.keyEquivalent
        liveItem.keyEquivalentModifierMask = newItem.keyEquivalentModifierMask
        liveItem.indentationLevel = newItem.indentationLevel
        if #available(macOS 14.4, *) {
            liveItem.subtitle = newItem.subtitle
        }
    }
}
