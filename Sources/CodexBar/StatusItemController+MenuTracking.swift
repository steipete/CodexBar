import AppKit
import CodexBarCore

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

    func shouldRefreshOpenMenusForTokenCostHistoryArrival() -> Bool {
        let previousPresence = self.lastObservedTokenCostHistoryPresence
        let currentPresence = self.tokenCostHistoryPresenceByProvider()
        self.lastObservedTokenCostHistoryPresence = currentPresence

        guard Self.menuRefreshEnabled else { return false }
        guard !self.openMenus.isEmpty else { return false }

        let visibleProviders = self.openParentMenuProviders()
        guard !visibleProviders.isEmpty else { return false }

        return visibleProviders.contains { provider in
            previousPresence[provider] != true && currentPresence[provider] == true
        }
    }

    func tokenCostHistoryPresenceByProvider() -> [UsageProvider: Bool] {
        Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map { provider in
            let hasHistory = self.settings.isCostUsageEffectivelyEnabled(for: provider) &&
                (self.store.tokenSnapshot(for: provider)?.daily.isEmpty == false)
            return (provider, hasHistory)
        })
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

    private func openParentMenuProviders() -> Set<UsageProvider> {
        var providers: Set<UsageProvider> = []
        for menu in self.openMenus.values where !self.isHostedSubviewMenu(menu) {
            if self.shouldMergeIcons, self.lastMergedSwitcherSelection == .overview {
                providers.formUnion(self.store.enabledProvidersForDisplay())
            } else if let provider = self.menuProvider(for: menu) {
                providers.insert(provider)
            } else {
                providers.formUnion(self.store.enabledProvidersForDisplay())
            }
        }
        return providers
    }
}
