import AppKit

struct ManualRefreshViewportRestoreRequest {
    let generation: Int
    let menuInteractionGeneration: Int
    let switcherSelection: ProviderSwitcherSelection?
}

@MainActor
final class ManualRefreshViewportRestoreState {
    var deferredUntilRebuild: [ObjectIdentifier: ManualRefreshViewportRestoreRequest] = [:]
    #if DEBUG
    var testOperation: (@MainActor () async -> Void)?
    var testObserver: (@MainActor (NSMenu) -> Void)?
    var testScheduler: ((@escaping @MainActor () -> Void) -> Void)?
    #endif
}

extension StatusItemController {
    /// A user-initiated manual refresh reconciles the tracked menu in place, and the row
    /// geometry and AppKit scroll state it changes can leave the private menu viewport anchored
    /// mid-list with no way back to the top short of closing and reopening the menu. Arm a token
    /// before refreshing so a close and reopen cannot transfer the restore to a new tracking
    /// session. Background refreshes never enter this path and therefore never move the viewport.
    func armManualRefreshViewportRestoreRequests(
        originatingMenuID: ObjectIdentifier?,
        originatingMenuInteractionGeneration: Int?)
        -> [ObjectIdentifier: ManualRefreshViewportRestoreRequest]
    {
        let candidates: [(ObjectIdentifier, NSMenu)]
        if let originatingMenuID {
            guard let menu = self.openMenus[originatingMenuID] else { return [:] }
            candidates = [(originatingMenuID, menu)]
        } else {
            candidates = Array(self.openMenus)
        }

        var requests: [ObjectIdentifier: ManualRefreshViewportRestoreRequest] = [:]
        for (key, menu) in candidates where menu.supermenu == nil && !self.isHostedSubviewMenu(menu) {
            guard let menuInteractionGeneration = self.menuSession.menuInteractionGeneration(for: key) else { continue }
            if key == originatingMenuID,
               let originatingMenuInteractionGeneration,
               menuInteractionGeneration != originatingMenuInteractionGeneration
            {
                continue
            }
            self.manualRefreshViewportRestoreState.deferredUntilRebuild.removeValue(forKey: key)
            requests[key] = ManualRefreshViewportRestoreRequest(
                generation: self.menuSession.armViewportRestore(key),
                menuInteractionGeneration: menuInteractionGeneration,
                switcherSelection: self.viewportRestoreSwitcherSelection(for: menu))
        }
        return requests
    }

    /// A completed manual refresh updates live card content without rebuilding the tracked
    /// parent menu. Restore on AppKit's tracking run loop after that live layout settles. The
    /// exact token prevents an older completion from consuming a newer refresh or menu session.
    func scheduleCompletedManualRefreshViewportRestore(
        _ requests: [ObjectIdentifier: ManualRefreshViewportRestoreRequest])
    {
        for (key, request) in requests {
            guard self.isCurrentManualRefreshViewportRestoreContext(request, for: key) else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                continue
            }
            guard !self.hasPreparedForAppShutdown,
                  let menu = self.openMenus[key],
                  ObjectIdentifier(menu) == key,
                  menu.supermenu == nil,
                  !self.isHostedSubviewMenu(menu),
                  request.switcherSelection == self.viewportRestoreSwitcherSelection(for: menu),
                  self.menuNeedsRefresh(menu)
            else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                continue
            }
            guard !self.hasOpenNonHostedChildMenu() else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                continue
            }
            if self.hasOpenHostedSubviewMenu() ||
                self.parentMenuRebuildPendingAfterHostedSubviewClose ||
                self.openMenuRebuildRequests.tokens[key] != nil
            {
                self.manualRefreshViewportRestoreState.deferredUntilRebuild[key] = request
                continue
            }
            guard !self.hasMenuItemHighlightedForViewportRestore(in: menu) else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                continue
            }

            self.scheduleManualRefreshViewportRestore(request, for: menu)
        }
    }

    func scheduleDeferredManualRefreshViewportRestoreAfterRebuild(for menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        guard let request = self.manualRefreshViewportRestoreState.deferredUntilRebuild.removeValue(forKey: key)
        else { return }
        guard self.isCurrentManualRefreshViewportRestoreContext(request, for: key),
              !self.hasPreparedForAppShutdown,
              self.openMenus[key] === menu,
              !self.hasOpenNonHostedChildMenu(),
              !self.hasOpenHostedSubviewMenu(),
              !self.hasMenuItemHighlightedForViewportRestore(in: menu),
              request.switcherSelection == self.viewportRestoreSwitcherSelection(for: menu)
        else {
            self.cancelManualRefreshViewportRestoreRequest(request, for: key)
            return
        }
        self.scheduleManualRefreshViewportRestore(request, for: menu)
    }

    private func scheduleManualRefreshViewportRestore(
        _ request: ManualRefreshViewportRestoreRequest,
        for menu: NSMenu)
    {
        let key = ObjectIdentifier(menu)
        let operation: @MainActor () -> Void = { [weak self, weak menu] in
            guard let self else { return }
            guard self.isCurrentManualRefreshViewportRestoreContext(request, for: key) else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                return
            }
            guard !self.hasPreparedForAppShutdown,
                  let menu,
                  self.openMenus[key] === menu,
                  request.switcherSelection == self.viewportRestoreSwitcherSelection(for: menu)
            else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                return
            }
            guard !self.hasOpenNonHostedChildMenu() else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                return
            }
            let menuIsDirty = self.menuNeedsRefresh(menu)
            let parentRebuildPending = self.openMenuRebuildRequests.tokens[key] != nil ||
                (self.parentMenuRebuildPendingAfterHostedSubviewClose && menuIsDirty)
            if self.hasOpenHostedSubviewMenu() {
                guard menuIsDirty || parentRebuildPending else {
                    self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                    return
                }
                self.manualRefreshViewportRestoreState.deferredUntilRebuild[key] = request
                return
            }
            if parentRebuildPending {
                self.manualRefreshViewportRestoreState.deferredUntilRebuild[key] = request
                return
            }
            guard !self.hasMenuItemHighlightedForViewportRestore(in: menu) else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                return
            }
            guard self.menuSession.consumeViewportRestore(key, generation: request.generation) else { return }
            self.restoreMenuViewportToTop(menu)
        }
        #if DEBUG
        if let scheduler = self._test_menuViewportRestoreScheduler {
            scheduler(operation)
        } else {
            ProviderSwitcherTrackingRunLoopScheduler.schedule(operation)
        }
        #else
        ProviderSwitcherTrackingRunLoopScheduler.schedule(operation)
        #endif
    }

    func cancelManualRefreshViewportRestore(for key: ObjectIdentifier) {
        self.manualRefreshViewportRestoreState.deferredUntilRebuild.removeValue(forKey: key)
        self.menuSession.cancelViewportRestore(key)
    }

    private func cancelManualRefreshViewportRestoreRequest(
        _ request: ManualRefreshViewportRestoreRequest,
        for key: ObjectIdentifier)
    {
        if self.manualRefreshViewportRestoreState.deferredUntilRebuild[key]?.generation == request.generation {
            self.manualRefreshViewportRestoreState.deferredUntilRebuild.removeValue(forKey: key)
        }
        self.menuSession.consumeViewportRestore(key, generation: request.generation)
    }

    func cancelManualRefreshViewportRestoreRequests(
        _ requests: [ObjectIdentifier: ManualRefreshViewportRestoreRequest])
    {
        for (key, request) in requests {
            self.cancelManualRefreshViewportRestoreRequest(request, for: key)
        }
    }

    private func viewportRestoreSwitcherSelection(for menu: NSMenu) -> ProviderSwitcherSelection? {
        guard self.shouldMergeIcons, menu === self.mergedMenu else { return nil }
        if self.isMergedOverviewSelected(in: menu) {
            return .overview
        }
        return .provider(self.resolvedMenuProvider() ?? .codex)
    }

    private func isCurrentManualRefreshViewportRestoreContext(
        _ request: ManualRefreshViewportRestoreRequest,
        for key: ObjectIdentifier)
        -> Bool
    {
        self.menuSession.isCurrentViewportRestore(request.generation, for: key) &&
            self.menuSession.isCurrentMenuInteraction(request.menuInteractionGeneration, for: key)
    }

    private func hasMenuItemHighlightedForViewportRestore(in menu: NSMenu) -> Bool {
        let key = ObjectIdentifier(menu)
        guard let item = self.highlightedMenuItems[key], item.menu === menu else { return false }
        return item.isEnabled
    }

    func advanceMenuContentSelection(for menu: NSMenu?) {
        guard let menu else { return }
        let key = ObjectIdentifier(menu)
        guard self.openMenus[key] === menu,
              let generation = self.menuSession.advanceMenuInteraction(for: key)
        else { return }
        (menu as? StatusItemMenu)?.menuInteractionGeneration = generation
    }

    func restoreMenuViewportToTop(_ menu: NSMenu) {
        #if DEBUG
        if let observer = self._test_menuViewportRestoreObserver {
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
