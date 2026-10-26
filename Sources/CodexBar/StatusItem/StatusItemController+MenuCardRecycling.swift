import AppKit

extension StatusItemController {
    /// Collects the card hosting views of items the current populate pass is about to discard
    /// so `makeMenuCardItem` can reuse them for cards with the same identifier (or, failing
    /// that, any other card row) instead of building fresh container views.
    ///
    /// Safety: live menu items can alias one merged-switcher cache entry — the one for the
    /// selection currently displayed, re-cached at the end of every populate. Consuming that
    /// entry up front (`displacedSelection`) guarantees no cache entry can still reference a
    /// harvested view; entries for other selections only hold items already detached from the
    /// menu. Harvested views are detached from their outgoing items; whatever the pass does
    /// not consume is released by `clearMenuCardViewRecyclePool`.
    func harvestRecyclableMenuCardViews(
        in menu: NSMenu,
        fromIndex: Int,
        displacedSelection: ProviderSwitcherSelection?,
        preserveHighlightedItem: Bool = false)
    {
        self.menuCardViewRecyclePool.removeAll(keepingCapacity: true)
        let menuKey = ObjectIdentifier(menu)
        if let displacedSelection {
            self.mergedSwitcherContentCaches[menuKey]?.removeValue(forKey: displacedSelection)
        }
        guard self.menuCardRenderingEnabledForController else { return }
        guard fromIndex >= 0, fromIndex < menu.items.count else { return }
        for item in menu.items[fromIndex...] {
            guard let id = item.representedObject as? String else { continue }
            guard let view = item.view, view is any MenuCardMeasuring else { continue }
            guard self.menuCardViewRecyclePool[id] == nil else { continue }
            // Unhighlight before detaching: the highlight tracker unwinds through the
            // outgoing item's `view`, which is about to become nil, so a recycled view
            // would otherwise re-attach visibly highlighted with no path to clear it.
            if self.highlightedMenuItems[menuKey] === item {
                if !preserveHighlightedItem {
                    self.highlightedMenuItems.removeValue(forKey: menuKey)
                }
            }
            (view as? MenuCardHighlighting)?.setHighlighted(false)
            item.view = nil
            self.menuCardViewRecyclePool[id] = view
        }
    }

    /// Pops a pool entry adoptable as `ViewType`: the same card identifier when its view
    /// matches, otherwise the first type-compatible leftover. Since all menu-card rows now use
    /// one erased container type, the fallback also covers Overview↔provider transitions.
    func takeRecyclableMenuCardView<ViewType: NSView>(for id: String, as type: ViewType.Type) -> ViewType? {
        if let candidate = self.menuCardViewRecyclePool.removeValue(forKey: id) {
            if let adopted = candidate as? ViewType {
                return adopted
            }
            // A same-id view of an incompatible shape can never be adopted later in this
            // pass; dropping it restores the build-fresh behavior.
            return nil
        }
        guard let match = self.menuCardViewRecyclePool.first(where: { $0.value is ViewType }) else {
            return nil
        }
        self.menuCardViewRecyclePool.removeValue(forKey: match.key)
        return match.value as? ViewType
    }

    func clearMenuCardViewRecyclePool() {
        self.menuCardViewRecyclePool.removeAll(keepingCapacity: true)
    }
}
