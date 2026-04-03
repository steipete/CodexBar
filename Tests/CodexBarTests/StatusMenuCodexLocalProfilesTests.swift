import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct StatusMenuCodexLocalProfilesTests {
    private func disableMenuCardsForTesting() {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.menuRefreshEnabled = false
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuCodexLocalProfilesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    private func enableOnlyCodex(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func enableCodexAndClaude(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let enabled = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: enabled)
        }
    }

    private func writeAuthFile(to url: URL, email: String, plan: String, accountID: String) throws {
        let token = Self.fakeJWT(email: email, plan: plan)
        let payload: [String: Any] = [
            "tokens": [
                "access_token": "access-\(accountID)",
                "refresh_token": "refresh-\(accountID)",
                "id_token": token,
                "account_id": accountID,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: url)
    }

    @Test
    func `codex local profiles menu hides save action when current account already saved`() throws {
        self.disableMenuCardsForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let profileURL = root.appendingPathComponent("profiles/plus-a.json")
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")
        try self.writeAuthFile(to: profileURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            appURL: root.appendingPathComponent("Codex.app"))
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            codexLocalProfileManager: manager,
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        #expect(menu.items.contains(where: { $0.title == "Save Current Account…" }) == false)
        let switchItem = try #require(menu.items.first(where: { $0.title == "Switch Local Profile" }))
        #expect(switchItem.submenu != nil)
    }

    @Test
    func `codex local profiles menu shows save action when live auth exists but no saved match exists`() throws {
        self.disableMenuCardsForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            appURL: root.appendingPathComponent("Codex.app"))
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            codexLocalProfileManager: manager,
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        #expect(menu.items.contains(where: { $0.title == "Save Current Account…" }))
    }

    @Test
    func `codex local profiles menu hides save action when no valid live auth exists`() throws {
        self.disableMenuCardsForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        self.enableOnlyCodex(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let manager = CodexLocalProfileManager(
            authFileURL: root.appendingPathComponent("auth.json"),
            fileManager: .default,
            appURL: root.appendingPathComponent("Codex.app"))
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            codexLocalProfileManager: manager,
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        #expect(menu.items.contains(where: { $0.title == "Save Current Account…" }) == false)
        let switchItem = try #require(menu.items.first(where: { $0.title == "Switch Local Profile" }))
        let submenuTitles = try #require(switchItem.submenu).items.map(\.title)
        #expect(submenuTitles.contains("Log into Codex first to save a profile"))
    }

    @Test
    func `merged codex menu preserves local profiles section during smart refresh`() throws {
        self.disableMenuCardsForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("auth.json")
        let profileURL = root.appendingPathComponent("profiles/plus-a.json")
        try self.writeAuthFile(to: authURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false
        self.enableCodexAndClaude(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let manager = CodexLocalProfileManager(
            authFileURL: authURL,
            fileManager: .default,
            appURL: root.appendingPathComponent("Codex.app"))
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            codexLocalProfileManager: manager,
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        #expect(menu.items.contains(where: { $0.title == "Save Current Account…" }))
        let initialSwitchItem = try #require(menu.items.first(where: { $0.title == "Switch Local Profile" }))
        let initialSubmenuTitles = try #require(initialSwitchItem.submenu).items.map(\.title)
        #expect(initialSubmenuTitles.contains("No saved profiles yet"))

        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try self.writeAuthFile(to: profileURL, email: "plus-a@example.com", plan: "plus", accountID: "acct-a")

        controller.menuContentVersion &+= 1
        controller.refreshOpenMenusIfNeeded()

        #expect(menu.items.contains(where: { $0.title == "Save Current Account…" }) == false)
        let refreshedSwitchItem = try #require(menu.items.first(where: { $0.title == "Switch Local Profile" }))
        let refreshedSubmenuTitles = try #require(refreshedSwitchItem.submenu).items.map(\.title)
        #expect(refreshedSubmenuTitles.contains("Switch to plus-a"))
    }

    private static func fakeJWT(email: String, plan: String) -> String {
        let header = (try? JSONSerialization.data(withJSONObject: ["alg": "none"])) ?? Data()
        let payload = (try? JSONSerialization.data(withJSONObject: [
            "email": email,
            "chatgpt_plan_type": plan,
            "https://api.openai.com/auth": ["chatgpt_plan_type": plan],
            "https://api.openai.com/profile": ["email": email],
        ])) ?? Data()
        return "\(self.base64URL(header)).\(self.base64URL(payload))."
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
