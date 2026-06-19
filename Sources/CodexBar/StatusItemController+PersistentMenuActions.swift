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
            self.refreshNow()
        case .installUpdate:
            self.closeMenuHierarchyForAction(menu)
            self.installUpdate()
        case .settings:
            self.closeMenuHierarchyForAction(menu)
            self.showSettingsGeneral()
        case .about:
            self.closeMenuHierarchyForAction(menu)
            self.showSettingsAbout()
        case .quit:
            self.closeMenuHierarchyForAction(menu)
            self.quit()
        default:
            break
        }
    }

    /// Syncs every live persistent Refresh row's spinner to the refresh lifecycle. This is
    /// an in-place AppKit mutation on the existing row views — it never rebuilds the menu, so it
    /// is safe to call during NSMenu tracking.
    func updatePersistentRefreshRowsInProgress() {
        let inProgress = self.manualRefreshTask != nil || self.store.isRefreshing
        for row in self.persistentRefreshRows.allObjects {
            row.setInProgress(inProgress)
        }
    }

    func closeMenuHierarchyForAction(_ menu: NSMenu?) {
        var menus: [NSMenu] = []
        var current = menu
        while let menu = current {
            menus.append(menu)
            current = menu.supermenu
        }

        for menu in menus {
            menu.cancelTrackingWithoutAnimation()
        }
        for menu in menus {
            self.forgetClosedMenu(menu)
        }
    }
}
