import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct ProviderSettingsDescriptorTests {
    @Test
    func `toggle I ds are unique across providers`() throws {
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
    func `codex exposes usage and cookie pickers`() throws {
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
        let toggles = CodexProviderImplementation().settingsToggles(context: context)
        #expect(pickers.contains(where: { $0.id == "codex-usage-source" }))
        #expect(pickers.contains(where: { $0.id == "codex-cookie-source" }))
        #expect(toggles.contains(where: { $0.id == "codex-historical-tracking" }))
    }

    @Test
    func `claude exposes usage and cookie pickers`() throws {
        let suite = "ProviderSettingsDescriptorTests-claude"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.debugDisableKeychainAccess = false
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
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        let optionIDs = Set(keychainPicker.options.map(\.id))
        #expect(optionIDs.contains(ClaudeOAuthKeychainPromptMode.never.rawValue))
        #expect(optionIDs.contains(ClaudeOAuthKeychainPromptMode.onlyOnUserAction.rawValue))
        #expect(optionIDs.contains(ClaudeOAuthKeychainPromptMode.always.rawValue))
        #expect(keychainPicker.isEnabled?() ?? true)
    }

    @Test
    func `claude prompt policy picker hidden when experimental reader selected`() throws {
        let suite = "ProviderSettingsDescriptorTests-claude-prompt-hidden-experimental"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.debugDisableKeychainAccess = false
        settings.claudeOAuthKeychainReadStrategy = .securityCLIExperimental

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
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        #expect(keychainPicker.isVisible?() == false)
    }

    @Test
    func `claude keychain prompt policy picker disabled when global keychain disabled`() throws {
        let suite = "ProviderSettingsDescriptorTests-claude-keychain-disabled"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.debugDisableKeychainAccess = true
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
        let keychainPicker = try #require(pickers.first(where: { $0.id == "claude-keychain-prompt-policy" }))
        #expect(keychainPicker.isEnabled?() == false)
        let subtitle = keychainPicker.dynamicSubtitle?() ?? ""
        #expect(subtitle.localizedCaseInsensitiveContains("inactive"))
    }

    @Test
    func `claude web extras auto disables when leaving CLI`() throws {
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

    @Test
    func `kilo exposes usage source picker and api field only`() throws {
        let suite = "ProviderSettingsDescriptorTests-kilo"
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
            provider: .kilo,
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

        let implementation = KiloProviderImplementation()
        let toggles = implementation.settingsToggles(context: context)
        let pickers = implementation.settingsPickers(context: context)
        let fields = implementation.settingsFields(context: context)

        #expect(toggles.isEmpty)
        #expect(pickers.contains(where: { $0.id == "kilo-usage-source" }))
        #expect(fields.contains(where: { $0.id == "kilo-api-key" }))
    }

    @Test
    func `alibaba presentation follows store source label`() throws {
        let suite = "ProviderSettingsDescriptorTests-alibaba-presentation"
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
        let metadata = try #require(ProviderDescriptorRegistry.metadata[.alibaba])
        let context = ProviderPresentationContext(
            provider: .alibaba,
            settings: settings,
            store: store,
            metadata: metadata)

        let detailLine = AlibabaCodingPlanProviderImplementation()
            .presentation(context: context)
            .detailLine(context)

        #expect(detailLine == store.sourceLabel(for: .alibaba))
    }
}
