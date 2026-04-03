import AppKit
import CodexBarCore

enum CodexLocalProfilesMenuMarker {
    static let saveCurrentAction = "codexLocalProfiles.saveCurrentAction"
    static let switchRoot = "codexLocalProfiles.switchRoot"
    static let sectionSeparator = "codexLocalProfiles.sectionSeparator"
}

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
            saveItem.representedObject = CodexLocalProfilesMenuMarker.saveCurrentAction
            menu.addItem(saveItem)
        }

        let profilesItem = NSMenuItem(title: "Switch Local Profile", action: nil, keyEquivalent: "")
        profilesItem.representedObject = CodexLocalProfilesMenuMarker.switchRoot
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
        let separator = NSMenuItem.separator()
        separator.representedObject = CodexLocalProfilesMenuMarker.sectionSeparator
        menu.addItem(separator)
    }

    func removeCodexLocalProfilesMenuSectionIfPresent(from menu: NSMenu, startingAt minimumIndex: Int) {
        guard minimumIndex < menu.items.count else { return }
        let searchRange = minimumIndex..<menu.items.count
        guard let profilesIndex = searchRange.first(where: { index in
            (menu.items[index].representedObject as? String) == CodexLocalProfilesMenuMarker.switchRoot
        }) else {
            return
        }

        let separatorSearchStart = profilesIndex + 1
        guard separatorSearchStart < menu.items.count,
              let separatorIndex = (separatorSearchStart..<menu.items.count).first(where: { index in
                  (menu.items[index].representedObject as? String) == CodexLocalProfilesMenuMarker.sectionSeparator
              })
        else {
            return
        }

        let sectionStart = if profilesIndex > minimumIndex,
                              (menu.items[profilesIndex - 1].representedObject as? String) ==
                              CodexLocalProfilesMenuMarker.saveCurrentAction
        {
            profilesIndex - 1
        } else {
            profilesIndex
        }

        for index in stride(from: separatorIndex, through: sectionStart, by: -1) {
            menu.removeItem(at: index)
        }
    }
}
