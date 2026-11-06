import AppKit

extension StatusItemController {
    /// Updates persistent Refresh rows in place while their menus are tracking.
    func updatePersistentRefreshItemsEnabled() {
        for item in self.persistentRefreshItems.allObjects {
            guard self.isPersistentRefreshItem(item) else {
                self.persistentRefreshItems.remove(item)
                continue
            }
            guard let menu = item.menu else { continue }
            let enabled = !self.isRefreshActionInFlight(for: menu)
            if !enabled, self.highlightedMenuItems[ObjectIdentifier(menu)] === item {
                (item.view as? MenuCardHighlighting)?.setHighlighted(false)
                self.highlightedMenuItems.removeValue(forKey: ObjectIdentifier(menu))
            }
            item.isEnabled = enabled
            (item.view as? PersistentRefreshMenuView)?.setEnabled(enabled)
        }
    }

    func isRefreshActionInFlight(for menu: NSMenu) -> Bool {
        if self.store.hasForcedRefreshEnrichmentInFlight || self.store.isRefreshing {
            return true
        }

        // An all-providers manual refresh (⌘R / overview) legitimately busies every row.
        if self.manualRefreshTasks[.global] != nil {
            return true
        }

        guard !self.manualRefreshTasks.isEmpty || !self.store.refreshingProviders.isEmpty else {
            return false
        }
        if self.isMergedOverviewSelected(in: menu) {
            // Overview stands for every provider, so it is busy while ANY manual refresh runs —
            // including the post-fetch tail of a per-provider refresh, after `refreshingProviders`
            // has cleared but its `.provider` task is still finishing status/token/credits work.
            return true
        }
        guard let provider = self.manualRefreshProvider(for: menu) else { return true }
        // A manual refresh of a different provider must not grey out this provider's row: only
        // reflect this provider's own manual refresh and its store refresh.
        return self.manualRefreshTasks[.provider(provider)] != nil
            || self.store.refreshingProviders.contains(provider)
    }

    func isMergedOverviewSelected(in menu: NSMenu) -> Bool {
        guard self.shouldMergeIcons else { return false }
        if let mergedMenu = self.mergedMenu, menu !== mergedMenu { return false }
        let providers = self.store.enabledFirstPartyProvidersForDisplay()
        return self.includesOverviewTab(enabledProviders: providers) &&
            self.settings.mergedMenuLastSelectedWasOverview
    }
}
