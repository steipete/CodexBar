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
        if self.manualRefreshTask != nil {
            return true
        }

        if self.isMergedOverviewSelected(in: menu) {
            // Overview refresh is global, so its busy state must mirror the global manual-refresh gate.
            return self.store.isRefreshing || !self.store.refreshingProviders.isEmpty
        }
        if let provider = self.menuProvider(for: menu) {
            return self.store.isRefreshing || self.store.refreshingProviders.contains(provider)
        }
        return self.store.isRefreshing || !self.store.refreshingProviders.isEmpty
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
