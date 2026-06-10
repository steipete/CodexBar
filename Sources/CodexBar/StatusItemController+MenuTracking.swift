import AppKit
import CodexBarCore

extension StatusItemController {
    private static let defaultClosedMenuPreparationDelay: Duration = .milliseconds(350)

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
        self.menuContentVersion &+= 1
        let preservesMergedSwitcherContentCaches = self.preservesMergedSwitcherContentCachesDuringInvalidation
        if !preservesMergedSwitcherContentCaches {
            self.clearMergedSwitcherContentCaches()
        }
        self.pruneVersionScopedMenuCardHeightCache()
        if !allowStaleContentDuringDataRefresh, !preservesMergedSwitcherContentCaches {
            self.latestRequiredMenuRebuildVersion = self.menuContentVersion
        }
        guard self.isMenuRefreshEnabled else { return }
        if !self.openMenus.isEmpty {
            guard refreshOpenMenus else { return }
            self.refreshOpenMenusAllowingParentRebuild(
                deferParentRebuildDuringTracking: deferOpenParentMenuRebuild)
            self.scheduleOpenMenuInvalidationRetry(
                deferParentRebuildDuringTracking: deferOpenParentMenuRebuild)
            return
        }
        self.prepareAttachedClosedMenusIfNeeded()
    }

    func prepareAttachedClosedMenusIfNeeded() {
        guard self.isMenuRefreshEnabled else { return }
        guard self.openMenus.isEmpty else { return }
        guard !self.isMenuDataRefreshInFlight else { return }
        let menus = self.attachedMenusForClosedPreparation()
        let requiredClosedPreparationVersion: Int?
        if self.menuContentVersion > self.latestRequiredMenuRebuildVersion {
            guard self.latestRequiredMenuRebuildVersion > 0 else { return }
            let hasRequiredClosedMenu = menus.contains { menu in
                let key = ObjectIdentifier(menu)
                return (self.menuVersions[key] ?? -1) < self.latestRequiredMenuRebuildVersion
            }
            guard hasRequiredClosedMenu else { return }
            requiredClosedPreparationVersion = self.latestRequiredMenuRebuildVersion
        } else {
            requiredClosedPreparationVersion = nil
        }
        for menu in menus {
            let key = ObjectIdentifier(menu)
            guard !self.closedMenusDeferredUntilNextOpen.contains(key) else { continue }
            if let requiredClosedPreparationVersion {
                guard (self.menuVersions[key] ?? -1) < requiredClosedPreparationVersion else { continue }
            }
            // Pre-warming the merged menu while it is closed runs a full main-thread populateMenu
            // (incl. SwiftUI hosting-view layout) that menuWillOpen redoes synchronously on display
            // anyway. In Merge Icons mode it is the only attached menu, so this just relocates that
            // work into a background freeze on every store tick (#1274). Defer it until next open.
            if menu === self.mergedMenu {
                self.closedMenusDeferredUntilNextOpen.insert(key)
                continue
            }
            self.rebuildClosedMenuIfNeeded(menu)
        }
    }

    var isMenuDataRefreshInFlight: Bool {
        self.store.isRefreshing ||
            UsageProvider.allCases.contains { self.store.isTokenRefreshInFlight(for: $0) }
    }

    func clearTransientMenuTrackingState(_ key: ObjectIdentifier) {
        self.menuProviders.removeValue(forKey: key)
        self.menuVersions.removeValue(forKey: key)
        self.menuReadinessSignatures.removeValue(forKey: key)
        self.closedMenusDeferredUntilNextOpen.remove(key)
    }

    func handleClosedPersistentMenuNeedingRefresh(_ menu: NSMenu) {
        if menu === self.mergedMenu {
            // Closing the merged menu is on the user's dismiss path. Leave stale content attached and let
            // menuWillOpen rebuild it, while other closed-menu invalidations can still prepare in the background.
            self.closedMenusDeferredUntilNextOpen.insert(ObjectIdentifier(menu))
        } else {
            self.rebuildClosedMenuIfNeeded(menu)
        }
    }

    func refreshMenuForOpenIfNeeded(_ menu: NSMenu, provider: UsageProvider?) {
        self.closedMenusDeferredUntilNextOpen.remove(ObjectIdentifier(menu))
        guard self.menuNeedsRefresh(menu) else { return }
        if self.canPreserveStaleMenuContentDuringRefresh(menu) {
            #if DEBUG
            self.menuLogger.debug(
                "menu open kept existing content during refresh",
                metadata: [
                    "items": "\(menu.items.count)",
                    "provider": provider?.rawValue ?? "nil",
                    "storeRefreshing": self.store.isRefreshing ? "1" : "0",
                ])
            #endif
            self.deferMenuInteractionRefreshIfNeeded()
            return
        }
        self.populateMenu(menu, provider: provider)
        self.markMenuFresh(menu)
    }

    private func canPreserveStaleMenuContentDuringRefresh(_ menu: NSMenu) -> Bool {
        guard self.isMenuDataRefreshInFlight, !menu.items.isEmpty else { return false }
        let key = ObjectIdentifier(menu)
        guard let menuVersion = self.menuVersions[key] else { return false }
        return menuVersion >= self.latestRequiredMenuRebuildVersion
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
        let measuredWidth = ceil(menu.size.width)
        return max(measuredWidth, Self.menuCardBaseWidth)
    }

    func rebuildClosedMenuIfNeeded(_ menu: NSMenu) {
        guard !self.hasPreparedForAppShutdown else { return }
        guard !self.isMenuDataRefreshInFlight else { return }
        let key = ObjectIdentifier(menu)
        let provider = self.menuProvider(for: menu)
        self.closedMenuRebuildTokenCounter &+= 1
        let rebuildToken = self.closedMenuRebuildTokenCounter
        self.closedMenuRebuildTokens[key] = rebuildToken
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
                if self.closedMenuRebuildTokens[key] == rebuildToken {
                    self.closedMenuRebuildTasks.removeValue(forKey: key)
                    self.closedMenuRebuildTokens.removeValue(forKey: key)
                }
            }
            guard let menu else { return }
            guard self.closedMenuRebuildTokens[key] == rebuildToken else { return }
            guard !self.hasPreparedForAppShutdown else { return }
            guard !self.isMenuDataRefreshInFlight else { return }
            guard self.openMenus[ObjectIdentifier(menu)] == nil else { return }
            guard self.menuNeedsRefresh(menu) else { return }
            self.populateMenu(menu, provider: provider)
            self.markMenuFresh(menu)
            #if DEBUG
            if self.lastLoggedClosedMenuRebuildVersion != self.menuContentVersion {
                self.lastLoggedClosedMenuRebuildVersion = self.menuContentVersion
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
        self.closedMenuRebuildTokens.removeValue(forKey: key)
    }

    func cancelAllClosedMenuRebuilds() {
        for task in self.closedMenuRebuildTasks.values {
            task.cancel()
        }
        self.closedMenuRebuildTasks.removeAll(keepingCapacity: false)
        self.closedMenuRebuildTokens.removeAll(keepingCapacity: false)
    }

    func menuNeedsRefresh(_ menu: NSMenu) -> Bool {
        let key = ObjectIdentifier(menu)
        return self.menuVersions[key] != self.menuContentVersion
    }

    func markMenuFresh(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        self.menuVersions[key] = self.menuContentVersion
        self.menuReadinessSignatures[key] = self.menuAdjunctReadinessSignature()
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
        self.parentMenuRebuildsDeferredDuringTracking.remove(key)
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
        self.refreshOpenMenusIfNeeded(
            allowsParentRebuild: true,
            respectsParentRebuildDeferral: true)
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
            self.parentMenuRebuildsDeferredDuringTracking.insert(key)
            return
        }
        if respectsParentRebuildDeferral, self.parentMenuRebuildsDeferredDuringTracking.contains(key) {
            return
        }
        self.parentMenuRebuildsDeferredDuringTracking.remove(key)
        guard !hasOpenHostedSubviewMenu else { return }

        let provider = self.menuProvider(for: menu)
        self.scheduleOpenMenuRebuildIfStillVisible(menu, provider: provider)
    }

    private func removeOrphanedOpenMenuEntries(_ keys: [ObjectIdentifier]) {
        for key in keys {
            self.openMenus.removeValue(forKey: key)
            self.menuRefreshTasks.removeValue(forKey: key)?.cancel()
            self.menuProviders.removeValue(forKey: key)
            self.menuVersions.removeValue(forKey: key)
            self.parentMenuRebuildsDeferredDuringTracking.remove(key)
        }
    }
}
