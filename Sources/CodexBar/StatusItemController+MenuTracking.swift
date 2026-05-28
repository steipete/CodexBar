import AppKit

extension StatusItemController {
    func renderedMenuWidth(for menu: NSMenu) -> CGFloat {
        let measuredWidth = ceil(menu.size.width)
        return max(measuredWidth, Self.menuCardBaseWidth)
    }

    func refreshOpenMenusIfNeeded() {
        guard Self.menuRefreshEnabled else { return }
        guard !self.openMenus.isEmpty else { return }
        self.refreshOpenMenusIfNeeded(allowsParentRebuild: false)
    }

    func refreshOpenMenusForStructureChange() {
        self.refreshOpenMenusAllowingParentRebuild()
    }

    func refreshOpenMenusAllowingParentRebuild() {
        guard Self.menuRefreshEnabled else { return }
        guard !self.openMenus.isEmpty else { return }
        self.refreshOpenMenusIfNeeded(allowsParentRebuild: true)
    }

    func refreshOpenMenusForTokenCostHydration() {
        guard Self.menuRefreshEnabled else { return }
        guard !self.openMenus.isEmpty else { return }
        self.refreshOpenMenusIfNeeded(allowsParentRebuild: true, allowsTrackedParentSmartUpdate: true)
    }

    private func refreshOpenMenusIfNeeded(
        allowsParentRebuild: Bool,
        allowsTrackedParentSmartUpdate: Bool = false)
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
                allowsTrackedParentSmartUpdate: allowsTrackedParentSmartUpdate,
                hasOpenHostedSubviewMenu: hasOpenHostedSubviewMenu)
        }
        self.removeOrphanedOpenMenuEntries(orphanedKeys)
    }

    private func refreshOpenMenuIfNeeded(
        _ menu: NSMenu,
        allowsParentRebuild: Bool,
        allowsTrackedParentSmartUpdate: Bool,
        hasOpenHostedSubviewMenu: Bool)
    {
        if self.isHostedSubviewMenu(menu) {
            self.refreshHostedSubviewHeights(in: menu)
            return
        }
        guard allowsParentRebuild else { return }
        guard !hasOpenHostedSubviewMenu else { return }
        guard self.menuNeedsRefresh(menu) else { return }

        let provider = self.menuProvider(for: menu)
        if allowsTrackedParentSmartUpdate {
            self.updateTrackedOpenParentMenuContentIfPossible(menu, provider: provider, reason: "tracked-menu-refresh")
            return
        }
        if self.deferOpenParentMenuMutationIfTracking(
            menu,
            provider: provider,
            reason: "tracked-menu-refresh")
        {
            return
        }
        self.populateMenu(menu, provider: provider)
        self.markMenuFresh(menu)
    }

    private func removeOrphanedOpenMenuEntries(_ keys: [ObjectIdentifier]) {
        for key in keys {
            self.openMenus.removeValue(forKey: key)
            self.menuRefreshTasks.removeValue(forKey: key)?.cancel()
            self.menuProviders.removeValue(forKey: key)
            self.menuVersions.removeValue(forKey: key)
        }
    }
}
