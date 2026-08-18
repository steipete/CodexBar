import AppKit
import Testing
@testable import CodexBar

@MainActor
struct SettingsApplicationMenuTests {
    @Test
    func `leaves one Settings command unchanged`() {
        let fixture = self.makeMenu(settingsItemCount: 1)

        let result = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))

        #expect(result == .unchanged(isFallback: false))
        #expect(SettingsApplicationMenu.candidateCount(
            in: fixture.mainMenu,
            localizedTitle: "Settings...") == 1)
    }

    @Test
    func `repairs a Settings command with no action`() throws {
        let fixture = self.makeMenu(settingsItemCount: 1, configuresActions: false)

        let result = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))
        let item = try #require(fixture.applicationMenu.items.first { $0.title == "Settings..." })

        #expect(result == .repaired(previousCount: 1, installedFallback: true))
        #expect(item.target === fixture.target)
        #expect(item.action == #selector(MenuTarget.openSettings(_:)))
    }

    @Test
    func `repairs duplicate Settings commands to one direct route`() throws {
        let fixture = self.makeMenu(settingsItemCount: 2)

        let result = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))
        let item = try #require(fixture.applicationMenu.items.first { $0.title == "Settings..." })

        #expect(result == .repaired(previousCount: 2, installedFallback: false))
        #expect(SettingsApplicationMenu.candidateCount(
            in: fixture.mainMenu,
            localizedTitle: "Settings...") == 1)
        #expect(item.target === fixture.target)
        #expect(item.action == #selector(MenuTarget.openSettings(_:)))
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    @Test
    func `refreshes a Settings command after its localized title changes`() throws {
        let fixture = self.makeMenu(settingsItemCount: 1)

        let result = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Einstellungen...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))
        let item = try #require(fixture.applicationMenu.items.first { $0.keyEquivalent == "," })

        #expect(result == .repaired(previousCount: 1, installedFallback: true))
        #expect(item.title == "Einstellungen...")
        #expect(item.target === fixture.target)
    }

    @Test
    func `ignores matching commands outside the application menu`() {
        let fixture = self.makeMenu(settingsItemCount: 1)
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let nestedItem = NSMenuItem(title: "Nested Settings", action: nil, keyEquivalent: ",")
        fileMenu.addItem(nestedItem)
        fileItem.submenu = fileMenu
        fixture.mainMenu.addItem(fileItem)

        let result = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))

        #expect(result == .unchanged(isFallback: false))
        #expect(fileMenu.items.contains { $0 === nestedItem })
        #expect(SettingsApplicationMenu.candidateCount(
            in: fixture.mainMenu,
            localizedTitle: "Settings...") == 1)
    }

    @Test
    func `defers a missing Settings command without mutating the menu`() {
        let fixture = self.makeMenu(settingsItemCount: 0)

        let result = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))

        #expect(result == .retryNeeded)
        #expect(SettingsApplicationMenu.candidateCount(
            in: fixture.mainMenu,
            localizedTitle: "Settings...") == 0)
    }

    @Test
    func `accepts a native Settings command that appears before retry`() {
        let fixture = self.makeMenu(settingsItemCount: 0)
        let firstResult = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))
        fixture.applicationMenu.addItem(self.makeSettingsItem(target: fixture.target))

        let retryResult = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))

        #expect(firstResult == .retryNeeded)
        #expect(retryResult == .unchanged(isFallback: false))
        #expect(SettingsApplicationMenu.candidateCount(
            in: fixture.mainMenu,
            localizedTitle: "Settings...") == 1)
    }

    @Test
    func `installs a fallback after missing-item retries are exhausted`() throws {
        let fixture = self.makeMenu(settingsItemCount: 0)

        let result = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)),
            allowMissingItemRepair: true)
        let item = try #require(fixture.applicationMenu.items.first { $0.keyEquivalent == "," })

        #expect(result == .repaired(previousCount: 0, installedFallback: true))
        #expect(item.identifier == SettingsApplicationMenu.fallbackItemIdentifier)
    }

    @Test
    func `reports an installed fallback while waiting for the native command`() {
        let fixture = self.makeMenu(settingsItemCount: 0)
        _ = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)),
            allowMissingItemRepair: true)

        let result = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))

        #expect(result == .unchanged(isFallback: true))
    }

    @Test
    func `reports a missing application menu before candidate retries`() {
        let result = SettingsApplicationMenu.ensureSingleItem(
            in: NSMenu(),
            localizedTitle: "Settings...",
            target: MenuTarget(),
            action: #selector(MenuTarget.openSettings(_:)))

        #expect(result == .missingApplicationMenu)
    }

    @Test
    func `prefers a native command that appears after fallback repair`() throws {
        let fixture = self.makeMenu(settingsItemCount: 0)
        _ = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)),
            allowMissingItemRepair: true)
        let nativeItem = self.makeSettingsItem(target: fixture.target)
        fixture.applicationMenu.addItem(nativeItem)

        let result = SettingsApplicationMenu.ensureSingleItem(
            in: fixture.mainMenu,
            localizedTitle: "Settings...",
            target: fixture.target,
            action: #selector(MenuTarget.openSettings(_:)))

        #expect(result == .repaired(previousCount: 2, installedFallback: false))
        #expect(fixture.applicationMenu.items.contains { $0 === nativeItem })
        #expect(SettingsApplicationMenu.candidateCount(
            in: fixture.mainMenu,
            localizedTitle: "Settings...") == 1)
        let remainingItem = try #require(fixture.applicationMenu.items.first { $0.keyEquivalent == "," })
        #expect(remainingItem.identifier != SettingsApplicationMenu.fallbackItemIdentifier)
    }

    private func makeMenu(settingsItemCount: Int, configuresActions: Bool = true)
        -> (mainMenu: NSMenu, applicationMenu: NSMenu, target: MenuTarget)
    {
        let mainMenu = NSMenu()
        let target = MenuTarget()
        let applicationItem = NSMenuItem(title: "CodexBar", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "CodexBar")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        applicationMenu.addItem(NSMenuItem(title: "About CodexBar", action: nil, keyEquivalent: ""))
        applicationMenu.addItem(.separator())
        for _ in 0..<settingsItemCount {
            applicationMenu.addItem(self.makeSettingsItem(
                target: configuresActions ? target : nil,
                configuresAction: configuresActions))
        }
        return (mainMenu, applicationMenu, target)
    }

    private func makeSettingsItem(target: MenuTarget?, configuresAction: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(
            title: "Settings...",
            action: configuresAction ? #selector(MenuTarget.openSettings(_:)) : nil,
            keyEquivalent: ",")
        item.target = target
        return item
    }
}

@MainActor
private final class MenuTarget: NSObject {
    @objc func openSettings(_: Any?) {}
}
