import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct PreferencesSelectionTests {
    @Test
    func `pane persistence tokens round-trip`() {
        let panes: [SettingsPane] = [
            .general,
            .iCloudSync,
            .usageSpend,
            .notifications,
            .menuBar,
            .menu,
            .advanced,
            .about,
            .debug,
            .provider(.claude),
        ]
        for pane in panes {
            #expect(SettingsPane(persistenceToken: pane.persistenceToken) == pane)
        }
        #expect(SettingsPane(persistenceToken: "provider:definitely-not-a-provider") == nil)
        #expect(SettingsPane(persistenceToken: "") == nil)
    }

    @Test
    func `legacy display token restores the menu bar pane`() {
        #expect(SettingsPane(persistenceToken: "display") == .menuBar)
    }

    @Test
    func `selection restores persisted pane and saves changes`() {
        let defaults = InMemoryUserDefaults()

        #expect(PreferencesSelection(userDefaults: defaults).pane == .general)

        let selection = PreferencesSelection(userDefaults: defaults)
        selection.pane = .provider(.codex)
        #expect(defaults.string(forKey: PreferencesSelection.paneDefaultsKey) == "provider:codex")
        let restored = PreferencesSelection(userDefaults: defaults)
        #expect(restored.pane == .provider(.codex))
        #expect(!restored.canGoBack)
        #expect(!restored.canGoForward)
    }
}
