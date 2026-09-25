import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct SettingsStoreOpenAIWebAccessTests {
    @Test
    func `first launch denial persists when a provider config appears on the next launch`() {
        let firstLaunchDefaults = InMemoryUserDefaults()
        SettingsStore.initializeOpenAIWebAccessPreference(
            userDefaults: firstLaunchDefaults,
            config: CodexBarConfig(providers: []))
        #expect(firstLaunchDefaults.object(forKey: "openAIWebAccessEnabled") as? Bool == false)

        // Reload only the saved values; exercise the same initialization helper as the production app.
        let secondLaunchDefaults = InMemoryUserDefaults(values: firstLaunchDefaults.dictionaryRepresentation())
        SettingsStore.initializeOpenAIWebAccessPreference(
            userDefaults: secondLaunchDefaults,
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex)]))
        #expect(secondLaunchDefaults.object(forKey: "openAIWebAccessEnabled") as? Bool == false)
    }

    @Test
    func `existing generic codex configuration does not establish browser consent`() {
        let defaults = InMemoryUserDefaults()
        SettingsStore.initializeOpenAIWebAccessPreference(
            userDefaults: defaults,
            config: CodexBarConfig(providers: [ProviderConfig(id: .codex)]))
        #expect(defaults.object(forKey: "openAIWebAccessEnabled") as? Bool == false)
    }

    @Test(arguments: [false, true], [ProviderCookieSource.off, .auto])
    func `explicit preference survives initialization and reload despite cookie configuration`(
        enabled: Bool,
        cookieSource: ProviderCookieSource)
    {
        let defaults = InMemoryUserDefaults(values: ["openAIWebAccessEnabled": enabled])
        let config = CodexBarConfig(providers: [ProviderConfig(id: .codex, cookieSource: cookieSource)])
        SettingsStore.initializeOpenAIWebAccessPreference(userDefaults: defaults, config: config)
        let reloaded = InMemoryUserDefaults(values: defaults.dictionaryRepresentation())
        SettingsStore.initializeOpenAIWebAccessPreference(userDefaults: reloaded, config: config)
        #expect(reloaded.object(forKey: "openAIWebAccessEnabled") as? Bool == enabled)
    }

    @Test(arguments: [ProviderCookieSource.off, .auto, .manual])
    func `explicit legacy cookie source determines initial browser access`(cookieSource: ProviderCookieSource) {
        let defaults = InMemoryUserDefaults()
        SettingsStore.initializeOpenAIWebAccessPreference(
            userDefaults: defaults,
            config: CodexBarConfig(providers: [
                ProviderConfig(id: .codex, cookieHeader: "session=synthetic", cookieSource: cookieSource),
            ]))
        #expect(defaults.object(forKey: "openAIWebAccessEnabled") as? Bool == cookieSource.isEnabled)
    }

    @Test
    func `legacy manual cookie header establishes consent only when nonempty`() {
        for header in ["session=synthetic", " "] {
            let defaults = InMemoryUserDefaults()
            SettingsStore.initializeOpenAIWebAccessPreference(
                userDefaults: defaults,
                config: CodexBarConfig(providers: [ProviderConfig(id: .codex, cookieHeader: header)]))
            #expect(defaults.object(forKey: "openAIWebAccessEnabled") as? Bool == (header == "session=synthetic"))
        }
    }
}
