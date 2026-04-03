import AppKit
import CodexBarCore

@MainActor
extension StatusItemController {
    func addCodexLocalProfilesMenuIfNeeded(to menu: NSMenu, provider: UsageProvider) {
        guard provider == .codex else { return }

        let state = CodexLocalProfilesSectionState(
            presentation: self.codexLocalProfileManager.presentation())

        if state.showsSaveCurrentProfileButton {
            let saveItem = NSMenuItem(
                title: "Save Current Account…",
                action: #selector(self.saveCurrentCodexProfileFromMenu(_:)),
                keyEquivalent: "")
            saveItem.target = self
            menu.addItem(saveItem)
        }

        let profilesItem = NSMenuItem(title: "Switch Local Profile", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        if state.menuProfiles.isEmpty {
            let emptyItem = NSMenuItem(title: state.menuEmptyStateTitle, action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for profile in state.menuProfiles {
                let item = NSMenuItem(
                    title: profile.title,
                    action: #selector(self.switchLocalCodexProfileFromMenu(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = profile.representedPath
                item.state = profile.isActive ? .on : .off
                item.isEnabled = !profile.isActive
                submenu.addItem(item)
            }
        }

        submenu.addItem(.separator())

        let reloadItem = NSMenuItem(
            title: "Reload Profiles",
            action: #selector(self.reloadCodexLocalProfilesFromMenu(_:)),
            keyEquivalent: "")
        reloadItem.target = self
        submenu.addItem(reloadItem)

        let openItem = NSMenuItem(
            title: "Open Profiles Folder",
            action: #selector(self.openCodexLocalProfilesFolderFromMenu(_:)),
            keyEquivalent: "")
        openItem.target = self
        submenu.addItem(openItem)

        profilesItem.submenu = submenu
        menu.addItem(profilesItem)
        menu.addItem(.separator())
    }
}
