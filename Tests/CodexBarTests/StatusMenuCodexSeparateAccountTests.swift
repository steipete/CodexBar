import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusMenuCodexSeparateAccountTests {
    @Test
    func `separate Codex accounts create private account items without switcher`() throws {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)
        let managedID = UUID()
        let storeURL = try self.makeManagedAccountStoreURL(accounts: [
            ManagedCodexAccount(
                id: managedID,
                email: "managed.private@example.com",
                managedHomePath: "/tmp/managed-home",
                createdAt: 1,
                updatedAt: 2,
                lastAuthenticatedAt: 2),
        ])
        settings._test_managedCodexAccountStoreURL = storeURL
        settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: "live.private@example.com",
            codexHomePath: "/Users/test/.codex",
            observedAt: Date())
        settings.codexActiveSource = .liveSystem
        settings.setAccountMenuBarDisplayMode(.separate, for: .codex)
        defer {
            settings._test_managedCodexAccountStoreURL = nil
            settings._test_liveSystemCodexAccount = nil
            try? FileManager.default.removeItem(at: storeURL)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.statusItems[.codex] == nil)
        #expect(controller.accountStatusItems.count == 2)
        var menusWithPlanUsage = 0
        for item in controller.accountStatusItems.values {
            let autosaveName = item.autosaveName ?? ""
            let identifier = item.button?.accessibilityIdentifier() ?? ""
            #expect(!autosaveName.contains("private@example.com"))
            #expect(!identifier.contains("private@example.com"))
            let menu = try #require(item.menu)
            controller.populateMenu(menu, provider: .codex)
            #expect(!menu.items.contains { $0.view is CodexAccountSwitcherView })
            #expect(!menu.items.contains { $0.view is TokenAccountSwitcherView })
            let titles = Set(menu.items.map(\.title))
            #expect(titles.contains("Usage Dashboard"))
            #expect(titles.contains("Status Page"))
            if titles.contains("Plan Usage") {
                menusWithPlanUsage += 1
            }
            #expect(!titles.contains("Add Account…"))
            #expect(!titles.contains("System Account"))
        }
        #expect(menusWithPlanUsage == 1)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuCodexSeparateAccountTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func makeManagedAccountStoreURL(accounts: [ManagedCodexAccount]) throws -> URL {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = FileManagedCodexAccountStore(fileURL: storeURL)
        try store.storeAccounts(ManagedCodexAccountSet(
            version: FileManagedCodexAccountStore.currentVersion,
            accounts: accounts))
        return storeURL
    }
}
