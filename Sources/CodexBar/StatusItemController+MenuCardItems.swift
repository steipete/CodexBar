import AppKit
import SwiftUI

enum MenuCardItemSizing {
    static let baseHeightPadding: CGFloat = 6
    static let descenderSafety: CGFloat = 1

    static var measuredHeightPadding: CGFloat {
        self.baseHeightPadding + self.descenderSafety
    }
}

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

    func makeMenuCardItem(
        _ view: some View,
        id: String,
        width: CGFloat,
        heightCacheScope: String? = nil,
        heightCacheFingerprint: String? = nil,
        submenu: NSMenu? = nil,
        showsSubmenuIndicator: Bool = true,
        submenuIndicatorAlignment: Alignment = .topTrailing,
        submenuIndicatorTopPadding: CGFloat = 8,
        containsInteractiveControls: Bool = false,
        usesGPUSelection: Bool = false,
        layoutDirection: LayoutDirection? = nil,
        accessibilityLabel: String? = nil,
        accessibilityUserInputLabels: [String]? = nil,
        accessibilityHelp: String? = nil,
        onClick: (() -> Void)? = nil) -> NSMenuItem
    {
        let allowsMenuHighlight = submenu != nil || onClick != nil
        if !self.menuCardRenderingEnabledForController {
            let item = NSMenuItem()
            item.title = ""
            item.isEnabled = allowsMenuHighlight
            item.representedObject = id
            item.submenu = submenu
            if submenu != nil {
                item.target = self
                item.action = #selector(self.menuCardNoOp(_:))
            }
            return item
        }

        // Content is erased so every row shares one outer AppKit class. Tab switches can replant
        // standard and GPU-selection payloads in place instead of detaching `item.view`.
        let payload = MenuCardRowPayload(
            content: AnyView(view),
            showsSubmenuIndicator: showsSubmenuIndicator && submenu != nil,
            submenuIndicatorAlignment: submenuIndicatorAlignment,
            submenuIndicatorTopPadding: submenuIndicatorTopPadding,
            allowsMenuHighlight: allowsMenuHighlight,
            containsInteractiveControls: containsInteractiveControls,
            usesGPUSelection: usesGPUSelection,
            layoutDirection: layoutDirection,
            accessibilityLabel: accessibilityLabel,
            accessibilityUserInputLabels: accessibilityUserInputLabels,
            accessibilityHelp: accessibilityHelp,
            onClick: onClick)
        let hosting: ErasedMenuCardHostingView
        if let recycled = self.takeRecyclableMenuCardView(
            for: id,
            as: ErasedMenuCardHostingView.self)
        {
            self.replantMenuCardRowPayload(payload, into: recycled)
            hosting = recycled
        } else {
            hosting = MenuRowContainerView(
                payload: payload,
                refreshMonitor: self.menuCardRefreshMonitor)
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
        // NSMenuItem()'s default title is the literal string "NSMenuItem"; Tahoe's
        // NSMenu paints that fallback title for frames where a row's view is
        // detached mid-mutation. Keep the fallback render blank instead.
        item.title = ""
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
        if let measured = view as? MenuCardMeasuring {
            return max(1, ceil(measured.measuredHeight(width: width) + MenuCardItemSizing.measuredHeightPadding))
        }

        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
        let fitted = view.fittingSize
        return max(1, ceil(fitted.height + MenuCardItemSizing.measuredHeightPadding))
    }
}
