import AppKit
import CodexBarCore

extension StatusItemController {
    func invalidateMenus(
        refreshOpenMenus: Bool = false,
        deferOpenParentMenuRebuild: Bool = false)
    {
        #if DEBUG
        guard !self.isReleasedForTesting else { return }
        #endif
        self.menuContentVersion &+= 1
        guard self.isMenuRefreshEnabled else { return }
        if !self.openMenus.isEmpty {
            guard refreshOpenMenus else { return }
            self.refreshOpenMenusAllowingParentRebuild(
                deferParentRebuildDuringTracking: deferOpenParentMenuRebuild)
            self.scheduleOpenMenuInvalidationRetry(
                deferParentRebuildDuringTracking: deferOpenParentMenuRebuild)
            return
        }
    }

    func renderedMenuWidth(for menu: NSMenu) -> CGFloat {
        let measuredWidth = ceil(menu.size.width)
        return max(measuredWidth, Self.menuCardBaseWidth)
    }

    func rebuildClosedMenuIfNeeded(_ menu: NSMenu) {
        guard !self.hasPreparedForAppShutdown else { return }
        let provider = self.menuProvider(for: menu)
        Task { @MainActor [weak self, weak menu] in
            await Task.yield()
            guard let self, let menu else { return }
            guard !self.hasPreparedForAppShutdown else { return }
            guard self.openMenus[ObjectIdentifier(menu)] == nil else { return }
            guard self.menuNeedsRefresh(menu) else { return }
            self.populateMenu(menu, provider: provider)
            self.markMenuFresh(menu)
        }
    }

    func menuNeedsRefresh(_ menu: NSMenu) -> Bool {
        let key = ObjectIdentifier(menu)
        return self.menuVersions[key] != self.menuContentVersion
    }

    func markMenuFresh(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        self.menuVersions[key] = self.menuContentVersion
    }

    func hasOpenHostedSubviewMenu() -> Bool {
        self.openMenus.values.contains { self.isHostedSubviewMenu($0) }
    }

    func refreshOpenMenuIfStillVisible(_ menu: NSMenu, provider: UsageProvider?) {
        self.scheduleOpenMenuRebuildIfStillVisible(menu, provider: provider)
    }

    func rebuildOpenMenuIfStillVisible(_ menu: NSMenu, provider: UsageProvider?) {
        guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
        guard self.isHostedSubviewMenu(menu) || !self.hasOpenHostedSubviewMenu() else { return }
        self.populateMenu(menu, provider: provider)
        self.markMenuFresh(menu)
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
