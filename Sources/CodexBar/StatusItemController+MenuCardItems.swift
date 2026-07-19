import AppKit
import SwiftUI

extension StatusItemController {
    func refreshMenuCardHeights(in menu: NSMenu) {
        let width = self.renderedMenuWidth(for: menu)
        for item in menu.items {
            if let view = item.view as? PersistentRefreshMenuView {
                guard abs(view.frame.width - width) > 0.5 else { continue }
                view.applySize(width: width, height: PersistentRefreshRowMetrics.defaults.rowHeight)
                continue
            }
            guard let view = item.view, view is any MenuCardMeasuring else { continue }
            guard abs(view.frame.width - width) > 0.5 else { continue }
            let id = item.representedObject as? String ?? "menuCard"
            let scope = self.menuProvider(for: menu)?.rawValue ?? id
            let height = self.cachedMenuCardHeight(for: id, scope: scope, width: width) {
                self.menuCardHeight(for: view, width: width)
            }
            view.frame = NSRect(
                origin: .zero,
                size: NSSize(width: width, height: height))
        }
    }

    func makeMenuCardItem<CardContent: View>(
        _ view: CardContent,
        id: String,
        width: CGFloat,
        heightCacheScope: String? = nil,
        heightCacheFingerprint: String? = nil,
        submenu: NSMenu? = nil,
        submenuIndicatorAlignment: Alignment = .topTrailing,
        submenuIndicatorTopPadding: CGFloat = 8,
        containsInteractiveControls: Bool = false,
        usesGPUSelection: Bool = false,
        onClick: (() -> Void)? = nil) -> NSMenuItem
    {
        let allowsMenuHighlight = submenu != nil || onClick != nil
        if !self.menuCardRenderingEnabledForController {
            let item = NSMenuItem()
            item.isEnabled = allowsMenuHighlight
            item.representedObject = id
            item.submenu = submenu
            if submenu != nil {
                item.target = self
                item.action = #selector(self.menuCardNoOp(_:))
            }
            return item
        }

        if usesGPUSelection {
            // Selection is painted by AppKit/GPU, so the SwiftUI content is pinned to its normal
            // appearance via a `highlightState` that is never flipped; these rows skip hosting-view
            // recycling because the recycler is typed to `MenuCardItemHostingView`.
            let interactiveRegionStore = MenuCardInteractiveRegionStore()
            let wrapped = MenuCardSectionContainerView(
                highlightState: MenuCardHighlightState(),
                showsSubmenuIndicator: submenu != nil,
                submenuIndicatorAlignment: submenuIndicatorAlignment,
                submenuIndicatorTopPadding: submenuIndicatorTopPadding,
                refreshMonitor: self.menuCardRefreshMonitor,
                interactiveRegionStore: interactiveRegionStore)
            {
                view
            }
            let gpuHosting = GPUSelectionHostingView(
                rootView: wrapped,
                allowsMenuHighlight: allowsMenuHighlight,
                containsInteractiveControls: containsInteractiveControls,
                interactiveRegionStore: interactiveRegionStore,
                onClick: onClick)
            let gpuHeight = self.cachedMenuCardHeight(
                for: id,
                scope: heightCacheScope ?? id,
                width: width,
                fingerprint: heightCacheFingerprint)
            {
                self.menuCardHeight(for: gpuHosting, width: width)
            }
            gpuHosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: gpuHeight))
            return self.makeMenuCardNSMenuItem(
                hosting: gpuHosting,
                id: id,
                submenu: submenu,
                isEnabled: allowsMenuHighlight || containsInteractiveControls)
        }

        let hosting: MenuCardItemHostingView<MenuCardSectionContainerView<CardContent>>
        if let recycled = self.takeRecyclableMenuCardView(
            for: id,
            as: MenuCardItemHostingView<MenuCardSectionContainerView<CardContent>>.self)
        {
            let wrapped = MenuCardSectionContainerView(
                highlightState: recycled.highlightState,
                showsSubmenuIndicator: submenu != nil,
                submenuIndicatorAlignment: submenuIndicatorAlignment,
                submenuIndicatorTopPadding: submenuIndicatorTopPadding,
                refreshMonitor: self.menuCardRefreshMonitor,
                interactiveRegionStore: recycled.interactiveRegionStore)
            {
                view
            }
            recycled.prepareForReuse(
                rootView: wrapped,
                allowsMenuHighlight: allowsMenuHighlight,
                containsInteractiveControls: containsInteractiveControls,
                onClick: onClick)
            hosting = recycled
        } else {
            let highlightState = MenuCardHighlightState()
            let interactiveRegionStore = MenuCardInteractiveRegionStore()
            let wrapped = MenuCardSectionContainerView(
                highlightState: highlightState,
                showsSubmenuIndicator: submenu != nil,
                submenuIndicatorAlignment: submenuIndicatorAlignment,
                submenuIndicatorTopPadding: submenuIndicatorTopPadding,
                refreshMonitor: self.menuCardRefreshMonitor,
                interactiveRegionStore: interactiveRegionStore)
            {
                view
            }
            hosting = MenuCardItemHostingView(
                rootView: wrapped,
                highlightState: highlightState,
                allowsMenuHighlight: allowsMenuHighlight,
                containsInteractiveControls: containsInteractiveControls,
                interactiveRegionStore: interactiveRegionStore,
                onClick: onClick)
        }
        let height = self.cachedMenuCardHeight(
            for: id,
            scope: heightCacheScope ?? id,
            width: width,
            fingerprint: heightCacheFingerprint)
        {
            self.menuCardHeight(for: hosting, width: width)
        }
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        return self.makeMenuCardNSMenuItem(
            hosting: hosting,
            id: id,
            submenu: submenu,
            isEnabled: allowsMenuHighlight || containsInteractiveControls)
    }

    /// Wraps a measured hosting view in the `NSMenuItem` the menu installs, wiring submenu routing.
    private func makeMenuCardNSMenuItem(
        hosting: NSView,
        id: String,
        submenu: NSMenu?,
        isEnabled: Bool) -> NSMenuItem
    {
        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = isEnabled
        item.representedObject = id
        item.submenu = submenu
        if submenu != nil {
            item.target = self
            item.action = #selector(self.menuCardNoOp(_:))
        }
        return item
    }

    private func menuCardHeight(for view: NSView, width: CGFloat) -> CGFloat {
        let basePadding: CGFloat = 6
        let descenderSafety: CGFloat = 1

        if let measured = view as? MenuCardMeasuring {
            return max(1, ceil(measured.measuredHeight(width: width) + basePadding + descenderSafety))
        }

        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
        let fitted = view.fittingSize
        return max(1, ceil(fitted.height + basePadding + descenderSafety))
    }
}
