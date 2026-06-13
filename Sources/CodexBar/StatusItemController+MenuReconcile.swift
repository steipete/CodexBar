import AppKit

// ============================================================================
// LAYOUT ENGINE ARCHITECTURE
// ============================================================================
// CodexBar menu rendering follows a strict two-phase deterministic pipeline:
//
//   PHASE C — LAYOUT ENGINE
//     • All SwiftUI measurement, intrinsic sizing, fittingSize evaluation
//     • All content fingerprinting, height caching, LayoutGraph construction
//     • All menu-item property setup (title, action, target, submenu, …)
//     • View allocation: NSHostingView(rootView:) — exactly once per content
//     • Frame commit: hosting.frame = precomputedSize
//     • Output: frozen NSMenuItem snapshot (view + properties)
//     • MUST NOT touch NSMenu — output is the LayoutGraph
//
//   PHASE A — RENDER LAYER
//     • ONLY responsibility: assign NSView to NSMenuItem
//     • NO measurement, NO SwiftUI interaction, NO invalidateIntrinsicContentSize
//     • NO fittingSize / intrinsicContentSize access
//     • NO layout computation of any kind
//     • NSMenu is a passive renderer; A-phase hands it precomputed views
//
// The boundary is enforced structurally: A-phase functions are 1-line assignments.
// Any future code that wants to do "more" in A-phase must be justified against
// this contract.
// ============================================================================

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
            let live = menu.items[fromIndex + offset]
            let scratch = newItems[offset]
            // Phase C: content sync (properties only, no view).
            self.applyMenuItemContent(live, from: scratch)
            // Phase A: view handoff (precomputed view, no measurement).
            self.updateMenuItemInPlace(live, from: scratch)
        }
        for offset in 0..<suffix {
            let live = menu.items[menu.items.count - 1 - offset]
            let scratch = newItems[newItems.count - 1 - offset]
            // Phase C: content sync.
            self.applyMenuItemContent(live, from: scratch)
            // Phase A: view handoff.
            self.updateMenuItemInPlace(live, from: scratch)
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
            if liveItem.isSeparatorItem == newItem.isSeparatorItem {
                if !liveItem.isSeparatorItem {
                    self.swapMenuItemContents(liveItem, newItem)
                }
                displacedItems.append(newItem)
            } else {
                // Phase A: structural replacement when shape doesn't match.
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

    /// === PHASE C: LAYOUT ENGINE ===
    /// Applies the content payload of a freshly-built NSMenuItem onto an existing live
    /// NSMenuItem that already occupies its slot in the tracked menu. Pure property
    /// synchronization — no view transfer, no layout, no SwiftUI interaction.
    /// Called by A-phase render-layer callers before the view handoff.
    private func applyMenuItemContent(_ liveItem: NSMenuItem, from newItem: NSMenuItem) {
        if liveItem.isSeparatorItem { return }
        liveItem.submenu = newItem.submenu
        newItem.submenu = nil
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

    /// === PHASE A: RENDER LAYER ===
    /// Pure view transfer. The precomputed NSHostingView from C-phase is moved from
    /// the scratch item onto the existing live item in the tracked menu. NO measurement,
    /// NO SwiftUI interaction, NO layout invalidation, NO fittingSize/intrinsicContentSize
    /// access. The view's frame is already authoritative from C-phase; the live item
    /// keeps its current submenu/property state (which C-phase updated via
    /// `applyMenuItemContent` before this handoff).
    private func updateMenuItemInPlace(_ liveItem: NSMenuItem, from newItem: NSMenuItem) {
        if liveItem.isSeparatorItem { return }
        let remainsHighlighted = liveItem.menu.map {
            self.highlightedMenuItems[ObjectIdentifier($0)] === liveItem
        } ?? false
        // Single-assignment view handoff. Nothing else belongs in this function.
        let precomputedView = newItem.view
        newItem.view = nil
        liveItem.view = precomputedView
        (precomputedView as? MenuCardHighlighting)?.setHighlighted(remainsHighlighted)
    }

    private func swapMenuItemContents(_ liveItem: NSMenuItem, _ cachedItem: NSMenuItem) {
        let holder = NSMenuItem()
        // Phase C: three-way content rotation
        //   holder   ← liveItem  (save live's state)
        //   liveItem ← cachedItem (live now mirrors cached)
        //   cachedItem ← holder   (cached now mirrors live's old state)
        self.applyMenuItemContent(holder, from: liveItem)
        self.applyMenuItemContent(liveItem, from: cachedItem)
        self.applyMenuItemContent(cachedItem, from: holder)
        // Phase A: three-way view rotation (same pattern)
        self.updateMenuItemInPlace(holder, from: liveItem)
        self.updateMenuItemInPlace(liveItem, from: cachedItem)
        self.updateMenuItemInPlace(cachedItem, from: holder)
    }
}
