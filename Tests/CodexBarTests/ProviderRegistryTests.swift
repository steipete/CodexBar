import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct ProviderRegistryTests {
    @Test
    func implementationsCoverAllProviders() {
        let ids = Set(ProviderCatalog.all.map(\.id))
        #expect(ids.count == ProviderCatalog.all.count)
        #expect(ids == Set(UsageProvider.allCases))
    }

    @Test
    func defaultsEnableCodexAndDisableClaude() {
        let defaults = UserDefaults(suiteName: "ProviderRegistryTests-defaults")!
        defaults.removePersistentDomain(forName: "ProviderRegistryTests-defaults")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        let registry = ProviderRegistry.shared

        let codexEnabled = settings.isProviderEnabled(provider: .codex, metadata: registry.metadata[.codex]!)
        let claudeEnabled = settings.isProviderEnabled(provider: .claude, metadata: registry.metadata[.claude]!)

        #expect(codexEnabled)
        #expect(!claudeEnabled)
    }

    @Test
    func togglesPersistAcrossStoreInstances() {
        let suite = "ProviderRegistryTests-persist"
        let defaultsA = UserDefaults(suiteName: suite)!
        defaultsA.removePersistentDomain(forName: suite)

        let settingsA = SettingsStore(userDefaults: defaultsA, zaiTokenStore: NoopZaiTokenStore())
        let registry = ProviderRegistry.shared
        let claudeMeta = registry.metadata[.claude]!

        settingsA.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)

        let defaultsB = UserDefaults(suiteName: suite)!
        let settingsB = SettingsStore(userDefaults: defaultsB, zaiTokenStore: NoopZaiTokenStore())
        let enabledAfterReload = settingsB.isProviderEnabled(provider: .claude, metadata: claudeMeta)

        #expect(enabledAfterReload)
    }

    @Test
    func registryBuildsSpecsForAllProviders() {
        let registry = ProviderRegistry.shared
        let defaults = UserDefaults(suiteName: "ProviderRegistryTests-specs")!
        defaults.removePersistentDomain(forName: "ProviderRegistryTests-specs")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        let specs = registry.specs(
            settings: settings,
            metadata: registry.metadata,
            codexFetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher())
        #expect(specs.keys.count == UsageProvider.allCases.count)
    }

    @Test
    func claudeStrategyPrefersWebWhenSessionAvailable() {
        let defaults = UserDefaults(suiteName: "ProviderRegistryTests-claude-web")!
        defaults.removePersistentDomain(forName: "ProviderRegistryTests-claude-web")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        settings.debugMenuEnabled = false

        let strategy = ClaudeProviderImplementation.usageStrategy(settings: settings, hasWebSession: { true })

        #expect(strategy.dataSource == .web)
        #expect(strategy.useWebExtras == false)
    }

    @Test
    func claudeStrategyFallsBackToCLIWhenNoSession() {
        let defaults = UserDefaults(suiteName: "ProviderRegistryTests-claude-cli")!
        defaults.removePersistentDomain(forName: "ProviderRegistryTests-claude-cli")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        settings.debugMenuEnabled = false

        let strategy = ClaudeProviderImplementation.usageStrategy(settings: settings, hasWebSession: { false })

        #expect(strategy.dataSource == .cli)
        #expect(strategy.useWebExtras == false)
    }

    @Test
    func claudeStrategyRespectsOAuthInDebug() {
        let defaults = UserDefaults(suiteName: "ProviderRegistryTests-claude-oauth")!
        defaults.removePersistentDomain(forName: "ProviderRegistryTests-claude-oauth")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        settings.debugMenuEnabled = true
        settings.claudeUsageDataSource = .oauth

        let strategy = ClaudeProviderImplementation.usageStrategy(settings: settings, hasWebSession: { false })

        #expect(strategy.dataSource == .oauth)
        #expect(strategy.useWebExtras == false)
    }

    @Test
    func claudeStrategyEnablesWebExtrasOnlyWithSession() {
        let defaults = UserDefaults(suiteName: "ProviderRegistryTests-claude-extras")!
        defaults.removePersistentDomain(forName: "ProviderRegistryTests-claude-extras")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        settings.debugMenuEnabled = true
        settings.claudeUsageDataSource = .cli
        settings.claudeWebExtrasEnabled = true

        let strategy = ClaudeProviderImplementation.usageStrategy(settings: settings, hasWebSession: { true })

        #expect(strategy.dataSource == .cli)
        #expect(strategy.useWebExtras == true)
    }

    @Test
    func providerCatalogLookupsExistForAllProviders() {
        for provider in UsageProvider.allCases {
            #expect(ProviderCatalog.implementation(for: provider) != nil)
        }
    }
}
