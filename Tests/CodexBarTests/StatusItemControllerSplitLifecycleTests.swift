import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemControllerSplitLifecycleTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        .system
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusItemControllerSplitLifecycleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func containsHostingView(_ view: NSView) -> Bool {
        if String(describing: type(of: view)).contains("NSHostingView") {
            return true
        }
        return view.subviews.contains { self.containsHostingView($0) }
    }

    private func makeSplitController() throws -> (SettingsStore, StatusItemController) {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.providerDetectionCompleted = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            if let metadata = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: false)
            }
        }
        try settings.setProviderEnabled(provider: .codex, metadata: #require(registry.metadata[.codex]), enabled: true)
        try settings.setProviderEnabled(
            provider: .claude,
            metadata: #require(registry.metadata[.claude]),
            enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        return (settings, controller)
    }

    @Test
    func `merged mode removes split provider status items`() throws {
        let (settings, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.statusItems[.codex] != nil)
        #expect(controller.statusItems[.claude] != nil)

        settings.mergeIcons = true
        controller.handleProviderConfigChange(reason: "test")

        #expect(controller.statusItem.isVisible == true)
        #expect(controller.statusItems.isEmpty)
    }

    @Test
    func `menu bar icons stay appkit hosted`() throws {
        let (settings, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        let codexButton = try #require(controller.statusItems[.codex]?.button)
        #expect(codexButton.image != nil)
        #expect(!self.containsHostingView(codexButton))

        settings.mergeIcons = true
        controller.handleProviderConfigChange(reason: "test")

        let mergedButton = try #require(controller.statusItem.button)
        #expect(mergedButton.image != nil)
        #expect(!self.containsHostingView(mergedButton))
    }

    @Test
    func `status items publish stable non persistent manager identity`() throws {
        let (_, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        let codexButton = try #require(controller.statusItems[.codex]?.button)
        let claudeButton = try #require(controller.statusItems[.claude]?.button)

        #expect(!controller.statusItem.autosaveName.hasPrefix("CodexBar."))
        #expect(controller.statusItems[.codex]?.autosaveName.hasPrefix("CodexBar.") == false)
        #expect(controller.statusItems[.claude]?.autosaveName.hasPrefix("CodexBar.") == false)
        #expect(controller.statusItem.button?.accessibilityIdentifier() == "CodexBar.StatusItem")
        #expect(codexButton.accessibilityIdentifier() == "CodexBar.StatusItem.codex")
        #expect(claudeButton.accessibilityIdentifier() == "CodexBar.StatusItem.claude")
        #expect(controller.statusItem.button?.accessibilityTitle() == "CodexBar")
        #expect(codexButton.accessibilityTitle() == "CodexBar")
        #expect(claudeButton.accessibilityTitle() == "CodexBar")
    }

    @Test
    func `status item defaults repair removes stale hidden Control Center keys once`() throws {
        let suite = "StatusItemControllerSplitLifecycleTests-repair-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "NSStatusItem VisibleCC Item-0")
        defaults.set(0, forKey: "NSStatusItem VisibleCC Item-12")
        defaults.set(false, forKey: "NSStatusItem VisibleCC codexbar-merged")
        defaults.set(true, forKey: "NSStatusItem VisibleCC Item-1")
        defaults.set(false, forKey: "NSStatusItem VisibleCC com.apple.clock")
        defer {
            defaults.removePersistentDomain(forName: suite)
        }

        let repairedKeys = MenuBarStatusItemDefaultsRepair.repairHiddenVisibilityDefaultsIfNeeded(defaults: defaults)

        #expect(repairedKeys == [
            "NSStatusItem VisibleCC Item-0",
            "NSStatusItem VisibleCC Item-12",
            "NSStatusItem VisibleCC codexbar-merged",
        ])
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC Item-0") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC Item-12") == nil)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC codexbar-merged") == nil)
        #expect(defaults.bool(forKey: "NSStatusItem VisibleCC Item-1"))
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC com.apple.clock") != nil)

        defaults.set(false, forKey: "NSStatusItem VisibleCC Item-2")
        #expect(MenuBarStatusItemDefaultsRepair.repairHiddenVisibilityDefaultsIfNeeded(defaults: defaults).isEmpty)
        #expect(defaults.object(forKey: "NSStatusItem VisibleCC Item-2") != nil)
    }

    @Test
    func `non destructive visibility refresh preserves split provider status items`() throws {
        let (_, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        let oldCodexItem = try #require(controller.statusItems[.codex])
        let oldClaudeItem = try #require(controller.statusItems[.claude])
        let oldCodexButton = try #require(oldCodexItem.button)

        controller.refreshExistingStatusItemsForVisibilityRecovery()

        let newCodexItem = try #require(controller.statusItems[.codex])
        let newClaudeItem = try #require(controller.statusItems[.claude])
        #expect(newCodexItem === oldCodexItem)
        #expect(newClaudeItem === oldClaudeItem)
        #expect(newCodexItem.button === oldCodexButton)
        #expect(!newCodexItem.autosaveName.hasPrefix("CodexBar."))
        #expect(newCodexItem.button?.accessibilityIdentifier() == "CodexBar.StatusItem.codex")
    }

    @Test
    func `non destructive visibility refresh preserves merged status item`() throws {
        let (settings, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        settings.mergeIcons = true
        controller.handleProviderConfigChange(reason: "test")
        let oldMergedItem = controller.statusItem
        let oldMergedButton = try #require(controller.statusItem.button)

        controller.refreshExistingStatusItemsForVisibilityRecovery()

        #expect(controller.statusItem === oldMergedItem)
        #expect(controller.statusItem.button === oldMergedButton)
        #expect(!controller.statusItem.autosaveName.hasPrefix("CodexBar."))
        #expect(controller.statusItem.button?.accessibilityIdentifier() == "CodexBar.StatusItem")
    }

    @Test
    func `visibility recovery recreates split provider status items`() throws {
        let (_, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        let oldCodexItem = try #require(controller.statusItems[.codex])
        controller.recreateStatusItemsForVisibilityRecovery()

        let newCodexItem = try #require(controller.statusItems[.codex])
        #expect(newCodexItem !== oldCodexItem)
        #expect(!newCodexItem.autosaveName.hasPrefix("CodexBar."))
        #expect(newCodexItem.button?.accessibilityIdentifier() == "CodexBar.StatusItem.codex")
    }

    @Test
    func `visibility recovery renders replacement merged status item`() throws {
        let (settings, controller) = try self.makeSplitController()
        defer { controller.releaseStatusItemsForTesting() }

        settings.mergeIcons = true
        controller.handleProviderConfigChange(reason: "test")
        let renderedSignature = try #require(controller.lastAppliedMergedIconRenderSignature)

        controller.lastAppliedMergedIconRenderSignature = renderedSignature
        controller.recreateStatusItemsForVisibilityRecovery()

        let mergedButton = try #require(controller.statusItem.button)
        #expect(mergedButton.image != nil)
        #expect(!controller.statusItem.autosaveName.hasPrefix("CodexBar."))
        #expect(mergedButton.accessibilityIdentifier() == "CodexBar.StatusItem")
    }
}
