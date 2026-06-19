import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemControllerShutdownTests {
    @Test
    func `app shutdown closes tracked menus and removes status items`() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = !SettingsStore.isRunningTests
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        let registry = ProviderRegistry.shared
        if let codexMetadata = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        }
        if let claudeMetadata = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        controller.menuRefreshTasks[key] = Task { try? await Task.sleep(for: .seconds(30)) }
        controller.menuReadinessSignatures[key] = "readiness"
        controller.menuIdentitySignatures[key] = "identity"

        #expect(controller.openMenus[key] === menu)
        #expect(controller.mergedMenu != nil)
        #expect(controller.statusItem.menu === controller.mergedMenu)

        controller.prepareForAppShutdown()
        controller.prepareForAppShutdown()

        #expect(controller.hasPreparedForAppShutdown)
        #expect(controller.openMenus.isEmpty)
        #expect(controller.menuRefreshTasks.isEmpty)
        #expect(controller.menuReadinessSignatures.isEmpty)
        #expect(controller.menuIdentitySignatures.isEmpty)
        #expect(controller.providerSwitcherShortcutEventMonitor == nil)
        #expect(controller.statusItem.menu == nil)
        #expect(controller.statusItems.isEmpty)
        #expect(controller.providerMenus.isEmpty)
        #expect(controller.mergedMenu == nil)
    }

    @Test
    func `status menu quit defers shutdown until menu tracking can unwind`() {
        let controller = self.makeController()
        defer {
            StatusItemController.menuCardRenderingEnabled = !SettingsStore.isRunningTests
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }
        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)

        var scheduledTermination: (@MainActor () -> Void)?
        var didTerminate = false
        controller.scheduleQuitTermination = { operation in
            scheduledTermination = operation
        }
        controller.terminateApplicationForQuit = {
            didTerminate = true
        }

        controller.quit()

        #expect(scheduledTermination != nil)
        #expect(!controller.hasPreparedForAppShutdown)
        #expect(!didTerminate)
        #expect(controller.openMenus[key] === menu)

        scheduledTermination?()

        #expect(controller.hasPreparedForAppShutdown)
        #expect(controller.openMenus.isEmpty)
        #expect(controller.statusItem.menu == nil)
        #expect(didTerminate)
    }

    private func makeController() -> StatusItemController {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        if let codexMetadata = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusItemControllerShutdownTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
