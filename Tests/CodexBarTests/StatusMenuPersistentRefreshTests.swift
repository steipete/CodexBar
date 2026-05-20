import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

private final class RefreshShortcutRecorder: StatusItemMenuPersistentActionDelegate {
    var refreshCount = 0
    var settingsCount = 0
    var quitCount = 0
    var navigationDirections: [StatusItemMenuProviderNavigationDirection] = []

    func performPersistentRefreshAction() {
        self.refreshCount += 1
    }

    func performPersistentSettingsAction() {
        self.settingsCount += 1
    }

    func performPersistentQuitAction() {
        self.quitCount += 1
    }

    func performProviderNavigation(_ direction: StatusItemMenuProviderNavigationDirection) {
        self.navigationDirections.append(direction)
    }
}

@MainActor
private final class UpdateReadyUpdater: UpdaterProviding {
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    let isAvailable = true
    let unavailableReason: String? = nil
    let updateStatus = UpdateStatus(isUpdateReady: true)

    func checkForUpdates(_: Any?) {}
    func installUpdate() {}
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

    private func makeController(
        settings: SettingsStore,
        updater: UpdaterProviding = DisabledUpdaterController()) -> StatusItemController
    {
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: updater,
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    @Test
    func `refresh menu item is view backed so mouse activation keeps the menu open`() throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)

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
    func `meta menu actions use the same stable row implementation`() throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings, updater: UpdateReadyUpdater())
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        for title in ["Update ready, restart now?", "Refresh", "Settings...", "About CodexBar", "Quit"] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.action == nil)
            #expect(item.target == nil)
            #expect(item.view is PersistentMenuActionItemView)
            #expect(item.view?.frame.height == PersistentMenuActionItemView.rowHeight)
        }
    }

    @Test
    func `refresh menu item view keeps fixed metrics while highlighted`() {
        let views = [
            PersistentMenuActionItemView(
                title: "Refresh",
                systemImageName: "arrow.clockwise",
                shortcutText: "⌘R",
                width: 320,
                onClick: {}),
            PersistentMenuActionItemView(
                title: "Settings...",
                systemImageName: "gearshape",
                shortcutText: "⌘,",
                width: 320,
                onClick: {}),
            PersistentMenuActionItemView(
                title: "About CodexBar",
                systemImageName: "info.circle",
                shortcutText: nil,
                width: 320,
                onClick: {}),
            PersistentMenuActionItemView(
                title: "Quit",
                systemImageName: nil,
                shortcutText: nil,
                width: 320,
                onClick: {}),
        ]

        for view in views {
            self.assertStableMetrics(view)
        }
    }

    private func assertStableMetrics(_ view: PersistentMenuActionItemView) {
        #expect(view.frame.height == PersistentMenuActionItemView.rowHeight)
        #expect(view.intrinsicContentSize.height == PersistentMenuActionItemView.rowHeight)
        #expect(view.fittingSize.height == PersistentMenuActionItemView.rowHeight)

        view.setFrameSize(NSSize(width: 360, height: 44))
        #expect(view.frame.width == 360)
        #expect(view.frame.height == PersistentMenuActionItemView.rowHeight)

        view.setHighlighted(true)
        #expect(view.frame.height == PersistentMenuActionItemView.rowHeight)
        #expect(view.intrinsicContentSize.height == PersistentMenuActionItemView.rowHeight)
        #expect(view.fittingSize.height == PersistentMenuActionItemView.rowHeight)

        view.setHighlighted(false)
        #expect(view.frame.height == PersistentMenuActionItemView.rowHeight)
        #expect(view.intrinsicContentSize.height == PersistentMenuActionItemView.rowHeight)
        #expect(view.fittingSize.height == PersistentMenuActionItemView.rowHeight)
    }

    @Test
    func `status item menu intercepts persistent shortcuts without native item selection`() throws {
        let menu = StatusItemMenu()
        let recorder = RefreshShortcutRecorder()
        menu.persistentActionDelegate = recorder

        #expect(try menu.performKeyEquivalent(with: self.keyEvent("r", keyCode: 15)) == true)
        #expect(try menu.performKeyEquivalent(with: self.keyEvent(",", keyCode: 43)) == true)
        #expect(try menu.performKeyEquivalent(with: self.keyEvent("q", keyCode: 12)) == true)

        #expect(recorder.refreshCount == 1)
        #expect(recorder.settingsCount == 1)
        #expect(recorder.quitCount == 1)
    }

    private func keyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode))
    }
}
