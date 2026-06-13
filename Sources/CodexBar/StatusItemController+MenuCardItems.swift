import AppKit
import SwiftUI

// === PHASE C: LAYOUT ENGINE — MEASUREMENT PIPELINE ===
// All measurement, height caching, and frame commit happens here. A-phase render
// layer must not call any of the functions in this file.

extension StatusItemController {
    func refreshMenuCardHeights(in menu: NSMenu) {
        let width = self.renderedMenuWidth(for: menu)
        for item in menu.items {
            guard let view = item.view, view is any MenuCardMeasuring else { continue }
            guard abs(view.frame.width - width) > 0.5 else { continue }
            let id = item.representedObject as? String ?? "menuCard"
            let providerState = self.menuProvider(for: menu)?.rawValue ?? id
            let height = self.cachedMenuCardHeight(for: id, providerState: providerState, width: width) {
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
        onClick: (() -> Void)? = nil) -> NSMenuItem
    {
        if !Self.menuCardRenderingEnabled {
            let item = NSMenuItem()
            item.isEnabled = true
            item.representedObject = id
            item.submenu = submenu
            if submenu != nil {
                item.target = self
                item.action = #selector(self.menuCardNoOp(_:))
            }
            return item
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
                refreshMonitor: self.menuCardRefreshMonitor)
            {
                view
            }
            recycled.prepareForReuse(rootView: wrapped, onClick: onClick)
            hosting = recycled
        } else {
            let highlightState = MenuCardHighlightState()
            let wrapped = MenuCardSectionContainerView(
                highlightState: highlightState,
                showsSubmenuIndicator: submenu != nil,
                submenuIndicatorAlignment: submenuIndicatorAlignment,
                submenuIndicatorTopPadding: submenuIndicatorTopPadding,
                refreshMonitor: self.menuCardRefreshMonitor)
            {
                view
            }
            hosting = MenuCardItemHostingView(rootView: wrapped, highlightState: highlightState, onClick: onClick)
        }
        let height = self.cachedMenuCardHeight(
            for: id,
            providerState: heightCacheScope ?? id,
            width: width,
            contentFingerprint: heightCacheFingerprint)
        {
            self.menuCardHeight(for: hosting, width: width)
        }
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))

        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = true
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
