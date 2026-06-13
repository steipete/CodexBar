import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `status menu follows current system appearance when created and opened`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let expectedAppearance = StatusItemController.systemMenuAppearanceName(
            interfaceStyle: UserDefaults.standard.string(forKey: "AppleInterfaceStyle"),
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let menu = controller.makeMenu()
        #expect(menu.appearance?.name == expectedAppearance)

        let isDark = expectedAppearance == .darkAqua || expectedAppearance == .accessibilityHighContrastDarkAqua
        let staleAppearance: NSAppearance.Name = isDark ? .aqua : .darkAqua
        menu.appearance = NSAppearance(named: staleAppearance)
        let submenu = NSMenu()
        submenu.appearance = NSAppearance(named: staleAppearance)
        let submenuItem = NSMenuItem()
        submenuItem.submenu = submenu
        menu.addItem(submenuItem)
        controller.menuWillOpen(menu)
        #expect(menu.appearance?.name == expectedAppearance)
        #expect(submenu.appearance?.name == expectedAppearance)
        controller.menuDidClose(menu)
    }

    @Test
    func `system menu appearance follows global interface style and contrast`() {
        #expect(StatusItemController.systemMenuAppearanceName(
            interfaceStyle: nil,
            increaseContrast: false) == .aqua)
        #expect(StatusItemController.systemMenuAppearanceName(
            interfaceStyle: "Dark",
            increaseContrast: false) == .darkAqua)
        #expect(StatusItemController.systemMenuAppearanceName(
            interfaceStyle: nil,
            increaseContrast: true) == .accessibilityHighContrastAqua)
        #expect(StatusItemController.systemMenuAppearanceName(
            interfaceStyle: "dark",
            increaseContrast: true) == .accessibilityHighContrastDarkAqua)
    }
}
