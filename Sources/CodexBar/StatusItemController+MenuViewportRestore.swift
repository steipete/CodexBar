import AppKit

struct ManualRefreshViewportRestoreRequest {
    let generation: Int
    let menuInteractionGeneration: Int
    let switcherSelection: ProviderSwitcherSelection?
}

struct MenuViewportGeometry: Equatable {
    let documentID: ObjectIdentifier
    let clipID: ObjectIdentifier
    let documentSize: CGSize
    let documentIsFlipped: Bool
    let clipSize: CGSize
    let clipOrigin: CGPoint
}

enum MenuViewportGeometryTransition: Equatable {
    case unchanged
    case layout
    case movement
}

private struct MenuViewportOriginRange {
    private(set) var minimumX: CGFloat
    private(set) var maximumX: CGFloat
    private(set) var minimumY: CGFloat
    private(set) var maximumY: CGFloat

    init(baseline: CGPoint, current: CGPoint) {
        self.minimumX = min(baseline.x, current.x)
        self.maximumX = max(baseline.x, current.x)
        self.minimumY = min(baseline.y, current.y)
        self.maximumY = max(baseline.y, current.y)
    }

    mutating func include(_ origin: CGPoint) {
        self.minimumX = min(self.minimumX, origin.x)
        self.maximumX = max(self.maximumX, origin.x)
        self.minimumY = min(self.minimumY, origin.y)
        self.maximumY = max(self.maximumY, origin.y)
    }

    func exceeds(_ tolerance: CGFloat) -> Bool {
        self.maximumX - self.minimumX > tolerance || self.maximumY - self.minimumY > tolerance
    }
}

@MainActor
final class ManualRefreshViewportMovementTracker: NSObject {
    private weak var scrollView: NSScrollView?
    private weak var clipView: NSClipView?
    private weak var documentView: NSView?
    private let originalPostsBoundsChangedNotifications: Bool
    private let originalClipPostsFrameChangedNotifications: Bool
    private let originalDocumentPostsFrameChangedNotifications: Bool
    private var baselineGeometry: MenuViewportGeometry?
    private var pendingOriginRange: MenuViewportOriginRange?
    private var afterSettleOperations: [@MainActor () -> Void] = []
    private var settleScheduled = false
    private var permitsPostLayoutTopCorrection = false
    private var isActive = true
    private(set) var observedMovement = false

    init(scrollView: NSScrollView) {
        let clipView = scrollView.contentView
        let documentView = scrollView.documentView
        self.scrollView = scrollView
        self.clipView = clipView
        self.documentView = documentView
        self.originalPostsBoundsChangedNotifications = clipView.postsBoundsChangedNotifications
        self.originalClipPostsFrameChangedNotifications = clipView.postsFrameChangedNotifications
        self.originalDocumentPostsFrameChangedNotifications = documentView?.postsFrameChangedNotifications ?? false
        self.baselineGeometry = nil
        self.pendingOriginRange = nil
        super.init()
        clipView.postsBoundsChangedNotifications = true
        clipView.postsFrameChangedNotifications = true
        documentView?.postsFrameChangedNotifications = true
        self.baselineGeometry = StatusItemController.menuViewportGeometry(in: scrollView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.viewportGeometryDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.viewportGeometryDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: clipView)
        if let documentView {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.viewportGeometryDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: documentView)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func stop() {
        guard self.isActive else { return }
        self.isActive = false
        self.clipView?.postsBoundsChangedNotifications = self.originalPostsBoundsChangedNotifications
        self.clipView?.postsFrameChangedNotifications = self.originalClipPostsFrameChangedNotifications
        self.documentView?.postsFrameChangedNotifications = self.originalDocumentPostsFrameChangedNotifications
        self.settleScheduled = false
        self.permitsPostLayoutTopCorrection = false
        self.pendingOriginRange = nil
        self.afterSettleOperations.removeAll(keepingCapacity: false)
        self.documentView = nil
        self.clipView = nil
        self.scrollView = nil
    }

    func isTracking(_ scrollView: NSScrollView) -> Bool {
        self.scrollView === scrollView &&
            self.clipView === scrollView.contentView &&
            self.documentView === scrollView.documentView
    }

    /// Make settled refresh geometry the baseline for the short completion-to-delivery window.
    /// Callers must enter through `afterPendingGeometrySettles` so stale AppKit geometry is never sampled.
    func rebaseAfterRefreshLayout() {
        guard !self.observedMovement, let scrollView = self.scrollView else { return }
        self.baselineGeometry = StatusItemController.menuViewportGeometry(in: scrollView)
        self.pendingOriginRange = nil
    }

    func afterPendingGeometrySettles(_ operation: @escaping @MainActor () -> Void) {
        guard self.isActive else { return }
        guard self.settleScheduled else {
            operation()
            return
        }
        self.afterSettleOperations.append(operation)
    }

    func settlePendingGeometryChanges() {
        self.settleScheduled = false
        if self.isActive,
           !self.observedMovement,
           let scrollView = self.scrollView,
           let current = StatusItemController.menuViewportGeometry(in: scrollView)
        {
            if let baselineGeometry = self.baselineGeometry {
                let pendingMovement = self.pendingOriginRange?.exceeds(1) == true
                switch StatusItemController.menuViewportGeometryTransition(from: baselineGeometry, to: current) {
                case .unchanged:
                    if pendingMovement {
                        if self.consumePostLayoutTopCorrectionIfNeeded(current) {
                            self.baselineGeometry = current
                        } else {
                            self.observedMovement = true
                        }
                    }
                // Otherwise keep the original baseline so fractional scroll deltas accumulate.
                case .layout:
                    self.baselineGeometry = current
                    // AppKit can publish the new document frame one run-loop pass before its
                    // automatic reset to the menu's top. Only that no-op restore target is safe
                    // to absorb; an arbitrary next origin is newer user movement.
                    self.permitsPostLayoutTopCorrection = !pendingMovement
                case .movement:
                    if self.consumePostLayoutTopCorrectionIfNeeded(current) {
                        self.baselineGeometry = current
                    } else {
                        self.observedMovement = true
                    }
                }
            } else {
                self.baselineGeometry = current
            }
            self.pendingOriginRange = nil
        }
        let operations = self.afterSettleOperations
        self.afterSettleOperations.removeAll(keepingCapacity: false)
        for operation in operations where self.isActive {
            operation()
        }
    }

    private func consumePostLayoutTopCorrectionIfNeeded(_ geometry: MenuViewportGeometry) -> Bool {
        guard self.permitsPostLayoutTopCorrection else { return false }
        self.permitsPostLayoutTopCorrection = false
        return StatusItemController.menuViewportGeometryIsAtTop(geometry)
    }

    @objc private func viewportGeometryDidChange(_: Notification) {
        guard self.isActive, !self.observedMovement else { return }
        if let origin = self.scrollView?.contentView.bounds.origin {
            if self.pendingOriginRange == nil {
                self.pendingOriginRange = MenuViewportOriginRange(
                    baseline: self.baselineGeometry?.clipOrigin ?? origin,
                    current: origin)
            } else {
                self.pendingOriginRange?.include(origin)
            }
        }
        guard !self.settleScheduled else { return }
        self.settleScheduled = true
        ProviderSwitcherTrackingRunLoopScheduler.schedule { [weak self] in
            self?.settlePendingGeometryChanges()
        }
    }
}

private struct ManualRefreshViewportMovementTracking {
    let generation: Int
    let tracker: ManualRefreshViewportMovementTracker
}

@MainActor
final class ManualRefreshViewportRestoreState {
    var deferredUntilRebuild: [ObjectIdentifier: ManualRefreshViewportRestoreRequest] = [:]
    private var movementTrackers: [ObjectIdentifier: ManualRefreshViewportMovementTracking] = [:]

    func startMovementTracking(
        for key: ObjectIdentifier,
        generation: Int,
        scrollView: NSScrollView)
    {
        self.stopMovementTracking(for: key)
        self.movementTrackers[key] = ManualRefreshViewportMovementTracking(
            generation: generation,
            tracker: ManualRefreshViewportMovementTracker(scrollView: scrollView))
    }

    func prepareForCompletedRefreshLayout(
        for key: ObjectIdentifier,
        generation: Int,
        scrollView: NSScrollView,
        completion: @escaping @MainActor () -> Void)
    {
        self.prepareMovementTracking(
            for: key,
            generation: generation,
            scrollView: scrollView,
            rebaseAfterLayout: true,
            completion: completion)
    }

    func prepareForDelivery(
        for key: ObjectIdentifier,
        generation: Int,
        scrollView: NSScrollView,
        completion: @escaping @MainActor () -> Void)
    {
        self.prepareMovementTracking(
            for: key,
            generation: generation,
            scrollView: scrollView,
            rebaseAfterLayout: false,
            completion: completion)
    }

    func afterMovementSettles(
        for key: ObjectIdentifier,
        generation: Int,
        operation: @escaping @MainActor () -> Void)
    {
        guard let tracking = self.movementTrackers[key], tracking.generation == generation else {
            operation()
            return
        }
        let tracker = tracking.tracker
        tracker.afterPendingGeometrySettles { [weak self, weak tracker] in
            guard let self,
                  let tracker,
                  let current = self.movementTrackers[key],
                  current.generation == generation,
                  current.tracker === tracker
            else { return }
            operation()
        }
    }

    func observedMovement(for key: ObjectIdentifier, generation: Int) -> Bool {
        guard let tracking = self.movementTrackers[key], tracking.generation == generation else { return false }
        return tracking.tracker.observedMovement
    }

    func stopMovementTracking(for key: ObjectIdentifier, generation: Int? = nil) {
        guard let tracking = self.movementTrackers[key],
              generation == nil || tracking.generation == generation
        else { return }
        tracking.tracker.stop()
        self.movementTrackers.removeValue(forKey: key)
    }

    func stopAllMovementTracking() {
        for tracking in self.movementTrackers.values {
            tracking.tracker.stop()
        }
        self.movementTrackers.removeAll(keepingCapacity: false)
    }

    private func prepareMovementTracking(
        for key: ObjectIdentifier,
        generation: Int,
        scrollView: NSScrollView,
        rebaseAfterLayout: Bool,
        completion: @escaping @MainActor () -> Void)
    {
        guard let tracking = self.movementTrackers[key] else {
            self.startMovementTracking(for: key, generation: generation, scrollView: scrollView)
            completion()
            return
        }
        guard tracking.generation == generation else {
            // A newer overlapping provider refresh owns this menu's tracker. Let the caller's
            // context check discard the stale completion without erasing newer movement.
            completion()
            return
        }
        let tracker = tracking.tracker
        tracker.afterPendingGeometrySettles { [weak self, weak tracker] in
            guard let self,
                  let tracker,
                  let current = self.movementTrackers[key],
                  current.generation == generation,
                  current.tracker === tracker
            else { return }
            if !tracker.observedMovement {
                if tracker.isTracking(scrollView) {
                    if rebaseAfterLayout {
                        tracker.rebaseAfterRefreshLayout()
                    }
                } else {
                    self.startMovementTracking(for: key, generation: generation, scrollView: scrollView)
                }
            }
            completion()
        }
    }

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
            let generation = self.menuSession.armViewportRestore(key)
            if let scrollView = Self.attachedMenuScrollView(in: menu) {
                self.manualRefreshViewportRestoreState.startMovementTracking(
                    for: key,
                    generation: generation,
                    scrollView: scrollView)
            }
            requests[key] = ManualRefreshViewportRestoreRequest(
                generation: generation,
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
            guard self.isCurrentManualRefreshViewportRestoreContext(request, for: key),
                  let menu = self.openMenus[key]
            else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                continue
            }
            let completion: @MainActor () -> Void = { [weak self, weak menu] in
                guard let self else { return }
                guard let menu else {
                    self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                    return
                }
                self.continueSchedulingCompletedManualRefreshViewportRestore(
                    request,
                    for: key,
                    menu: menu)
            }
            if let scrollView = Self.attachedMenuScrollView(in: menu) {
                self.manualRefreshViewportRestoreState.prepareForCompletedRefreshLayout(
                    for: key,
                    generation: request.generation,
                    scrollView: scrollView,
                    completion: completion)
            } else {
                completion()
            }
        }
    }

    private func continueSchedulingCompletedManualRefreshViewportRestore(
        _ request: ManualRefreshViewportRestoreRequest,
        for key: ObjectIdentifier,
        menu: NSMenu)
    {
        guard self.isCurrentManualRefreshViewportRestoreContext(request, for: key),
              !self.hasPreparedForAppShutdown,
              self.openMenus[key] === menu,
              ObjectIdentifier(menu) == key,
              menu.supermenu == nil,
              !self.isHostedSubviewMenu(menu),
              request.switcherSelection == self.viewportRestoreSwitcherSelection(for: menu),
              self.menuNeedsRefresh(menu),
              !self.manualRefreshViewportRestoreState.observedMovement(
                  for: key,
                  generation: request.generation),
              !self.hasOpenNonHostedChildMenu()
        else {
            self.cancelManualRefreshViewportRestoreRequest(request, for: key)
            return
        }
        if self.hasOpenHostedSubviewMenu() ||
            self.parentMenuRebuildPendingAfterHostedSubviewClose ||
            self.openMenuRebuildRequests.tokens[key] != nil
        {
            self.manualRefreshViewportRestoreState.deferredUntilRebuild[key] = request
            return
        }
        guard !self.hasMenuItemHighlightedForViewportRestore(in: menu) else {
            self.cancelManualRefreshViewportRestoreRequest(request, for: key)
            return
        }
        self.scheduleManualRefreshViewportRestore(request, for: menu)
    }

    func scheduleDeferredManualRefreshViewportRestoreAfterRebuild(for menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        guard let request = self.manualRefreshViewportRestoreState.deferredUntilRebuild.removeValue(forKey: key)
        else { return }
        let completion: @MainActor () -> Void = { [weak self, weak menu] in
            guard let self else { return }
            guard let menu else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                return
            }
            self.continueSchedulingDeferredManualRefreshViewportRestore(
                request,
                for: key,
                menu: menu)
        }
        if let scrollView = Self.attachedMenuScrollView(in: menu) {
            self.manualRefreshViewportRestoreState.prepareForDelivery(
                for: key,
                generation: request.generation,
                scrollView: scrollView,
                completion: completion)
        } else {
            completion()
        }
    }

    private func continueSchedulingDeferredManualRefreshViewportRestore(
        _ request: ManualRefreshViewportRestoreRequest,
        for key: ObjectIdentifier,
        menu: NSMenu)
    {
        guard self.isCurrentManualRefreshViewportRestoreContext(request, for: key),
              !self.hasPreparedForAppShutdown,
              self.openMenus[key] === menu,
              !self.hasOpenNonHostedChildMenu(),
              !self.hasOpenHostedSubviewMenu(),
              !self.hasMenuItemHighlightedForViewportRestore(in: menu),
              !self.manualRefreshViewportRestoreState.observedMovement(
                  for: key,
                  generation: request.generation),
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
        let delivery: @MainActor () -> Void = { [weak self, weak menu] in
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
            guard !self.hasMenuItemHighlightedForViewportRestore(in: menu),
                  !self.manualRefreshViewportRestoreState.observedMovement(
                      for: key,
                      generation: request.generation)
            else {
                self.cancelManualRefreshViewportRestoreRequest(request, for: key)
                return
            }
            guard self.menuSession.consumeViewportRestore(key, generation: request.generation) else { return }
            self.manualRefreshViewportRestoreState.stopMovementTracking(
                for: key,
                generation: request.generation)
            self.restoreMenuViewportToTop(menu)
        }
        let operation: @MainActor () -> Void = { [weak self] in
            self?.manualRefreshViewportRestoreState.afterMovementSettles(
                for: key,
                generation: request.generation,
                operation: delivery)
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
        self.manualRefreshViewportRestoreState.stopMovementTracking(for: key)
        self.menuSession.cancelViewportRestore(key)
    }

    private func cancelManualRefreshViewportRestoreRequest(
        _ request: ManualRefreshViewportRestoreRequest,
        for key: ObjectIdentifier)
    {
        if self.manualRefreshViewportRestoreState.deferredUntilRebuild[key]?.generation == request.generation {
            self.manualRefreshViewportRestoreState.deferredUntilRebuild.removeValue(forKey: key)
        }
        self.manualRefreshViewportRestoreState.stopMovementTracking(
            for: key,
            generation: request.generation)
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

    func advanceMenuInteraction(for menu: NSMenu?) {
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

    static func menuViewportGeometry(in scrollView: NSScrollView) -> MenuViewportGeometry? {
        guard let documentView = scrollView.documentView else { return nil }
        let clipView = scrollView.contentView
        return MenuViewportGeometry(
            documentID: ObjectIdentifier(documentView),
            clipID: ObjectIdentifier(clipView),
            documentSize: documentView.frame.size,
            documentIsFlipped: documentView.isFlipped,
            clipSize: clipView.bounds.size,
            clipOrigin: clipView.bounds.origin)
    }

    /// Bounds notifications can arrive before AppKit exposes updated row geometry. Compare only
    /// coalesced, settled samples: any geometry change is layout; stable geometry exposes scrolling.
    static func menuViewportGeometryTransition(
        from previous: MenuViewportGeometry,
        to current: MenuViewportGeometry,
        movementTolerance: CGFloat = 1)
        -> MenuViewportGeometryTransition
    {
        // AppKit can publish an origin reset before exposing a row-size change. A mixed batch is
        // therefore irreducibly ambiguous: treat it as layout, then catch repeating edge-scroll
        // ticks against the new stable geometry on the next batch.
        guard previous.documentID == current.documentID,
              previous.clipID == current.clipID,
              previous.documentSize == current.documentSize,
              previous.documentIsFlipped == current.documentIsFlipped,
              previous.clipSize == current.clipSize
        else { return .layout }
        let moved = abs(current.clipOrigin.x - previous.clipOrigin.x) > movementTolerance ||
            abs(current.clipOrigin.y - previous.clipOrigin.y) > movementTolerance
        return moved ? .movement : .unchanged
    }

    static func menuViewportGeometryIsAtTop(
        _ geometry: MenuViewportGeometry,
        tolerance: CGFloat = 1)
        -> Bool
    {
        let maximumOffset = max(0, geometry.documentSize.height - geometry.clipSize.height)
        let topOffset = geometry.documentIsFlipped ? 0 : maximumOffset
        return abs(geometry.clipOrigin.y - topOffset) <= tolerance
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
