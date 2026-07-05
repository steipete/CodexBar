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
            item.isEnabled = enabled
            (item.view as? PersistentRefreshMenuView)?.setEnabled(enabled)
        }
    }

    func isRefreshActionInFlight(for menu: NSMenu) -> Bool {
        // An all-providers manual refresh (⌘R / overview) legitimately busies every row.
        if self.manualRefreshTasks[.global] != nil {
            return true
        }

        if self.isMergedOverviewSelected(in: menu) {
            // Overview stands for every provider, so it is busy while ANY manual refresh runs —
            // including the post-fetch tail of a per-provider refresh, after `refreshingProviders`
            // has cleared but its `.provider` task is still finishing status/token/credits work.
            return self.store.isRefreshing
                || !self.manualRefreshTasks.isEmpty
                || !self.store.refreshingProviders.isEmpty
        }
        if let provider = self.menuProvider(for: menu) {
            // A manual refresh of a different provider must not grey out this provider's row: only
            // reflect the global refresh, this provider's own manual refresh, and its store refresh.
            return self.store.isRefreshing
                || self.manualRefreshTasks[.provider(provider)] != nil
                || self.store.refreshingProviders.contains(provider)
        }
        return self.store.isRefreshing
            || !self.manualRefreshTasks.isEmpty
            || !self.store.refreshingProviders.isEmpty
    }

    func isMergedOverviewSelected(in menu: NSMenu) -> Bool {
        guard self.shouldMergeIcons else { return false }
        if let mergedMenu = self.mergedMenu, menu !== mergedMenu { return false }
        let providers = self.settings.resolvedMergedOverviewProviders(
            activeProviders: self.store.enabledProvidersForDisplay(),
            maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit)
        return !providers.isEmpty && self.settings.mergedMenuLastSelectedWasOverview
    }
}
