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

    private func refreshOpenMenusIfNeeded(allowsParentRebuild: Bool) {
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
                hasOpenHostedSubviewMenu: hasOpenHostedSubviewMenu)
        }
        self.removeOrphanedOpenMenuEntries(orphanedKeys)
    }

    private func refreshOpenMenuIfNeeded(
        _ menu: NSMenu,
        allowsParentRebuild: Bool,
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
        self.scheduleOpenMenuRebuildIfStillVisible(menu, provider: provider)
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
