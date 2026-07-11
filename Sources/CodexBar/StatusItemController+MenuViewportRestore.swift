import AppKit

extension StatusItemController {
    #if DEBUG
    static var _test_menuViewportRestoreObserver: (@MainActor (NSMenu) -> Void)?
    #endif

    /// A user-initiated manual refresh reconciles the tracked menu in place, and the row
    /// heights it changes (a recovered provider-error banner collapsing is the largest jump)
    /// can leave AppKit's private menu scrolling anchored mid-list with no way back to the
    /// top short of closing and reopening the menu. Arm a one-shot viewport restore for the
    /// open menus the refresh will rebuild; the restore runs when that rebuild lands.
    /// Background data ticks never arm this, so they cannot yank a viewport the user is
    /// reading.
    func armMenuViewportRestoreAfterManualRefresh() {
        for (key, menu) in self.openMenus {
            guard !self.isHostedSubviewMenu(menu) else { continue }
            guard self.menuNeedsRefresh(menu) else { continue }
            self.menuSession.armViewportRestore(key)
        }
    }

    /// Consumes a pending restore after `populateMenu` has reconciled the open menu. The
    /// scroll repair runs on the next main-actor turn so AppKit's own relayout of the
    /// table-backed menu settles first; the restore is a no-op when the menu is not
    /// scrolled or no longer open.
    func consumePendingMenuViewportRestore(for menu: NSMenu) {
        guard self.menuSession.consumeViewportRestore(ObjectIdentifier(menu)) else { return }
        Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
            self.restoreMenuViewportToTop(menu)
        }
    }

    func restoreMenuViewportToTop(_ menu: NSMenu) {
        #if DEBUG
        if let observer = Self._test_menuViewportRestoreObserver {
            observer(menu)
            return
        }
        #endif
        guard let scrollView = Self.attachedMenuScrollView(in: menu),
              let documentView = scrollView.documentView
        else { return }
        let clipView = scrollView.contentView
        guard let target = Self.menuViewportTopOffset(
            documentIsFlipped: documentView.isFlipped,
            documentHeight: documentView.frame.height,
            clipHeight: clipView.bounds.height,
            currentOffset: clipView.documentVisibleRect.origin.y)
        else { return }
        self.performMenuMutationWithoutAnimation {
            clipView.scroll(to: NSPoint(x: clipView.documentVisibleRect.origin.x, y: target))
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    /// The view-based menu (`NSMenuScrollView` → `NSClipView` → table representation)
    /// recycles row views once they scroll offscreen, so the shared scroll view must be
    /// resolved through whichever item view is currently attached to the menu window.
    static func attachedMenuScrollView(in menu: NSMenu) -> NSScrollView? {
        for item in menu.items {
            if let scrollView = item.view?.enclosingScrollView {
                return scrollView
            }
        }
        return nil
    }

    /// Returns the offset that shows the top of the menu content, or nil when the menu is
    /// not scrollable or the viewport is already there.
    static func menuViewportTopOffset(
        documentIsFlipped: Bool,
        documentHeight: CGFloat,
        clipHeight: CGFloat,
        currentOffset: CGFloat) -> CGFloat?
    {
        guard clipHeight > 0, documentHeight - clipHeight > 0.5 else { return nil }
        let top: CGFloat = documentIsFlipped ? 0 : documentHeight - clipHeight
        guard abs(currentOffset - top) > 0.5 else { return nil }
        return top
    }
}
