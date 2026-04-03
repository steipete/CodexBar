import AppKit
import CodexBarCore

@MainActor
extension StatusItemController {
    func addCodexLocalProfilesMenuIfNeeded(to menu: NSMenu, provider: UsageProvider) {
        guard provider == .codex else { return }

        let saveItem = NSMenuItem(
            title: "Save Current Account…",
            action: #selector(self.saveCurrentCodexProfileFromMenu(_:)),
            keyEquivalent: "")
        saveItem.target = self
        menu.addItem(saveItem)

        let profilesItem = NSMenuItem(title: "Switch Local Profile", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let profiles = self.codexLocalProfileManager.profiles().filter { $0.alias != "Live" }
        if profiles.isEmpty {
            let emptyItem = NSMenuItem(title: "No saved profiles yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for profile in profiles {
                let item = NSMenuItem(
                    title: "Switch to \(profile.alias)",
                    action: #selector(self.switchLocalCodexProfileFromMenu(_:)),
                    keyEquivalent: "")
                item.target = self
                item.representedObject = profile.fileURL.path
                item.state = profile.isActiveInCodex ? .on : .off
                item.isEnabled = !profile.isActiveInCodex
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
