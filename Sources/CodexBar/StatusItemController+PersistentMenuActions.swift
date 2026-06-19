import AppKit

extension StatusItemController {
    func usesPersistentMenuActionItem(for action: MenuDescriptor.MenuAction) -> Bool {
        switch action {
        case .installUpdate, .refresh, .settings, .about, .quit:
            true
        default:
            false
        }
    }

    func persistentMenuActionSystemImageName(for action: MenuDescriptor.MenuAction) -> String? {
        switch action {
        case .installUpdate:
            "arrow.down.circle"
        case .refresh:
            MenuDescriptor.MenuActionSystemImage.refresh.rawValue
        case .settings:
            MenuDescriptor.MenuActionSystemImage.settings.rawValue
        case .about:
            MenuDescriptor.MenuActionSystemImage.about.rawValue
        case .quit:
            MenuDescriptor.MenuActionSystemImage.quit.rawValue
        default:
            action.systemImageName
        }
    }

    func performPersistentMenuAction(_ action: MenuDescriptor.MenuAction, in menu: NSMenu?) {
        switch action {
        case .refresh:
            self.refreshMenuProviderNow(in: menu)
        case .installUpdate:
            self.closeMenuForPersistentAction(menu)
            self.installUpdate()
        case .settings:
            self.closeMenuForPersistentAction(menu)
            self.showSettingsGeneral()
        case .about:
            self.closeMenuForPersistentAction(menu)
            self.showSettingsAbout()
        case .quit:
            self.closeMenuForPersistentAction(menu)
            self.quit()
        default:
            break
        }
    }

    /// Syncs every live persistent Refresh row's static progress state to the refresh lifecycle. This is
    /// an in-place AppKit mutation on the existing row views — it never rebuilds the menu, so it
    /// is safe to call during NSMenu tracking.
    func updatePersistentRefreshRowsInProgress() {
        for row in self.persistentRefreshRows.allObjects {
            guard let menu = row.enclosingMenuItem?.menu else {
                row.setInProgress(self.manualRefreshTask != nil || self.store.isRefreshing)
                continue
            }
            row.setInProgress(self.isRefreshActionInFlight(for: menu))
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

    private func closeMenuForPersistentAction(_ menu: NSMenu?) {
        guard let menu else { return }
        menu.cancelTrackingWithoutAnimation()
        self.forgetClosedMenu(menu)
    }
}
