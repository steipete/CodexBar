import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

private final class RefreshShortcutRecorder: StatusItemMenuPersistentActionDelegate {
    var refreshCount = 0

    func performPersistentRefreshAction() {
        self.refreshCount += 1
    }
}

@MainActor
@Suite(.serialized)
struct StatusMenuPersistentRefreshTests {
    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuPersistentRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    @Test
    func `refresh menu item is view backed so mouse activation keeps the menu open`() throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let refreshItem = try #require(menu.items.first { $0.title == "Refresh" })
        #expect(refreshItem.action == nil)
        #expect(refreshItem.target == nil)
        #expect(refreshItem.view != nil)
        #expect(refreshItem.keyEquivalent == "r")
        #expect(refreshItem.keyEquivalentModifierMask == [.command])
    }

    @Test
    func `status item menu intercepts refresh shortcut without native item selection`() throws {
        let menu = StatusItemMenu()
        let recorder = RefreshShortcutRecorder()
        menu.persistentActionDelegate = recorder
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "r",
            charactersIgnoringModifiers: "r",
            isARepeat: false,
            keyCode: 15))

        #expect(menu.performKeyEquivalent(with: event) == true)
        #expect(recorder.refreshCount == 1)
    }
}
