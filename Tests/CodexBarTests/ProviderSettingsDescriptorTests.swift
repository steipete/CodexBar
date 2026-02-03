import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite
struct ProviderSettingsDescriptorTests {
    @Test
    func toggleIDsAreUniqueAcrossProviders() throws {
        let suite = "ProviderSettingsDescriptorTests-unique"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        var statusByID: [String: String] = [:]
        var lastRunAtByID: [String: Date] = [:]
        var seenToggleIDs: Set<String> = []
        var seenActionIDs: Set<String> = []
        var seenPickerIDs: Set<String> = []

        for provider in UsageProvider.allCases {
            let context = ProviderSettingsContext(
                provider: provider,
                settings: settings,
                store: store,
                boolBinding: { keyPath in
                    Binding(
                        get: { settings[keyPath: keyPath] },
                        set: { settings[keyPath: keyPath] = $0 })
                },
                stringBinding: { keyPath in
                    Binding(
                        get: { settings[keyPath: keyPath] },
                        set: { settings[keyPath: keyPath] = $0 })
                },
                statusText: { id in statusByID[id] },
                setStatusText: { id, text in
                    if let text {
                        statusByID[id] = text
                    } else {
                        statusByID.removeValue(forKey: id)
                    }
                },
                lastAppActiveRunAt: { id in lastRunAtByID[id] },
                setLastAppActiveRunAt: { id, date in
                    if let date {
                        lastRunAtByID[id] = date
                    } else {
                        lastRunAtByID.removeValue(forKey: id)
                    }
                },
                requestConfirmation: { _ in })

            let impl = try #require(ProviderCatalog.implementation(for: provider))
            let toggles = impl.settingsToggles(context: context)
            for toggle in toggles {
                #expect(!seenToggleIDs.contains(toggle.id))
                seenToggleIDs.insert(toggle.id)

                for action in toggle.actions {
                    #expect(!seenActionIDs.contains(action.id))
                    seenActionIDs.insert(action.id)
                }
            }

            let pickers = impl.settingsPickers(context: context)
            for picker in pickers {
                #expect(!seenPickerIDs.contains(picker.id))
                seenPickerIDs.insert(picker.id)
            }
        }
    }

    @Test
    func codexExposesUsageAndCookiePickers() throws {
        let suite = "ProviderSettingsDescriptorTests-codex"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let context = ProviderSettingsContext(
            provider: .codex,
            settings: settings,
            store: store,
            boolBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })

        let pickers = CodexProviderImplementation().settingsPickers(context: context)
        #expect(pickers.contains(where: { $0.id == "codex-usage-source" }))
        #expect(pickers.contains(where: { $0.id == "codex-cookie-source" }))
    }

    @Test
    func claudeExposesUsageAndCookiePickers() throws {
        let suite = "ProviderSettingsDescriptorTests-claude"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let context = ProviderSettingsContext(
            provider: .claude,
            settings: settings,
            store: store,
            boolBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            stringBinding: { keyPath in
                Binding(
                    get: { settings[keyPath: keyPath] },
                    set: { settings[keyPath: keyPath] = $0 })
            },
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })
        let pickers = ClaudeProviderImplementation().settingsPickers(context: context)
        #expect(pickers.contains(where: { $0.id == "claude-usage-source" }))
        #expect(pickers.contains(where: { $0.id == "claude-cookie-source" }))
    }

    @Test
    func claudeWebExtrasAutoDisablesWhenLeavingCLI() throws {
        let suite = "ProviderSettingsDescriptorTests-claude-invariant"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.debugMenuEnabled = true
        settings.claudeUsageDataSource = .cli
        settings.claudeWebExtrasEnabled = true

        settings.claudeUsageDataSource = .oauth
        #expect(settings.claudeWebExtrasEnabled == false)
    }
}
