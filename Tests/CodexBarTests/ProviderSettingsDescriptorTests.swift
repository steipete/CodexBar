import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite
struct ProviderSettingsDescriptorTests {
    @Test
    func toggleIDsAreUniqueAcrossProviders() {
        let defaults = UserDefaults(suiteName: "ProviderSettingsDescriptorTests-unique")!
        defaults.removePersistentDomain(forName: "ProviderSettingsDescriptorTests-unique")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        let store = UsageStore(fetcher: UsageFetcher(environment: [:]), settings: settings)

        var statusByID: [String: String] = [:]
        var lastRunAtByID: [String: Date] = [:]
        var seenToggleIDs: Set<String> = []
        var seenActionIDs: Set<String> = []

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

            let impl = ProviderCatalog.implementation(for: provider)!
            let toggles = impl.settingsToggles(context: context)
            for toggle in toggles {
                #expect(!seenToggleIDs.contains(toggle.id))
                seenToggleIDs.insert(toggle.id)

                for action in toggle.actions {
                    #expect(!seenActionIDs.contains(action.id))
                    seenActionIDs.insert(action.id)
                }
            }
        }
    }

    @Test
    func codexDoesNotExposeOpenAIWebToggle() {
        let defaults = UserDefaults(suiteName: "ProviderSettingsDescriptorTests-codex")!
        defaults.removePersistentDomain(forName: "ProviderSettingsDescriptorTests-codex")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        let store = UsageStore(fetcher: UsageFetcher(environment: [:]), settings: settings)

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

        let toggles = CodexProviderImplementation().settingsToggles(context: context)
        #expect(toggles.isEmpty)
    }

    @Test
    func claudeWebExtrasToggleIsVisibleOnlyForCLIDataSource() {
        let defaults = UserDefaults(suiteName: "ProviderSettingsDescriptorTests-claude")!
        defaults.removePersistentDomain(forName: "ProviderSettingsDescriptorTests-claude")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        let store = UsageStore(fetcher: UsageFetcher(environment: [:]), settings: settings)

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

        let toggle = ClaudeProviderImplementation().settingsToggles(context: context)
            .first { $0.id == "claude.webExtras" }!

        settings.debugMenuEnabled = true
        settings.claudeUsageDataSource = .web
        #expect((toggle.isVisible?() ?? true) == false)

        settings.claudeUsageDataSource = .cli
        #expect((toggle.isVisible?() ?? true) == true)
    }

    @Test
    func claudeWebExtrasAutoDisablesWhenLeavingCLI() {
        let defaults = UserDefaults(suiteName: "ProviderSettingsDescriptorTests-claude-invariant")!
        defaults.removePersistentDomain(forName: "ProviderSettingsDescriptorTests-claude-invariant")
        let settings = SettingsStore(userDefaults: defaults, zaiTokenStore: NoopZaiTokenStore())
        settings.debugMenuEnabled = true
        settings.claudeUsageDataSource = .cli
        settings.claudeWebExtrasEnabled = true

        settings.claudeUsageDataSource = .oauth
        #expect(settings.claudeWebExtrasEnabled == false)
    }
}
