import AppKit
import CodexBarCore

extension StatusItemController {
    private static let defaultClosedMenuPreparationDelay: Duration = .milliseconds(350)

    var isMenuRefreshEnabled: Bool {
        #if DEBUG
        if let menuRefreshEnabledOverrideForTesting {
            return menuRefreshEnabledOverrideForTesting
        }
        #endif
        return self.menuRefreshEnabledForController
    }

    #if DEBUG
    private static var closedMenuPreparationDelayForTesting: Duration = defaultClosedMenuPreparationDelay
    static func setClosedMenuPreparationDelayForTesting(_ delay: Duration) {
        self.closedMenuPreparationDelayForTesting = delay
    }

    static func resetClosedMenuPreparationDelayForTesting() {
        self.closedMenuPreparationDelayForTesting = self.defaultClosedMenuPreparationDelay
    }
    #endif

    private static var closedMenuPreparationDelay: Duration {
        #if DEBUG
        closedMenuPreparationDelayForTesting
        #else
        defaultClosedMenuPreparationDelay
        #endif
    }

    func invalidateMenus(
        refreshOpenMenus: Bool = false,
        deferOpenParentMenuRebuild: Bool = false,
        allowStaleContentDuringDataRefresh: Bool = false)
    {
        #if DEBUG
        guard !self.isReleasedForTesting else { return }
        #endif
        let preservesMergedSwitcherContentCaches = self.preservesMergedSwitcherContentCachesDuringInvalidation
        self.menuSession.invalidate(
            allowsStaleContent: allowStaleContentDuringDataRefresh,
            requiresRebuild: !preservesMergedSwitcherContentCaches)
        if !preservesMergedSwitcherContentCaches {
            self.clearMergedSwitcherContentCaches()
        }
        self.pruneVersionScopedMenuCardHeightCache()
        guard self.isMenuRefreshEnabled else { return }
        if !self.openMenus.isEmpty {
            guard refreshOpenMenus else { return }
            self.refreshOpenMenusAllowingParentRebuild(
                deferParentRebuildDuringTracking: deferOpenParentMenuRebuild)
            self.scheduleOpenMenuInvalidationRetry(
                deferParentRebuildDuringTracking: deferOpenParentMenuRebuild)
            return
        }
        if allowStaleContentDuringDataRefresh {
            if !self.cancelNonRequiredClosedMenuPreparation() {
                self.prepareAttachedClosedMenusIfNeeded()
            }
            return
        }
        self.prepareAttachedClosedMenusIfNeeded()
    }

    @discardableResult
    private func cancelNonRequiredClosedMenuPreparation() -> Bool {
        let menus = self.attachedMenusForClosedPreparation()
        let menuIDs = menus.map(ObjectIdentifier.init)
        guard !self.menuSession.hasRequiredClosedPreparation(for: menuIDs) else { return false }
        self.cancelAllClosedMenuRebuilds()
        for menuID in menuIDs {
            self.menuSession.clearNextOpenDeferral(menuID)
        }
        return true
    }

    func prepareAttachedClosedMenusIfNeeded() {
        guard self.isMenuRefreshEnabled else { return }
        guard self.openMenus.isEmpty else { return }
        guard !self.isMenuDataRefreshInFlight else { return }
        let menus = self.attachedMenusForClosedPreparation()
        let preparationPlan = self.menuSession.closedPreparationPlan(
            for: menus.lazy.map(ObjectIdentifier.init))
        guard preparationPlan != .none else { return }
        for menu in menus {
            let key = ObjectIdentifier(menu)
            switch preparationPlan {
            case .none:
                return
            case .nonDeferred:
                guard !self.menuSession.isDeferredUntilNextOpen(key) else { continue }
            case let .required(requiredVersion):
                self.menuSession.clearNextOpenDeferral(key)
                guard self.menuSession.isRenderedVersion(key, olderThan: requiredVersion) else { continue }
            }
            // Pre-warming the merged menu while it is closed runs a full main-thread populateMenu
            // (incl. SwiftUI hosting-view layout) that menuWillOpen redoes synchronously on display
            // anyway. In Merge Icons mode it is the only attached menu, so this just relocates that
            // work into a background freeze on every store tick (#1274). Defer it until next open.
            if menu === self.mergedMenu {
                self.menuSession.deferUntilNextOpen(key)
                continue
            }
            self.rebuildClosedMenuIfNeeded(menu)
        }
    }

    var isMenuDataRefreshInFlight: Bool {
        self.store.isRefreshing ||
            !self.manualRefreshTasks.isEmpty ||
            !self.store.refreshingProviders.isEmpty ||
            UsageProvider.allCases.contains { self.store.isTokenRefreshInFlight(for: $0) }
    }

    func removeMenuTrackingState(_ key: ObjectIdentifier) {
        self.menuProviders.removeValue(forKey: key)
        self.menuSession.removeMenu(key)
        self.menuReadinessSignatures.removeValue(forKey: key)
        self.menuIdentitySignatures.removeValue(forKey: key)
    }

    func cancelMenuWork(_ key: ObjectIdentifier) {
        self.menuRefreshTasks.removeValue(forKey: key)?.cancel()
        self.closedMenuRebuildTasks.removeValue(forKey: key)?.cancel()
        self.closedMenuRebuildRequests.cancel(for: key)
        self.openMenuRebuildTasks.removeValue(forKey: key)?.cancel()
        self.openMenuRebuildRequests.cancel(for: key)
        self.openMenuRebuildsClosingHostedSubviewMenus.remove(key)
    }

    func clearMenuHighlight(_ key: ObjectIdentifier) {
        if let highlightedView = self.highlightedMenuItems.removeValue(forKey: key)?.view {
            (highlightedView as? MenuCardHighlighting)?.setHighlighted(false)
        }
    }

    func removeMenuLifecycleState(_ key: ObjectIdentifier) {
        self.openMenus.removeValue(forKey: key)
        self.cancelMenuWork(key)
        self.clearMenuHighlight(key)
        self.removeMenuTrackingState(key)
    }

    func handleClosedPersistentMenuNeedingRefresh(_ menu: NSMenu) {
        if menu === self.mergedMenu {
            // Closing the merged menu is on the user's dismiss path. Leave stale content attached and let
            // menuWillOpen rebuild it, while other closed-menu invalidations can still prepare in the background.
            self.menuSession.deferUntilNextOpen(ObjectIdentifier(menu))
        } else {
            self.rebuildClosedMenuIfNeeded(menu)
        }
    }

    func refreshMenuForOpenIfNeeded(_ menu: NSMenu, provider: UsageProvider?) {
        self.menuSession.clearNextOpenDeferral(ObjectIdentifier(menu))
        guard self.menuNeedsRefresh(menu) else { return }
        if self.canPreserveStaleMenuContentForInstantOpen(menu) {
            #if DEBUG
            self.menuLogger.debug(
                "menu open kept existing content for instant render",
                metadata: [
                    "items": "\(menu.items.count)",
                    "provider": provider?.rawValue ?? "nil",
                    "storeRefreshing": self.store.isRefreshing ? "1" : "0",
                ])
            #endif
            if self.isMenuRefreshEnabled, !self.isMenuDataRefreshInFlight {
                self.scheduleOpenMenuRebuildIfStillVisible(
                    menu,
                    provider: provider,
                    resyncReadinessBaselineAfterRebuild: self.openMenus.isEmpty)
            }
            return
        }
        self.populateMenu(menu, provider: provider)
        self.markMenuFresh(menu)
    }

    private func canPreserveStaleMenuContentForInstantOpen(_ menu: NSMenu) -> Bool {
        guard !menu.items.isEmpty else { return false }
        let key = ObjectIdentifier(menu)
        return self.menuSession.canPreserveStaleContent(for: key) &&
            self.menuIdentitySignatures[key] == self.menuIdentitySignature(
                for: self.renderedProviders(for: menu))
    }

    private func attachedMenusForClosedPreparation() -> [NSMenu] {
        var menus: [NSMenu] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ menu: NSMenu?) {
            guard let menu else { return }
            let key = ObjectIdentifier(menu)
            guard seen.insert(key).inserted else { return }
            menus.append(menu)
        }

        append(self.statusItem.menu)
        append(self.mergedMenu)
        append(self.fallbackMenu)
        for item in self.statusItems.values {
            append(item.menu)
        }
        for menu in self.providerMenus.values {
            append(menu)
        }
        return menus
    }

    func renderedMenuWidth(for menu: NSMenu) -> CGFloat {
        let menuKey = ObjectIdentifier(menu)
        let trackedWindowWidth: CGFloat? = if self.openMenus[menuKey] != nil {
            menu.items.lazy.compactMap { item -> CGFloat? in
                guard let window = item.view?.window else { return nil }
                let contentWidth = window.contentLayoutRect.width
                return contentWidth > 0 ? contentWidth : window.frame.width
            }.first
        } else {
            nil
        }
        return Self.resolvedRenderedMenuWidth(
            menuWidth: menu.size.width,
            trackedWindowWidth: trackedWindowWidth)
    }

    static func resolvedRenderedMenuWidth(
        menuWidth: CGFloat,
        trackedWindowWidth: CGFloat?) -> CGFloat
    {
        max(
            ceil(menuWidth),
            ceil(trackedWindowWidth ?? 0),
            menuCardBaseWidth)
    }

    func rebuildClosedMenuIfNeeded(_ menu: NSMenu) {
        guard !self.hasPreparedForAppShutdown else { return }
        guard !self.isMenuDataRefreshInFlight else { return }
        let key = ObjectIdentifier(menu)
        let provider = self.menuProvider(for: menu)
        let rebuildToken = self.closedMenuRebuildRequests.replaceRequest(for: key)
        self.closedMenuRebuildTasks[key]?.cancel()
        self.closedMenuRebuildTasks[key] = Task { @MainActor [weak self, weak menu] in
            let delay = Self.closedMenuPreparationDelay
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            guard let self else { return }
            defer {
                if self.closedMenuRebuildRequests.finish(rebuildToken, for: key) {
                    self.closedMenuRebuildTasks.removeValue(forKey: key)
                }
            }
            guard let menu else { return }
            guard self.closedMenuRebuildRequests.isCurrent(rebuildToken, for: key) else { return }
            guard !self.hasPreparedForAppShutdown else { return }
            guard !self.isMenuDataRefreshInFlight else { return }
            // A delayed prewarm for one menu must never populate while another menu is tracking.
            guard self.openMenus.isEmpty else { return }
            guard self.menuNeedsRefresh(menu) else { return }
            self.populateMenu(menu, provider: provider)
            self.markMenuFresh(menu)
            #if DEBUG
            if self.lastLoggedClosedMenuRebuildVersion != self.menuSession.contentVersion {
                self.lastLoggedClosedMenuRebuildVersion = self.menuSession.contentVersion
                self.menuLogger.debug(
                    "closed menu rebuild completed",
                    metadata: [
                        "items": "\(menu.items.count)",
                        "provider": provider?.rawValue ?? "nil",
                    ])
            }
            #endif
        }
    }

    func cancelClosedMenuRebuild(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        self.closedMenuRebuildTasks.removeValue(forKey: key)?.cancel()
        self.closedMenuRebuildRequests.cancel(for: key)
    }

    func cancelAllClosedMenuRebuilds() {
        for task in self.closedMenuRebuildTasks.values {
            task.cancel()
        }
        self.closedMenuRebuildTasks.removeAll(keepingCapacity: false)
        self.closedMenuRebuildRequests.cancelAll()
    }

    func menuNeedsRefresh(_ menu: NSMenu) -> Bool {
        self.menuSession.needsRefresh(ObjectIdentifier(menu))
    }

    func markMenuFresh(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        self.menuSession.markFresh(key)
        self.menuReadinessSignatures[key] = self.menuAdjunctReadinessSignature()
        self.menuIdentitySignatures[key] = self.menuIdentitySignature(
            for: self.renderedProviders(for: menu))
    }

    private func menuIdentitySignature(for providers: [UsageProvider]) -> String {
        var parts: [String] = []
        for target in providers {
            parts.append(target.rawValue)
            parts.append(self.providerIdentitySignature(self.store.snapshot(for: target)?.identity(for: target)))

            if target != .codex, self.store.metadata(for: target).usesAccountFallback {
                let account = self.store.accountInfo(for: target)
                parts.append(Self.menuIdentityField(account.email))
                parts.append(Self.menuIdentityField(account.plan))
            }

            for accountSnapshot in self.store.accountSnapshots[target] ?? [] {
                parts.append(accountSnapshot.account.id.uuidString)
                parts.append(Self.menuIdentityField(accountSnapshot.account.label))
                parts.append(self.providerIdentitySignature(accountSnapshot.snapshot?.identity(for: target)))
            }

            if target == .codex {
                parts.append(Self.menuIdentityField(self.account.email))
                parts.append(Self.menuIdentityField(self.account.plan))
                for account in self.settings.codexVisibleAccountProjectionForMenuDisplay?.visibleAccounts ?? [] {
                    parts.append(Self.menuIdentityField(account.id))
                    parts.append(Self.menuIdentityField(account.email))
                    parts.append(Self.menuIdentityField(account.workspaceLabel))
                    parts.append(account.isActive ? "active" : "inactive")
                    parts.append(account.isLive ? "live" : "stored")
                }
                for accountSnapshot in self.store.codexAccountSnapshots {
                    parts.append(Self.menuIdentityField(accountSnapshot.id))
                    parts.append(self.providerIdentitySignature(accountSnapshot.snapshot?.identity(for: target)))
                }
            }

            if target == .kilo {
                for scopeSnapshot in self.store.kiloScopeSnapshots {
                    parts.append(Self.menuIdentityField(scopeSnapshot.id))
                    parts.append(self.providerIdentitySignature(scopeSnapshot.snapshot?.identity(for: target)))
                }
            }

            if target == .claude {
                parts.append(Self.menuIdentityField(self.store.claudeSwapLastError ?? ""))
                for accountSnapshot in self.store.claudeSwapAccountSnapshots {
                    parts.append(Self.menuIdentityField(accountSnapshot.id.opaqueID))
                    parts.append(accountSnapshot.isActive ? "active" : "inactive")
                    parts.append(self.providerIdentitySignature(accountSnapshot.snapshot?.identity(for: target)))
                }
            }
        }
        return parts.joined(separator: "|")
    }

    private func providerIdentitySignature(_ identity: ProviderIdentitySnapshot?) -> String {
        [
            identity?.providerID?.rawValue ?? "",
            Self.menuIdentityField(identity?.accountEmail),
            Self.menuIdentityField(identity?.accountOrganization),
            Self.menuIdentityField(identity?.loginMethod),
        ].joined(separator: ":")
    }

    private static func menuIdentityField(_ value: String?) -> String {
        let value = value ?? ""
        return "\(value.utf8.count):\(value)"
    }

    func hasOpenHostedSubviewMenu() -> Bool {
        self.openMenus.values.contains { self.isHostedSubviewMenu($0) }
    }

    func refreshOpenMenuIfStillVisible(_ menu: NSMenu, provider: UsageProvider?) {
        let key = ObjectIdentifier(menu)
        guard self.openMenus[key] != nil else { return }
        if self.isHostedSubviewMenu(menu) {
            self.scheduleOpenMenuRebuildIfStillVisible(menu, provider: provider)
            return
        }
        self.invalidateMenus(
            refreshOpenMenus: true,
            deferOpenParentMenuRebuild: true,
            allowStaleContentDuringDataRefresh: true)
    }

    func rebuildOpenMenuIfStillVisible(_ menu: NSMenu, provider: UsageProvider?) {
        let key = ObjectIdentifier(menu)
        guard self.openMenus[key] != nil else { return }
        guard self.isHostedSubviewMenu(menu) || !self.hasOpenHostedSubviewMenu() else { return }
        self.populateMenu(menu, provider: provider)
        self.markMenuFresh(menu)
        self.menuSession.clearParentRebuildDeferral(key)
        self.applyIcon(phase: nil)
        #if DEBUG
        self._test_openMenuRebuildObserver?(menu)
        #endif
    }

    func refreshOpenMenusIfNeeded() {
        guard self.isMenuRefreshEnabled else { return }
        guard !self.openMenus.isEmpty else { return }
        self.refreshOpenMenusIfNeeded(allowsParentRebuild: false)
    }

    func refreshOpenMenusForStructureChange() {
        self.refreshOpenMenusAllowingParentRebuild()
    }

    func refreshOpenMenusAfterHostedSubviewClose() {
        guard self.isMenuRefreshEnabled else { return }
        guard !self.openMenus.isEmpty else { return }
        if self.isMenuDataRefreshInFlight {
            self.parentMenuRebuildPendingAfterHostedSubviewClose = true
            return
        }
        self.parentMenuRebuildPendingAfterHostedSubviewClose = false
        self.refreshOpenMenusIfNeeded(allowsParentRebuild: true)
    }

    func completeParentMenuRebuildAfterHostedSubviewCloseIfNeeded() {
        guard self.parentMenuRebuildPendingAfterHostedSubviewClose else { return }
        guard !self.isMenuDataRefreshInFlight else { return }
        guard !self.hasOpenHostedSubviewMenu() else { return }
        self.refreshOpenMenusAfterHostedSubviewClose()
    }

    func refreshOpenMenusAllowingParentRebuild(deferParentRebuildDuringTracking: Bool = false) {
        guard self.isMenuRefreshEnabled else { return }
        guard !self.openMenus.isEmpty else { return }
        self.refreshOpenMenusIfNeeded(
            allowsParentRebuild: true,
            deferParentRebuildDuringTracking: deferParentRebuildDuringTracking)
    }

    func scheduleOpenMenuInvalidationRetry(deferParentRebuildDuringTracking: Bool = false) {
        self.openMenuInvalidationRetryTask?.cancel()
        self.openMenuInvalidationRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            #if DEBUG
            self.onOpenMenuInvalidationRetryForTesting?()
            #endif
            self.refreshOpenMenusAllowingParentRebuild(
                deferParentRebuildDuringTracking: deferParentRebuildDuringTracking)
            self.openMenuInvalidationRetryTask = nil
        }
    }

    private func refreshOpenMenusIfNeeded(
        allowsParentRebuild: Bool,
        deferParentRebuildDuringTracking: Bool = false,
        respectsParentRebuildDeferral: Bool = false)
    {
        var orphanedKeys: [ObjectIdentifier] = []
        let hasOpenHostedSubviewMenu = self.hasOpenHostedSubviewMenu()
        for (key, menu) in self.openMenus {
            guard key == ObjectIdentifier(menu) else {
                orphanedKeys.append(key)
                continue
            }
            self.refreshOpenMenuIfNeeded(
                menu,
                allowsParentRebuild: allowsParentRebuild,
                deferParentRebuildDuringTracking: deferParentRebuildDuringTracking,
                respectsParentRebuildDeferral: respectsParentRebuildDeferral,
                hasOpenHostedSubviewMenu: hasOpenHostedSubviewMenu)
        }
        self.removeOrphanedOpenMenuEntries(orphanedKeys)
    }

    private func refreshOpenMenuIfNeeded(
        _ menu: NSMenu,
        allowsParentRebuild: Bool,
        deferParentRebuildDuringTracking: Bool,
        respectsParentRebuildDeferral: Bool,
        hasOpenHostedSubviewMenu: Bool)
    {
        if self.isHostedSubviewMenu(menu) {
            self.refreshHostedSubviewMenu(menu)
            return
        }
        guard allowsParentRebuild else { return }
        guard self.menuNeedsRefresh(menu) else { return }
        let key = ObjectIdentifier(menu)

        if deferParentRebuildDuringTracking {
            self.menuSession.deferParentRebuild(key)
            return
        }
        if respectsParentRebuildDeferral, self.menuSession.isParentRebuildDeferred(key) {
            return
        }
        self.menuSession.clearParentRebuildDeferral(key)
        guard !hasOpenHostedSubviewMenu else { return }

        let provider = self.menuProvider(for: menu)
        self.scheduleOpenMenuRebuildIfStillVisible(menu, provider: provider)
    }

    private func removeOrphanedOpenMenuEntries(_ keys: [ObjectIdentifier]) {
        for key in keys {
            self.removeMenuLifecycleState(key)
        }
    }
}
