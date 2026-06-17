import AppKit

/// Pre-harvest snapshot of one live content row, captured before card views are detached
/// into the recycle pool so reconciliation can still compare row shapes afterwards.
struct MenuRowShape {
    let isSeparator: Bool
    let requiresNativeImageReplacement: Bool
    let id: String?
    let viewClassName: String?
}

extension StatusItemController {
    func menuContentShapes(in menu: NSMenu, fromIndex: Int) -> [MenuRowShape] {
        guard fromIndex >= 0, fromIndex <= menu.items.count else { return [] }
        return menu.items[fromIndex...].map { item in
            MenuRowShape(
                isSeparator: item.isSeparatorItem,
                requiresNativeImageReplacement: self.shouldReplaceNativeImageItemDuringReconcile(item),
                id: item.representedObject as? String,
                viewClassName: item.view.map { String(describing: type(of: $0)) })
        }
    }

    /// Identifies leaf AppKit image items that should be replaced instead of updated in place.
    ///
    /// AppKit can retain stale layout state for standard image-backed menu items after repeated
    /// in-place updates, which makes rows such as "Status Page" drift horizontally. Submenu rows
    /// stay on the normal reconciliation path because replacing their parent item can disturb an
    /// active submenu.
    private func shouldReplaceNativeImageItemDuringReconcile(_ item: NSMenuItem) -> Bool {
        !item.isSeparatorItem && item.view == nil && item.image != nil && item.submenu == nil
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
            guard !shape.requiresNativeImageReplacement,
                  !self.shouldReplaceNativeImageItemDuringReconcile(newItem)
            else { return false }
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

    /// Replaces cached content without first emptying the tracked menu. Compatible item shells
    /// stay attached while their payloads swap; only separator or row-count differences cause
    /// structural mutations.
    func replaceMenuContentKeepingRowsVisible(
        _ menu: NSMenu,
        fromIndex: Int,
        with newItems: [NSMenuItem])
        -> [NSMenuItem]
    {
        guard fromIndex >= 0, fromIndex <= menu.items.count else { return [] }
        defer { self.finishReconciledHighlightTracking(in: menu) }

        let liveItems = Array(menu.items[fromIndex...])
        let liveCount = liveItems.count
        let sharedCount = min(liveCount, newItems.count)
        var displacedItems: [NSMenuItem] = []
        displacedItems.reserveCapacity(liveCount)
        for offset in 0..<sharedCount {
            let index = fromIndex + offset
            let liveItem = liveItems[offset]
            let newItem = newItems[offset]
            let requiresNativeImageReplacement =
                self.shouldReplaceNativeImageItemDuringReconcile(liveItem) ||
                self.shouldReplaceNativeImageItemDuringReconcile(newItem)
            if liveItem.isSeparatorItem == newItem.isSeparatorItem, !requiresNativeImageReplacement {
                if !liveItem.isSeparatorItem {
                    self.swapMenuItemContents(liveItem, newItem)
                }
                displacedItems.append(newItem)
            } else {
                menu.insertItem(newItem, at: index)
                menu.removeItem(liveItem)
                displacedItems.append(liveItem)
            }
        }
        if newItems.count > liveCount {
            for offset in liveCount..<newItems.count {
                menu.insertItem(newItems[offset], at: fromIndex + offset)
            }
        } else if liveCount > newItems.count {
            for offset in newItems.count..<liveCount {
                menu.removeItem(liveItems[offset])
                displacedItems.append(liveItems[offset])
            }
        }
        return displacedItems
    }

    private func finishReconciledHighlightTracking(in menu: NSMenu) {
        let menuKey = ObjectIdentifier(menu)
        guard let highlightedItem = self.highlightedMenuItems[menuKey] else { return }
        guard highlightedItem.menu === menu else {
            self.highlightedMenuItems.removeValue(forKey: menuKey)
            (highlightedItem.view as? MenuCardHighlighting)?.setHighlighted(false)
            return
        }
        guard highlightedItem.isEnabled,
              (highlightedItem.view as? MenuCardHighlighting)?.allowsMenuHighlight != false
        else {
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
        liveItem.submenu = submenu
        liveItem.title = newItem.title
        liveItem.attributedTitle = newItem.attributedTitle
        liveItem.action = newItem.action
        liveItem.target = newItem.target
        liveItem.representedObject = newItem.representedObject
        liveItem.state = newItem.state
        liveItem.isEnabled = newItem.isEnabled
        let allowsHighlight = (view as? MenuCardHighlighting)?.allowsMenuHighlight != false
        (view as? MenuCardHighlighting)?.setHighlighted(newItem.isEnabled && allowsHighlight && remainsHighlighted)
        liveItem.image = newItem.image
        liveItem.toolTip = newItem.toolTip
        liveItem.keyEquivalent = newItem.keyEquivalent
        liveItem.keyEquivalentModifierMask = newItem.keyEquivalentModifierMask
        liveItem.indentationLevel = newItem.indentationLevel
        liveItem.tag = newItem.tag
        liveItem.identifier = newItem.identifier
        liveItem.isHidden = newItem.isHidden
        liveItem.isAlternate = newItem.isAlternate
        liveItem.allowsKeyEquivalentWhenHidden = newItem.allowsKeyEquivalentWhenHidden
        liveItem.onStateImage = newItem.onStateImage
        liveItem.offStateImage = newItem.offStateImage
        liveItem.mixedStateImage = newItem.mixedStateImage
        if #available(macOS 14.4, *) {
            liveItem.subtitle = newItem.subtitle
        }
    }

    private func swapMenuItemContents(_ liveItem: NSMenuItem, _ cachedItem: NSMenuItem) {
        let holder = NSMenuItem()
        self.updateMenuItemInPlace(holder, from: liveItem)
        self.updateMenuItemInPlace(liveItem, from: cachedItem)
        self.updateMenuItemInPlace(cachedItem, from: holder)
    }
}
