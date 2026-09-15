import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ProviderSettingsIntegrationTests {
    @Test
    func `reordering visible providers preserves saved configuration for absent plugins`() throws {
        let absent = try #require(ProviderInstanceID(rawValue: "absent-fixture-plugin"))
        let settings = testSettingsStore(
            suiteName: #function,
            userDefaults: InMemoryUserDefaults())
        // Model a plugin becoming unavailable after its configuration is already loaded.
        settings.updatePluginConfig(instanceID: absent) {
            $0.enabled = false
            $0.apiKey = "synthetic-plugin-key"
        }
        #expect(settings.configSnapshot.providerConfig(for: absent)?.apiKey == "synthetic-plugin-key")
        let before = settings.orderedProviders()
        #expect(!before.contains(absent))
        settings.moveProvider(fromOffsets: IndexSet(integer: 0), toOffset: before.count)

        #expect(settings.orderedProviders().last == before.first)
        #expect(settings.configSnapshot.providerConfig(for: absent)?.apiKey == "synthetic-plugin-key")
        #expect(settings.configSnapshot.providerConfig(for: absent)?.enabled == false)
        #expect(settings.configSnapshot.providers.count(where: { $0.id == absent }) == 1)
    }

    @Test
    func `settings links resolve their destination only when clicked`() async {
        var resolutions = 0
        let destination: () -> URL? = {
            resolutions += 1
            return nil
        }
        let action = ProviderSettingsActionDescriptor.openURL(id: "fixture", title: "Fixture", url: destination())
        #expect(resolutions == 0)
        await action.perform()
        #expect(resolutions == 1)
    }

    @Test
    func `cookie pickers write only their provider and keep subtitles live`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let providers: [UsageProvider] = [
            .abacus, .alibaba, .alibabatokenplan, .amp, .augment, .claude, .codex, .commandcode,
            .copilot, .cursor, .devin, .factory, .grok, .kimi, .longcat, .manus, .mimo, .minimax,
            .mistral, .notion, .ollama, .opencode, .opencodego, .perplexity, .qoder, .qwencloud,
            .stepfun, .t3chat, .windsurf, .zoommate,
        ]
        for provider in providers {
            let context = ProviderSettingsContext(
                provider: provider,
                settings: settings,
                store: store,
                statusText: { _ in nil },
                setStatusText: { _, _ in },
                lastAppActiveRunAt: { _ in nil },
                setLastAppActiveRunAt: { _, _ in },
                requestConfirmation: { _ in })
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let picker = try #require(implementation.settingsPickers(context: context)
                .first { $0.id.hasSuffix("cookie-source") })
            let otherSources = providers.filter { $0 != provider }
                .map { settings.providerConfig(for: $0)?.cookieSource }

            picker.binding.wrappedValue = "auto"
            let automaticText = picker.dynamicSubtitle?()
            picker.binding.wrappedValue = "manual"
            #expect(settings.providerConfig(for: provider)?.cookieSource == .manual)
            #expect(picker.binding.wrappedValue == "manual")
            #expect(picker.dynamicSubtitle?() != automaticText)
            picker.binding.wrappedValue = "unknown"
            #expect(settings.providerConfig(for: provider)?.cookieSource == .auto)
            #expect(picker.dynamicSubtitle?() == automaticText)
            #expect(providers.filter { $0 != provider }.map { settings.providerConfig(for: $0)?.cookieSource }
                == otherSources)
        }
    }

    @Test
    func `standard app cookie sections preserve configured modes and empty headers`() throws {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        defer { settings.debugDisableKeychainAccess = false }
        let providers: [UsageProvider] = [
            .abacus, .amp, .augment, .commandcode, .cursor, .factory, .kimi, .longcat,
            .manus, .mimo, .mistral, .ollama, .perplexity, .qoder, .qwencloud, .t3chat, .zoommate,
        ]
        for provider in providers {
            let implementation = try #require(ProviderCatalog.implementation(for: provider))
            let registration = ProviderDescriptorRegistry.descriptor(for: provider).settingsSection
            for header in ["", "session=fixture"] {
                settings[providerConfig: provider, field: .cookieHeader] = header
                for mode in [ProviderCookieSource.auto, .manual, .off] {
                    settings.setCookieSource(mode, provider: provider)
                    for keychainDisabled in [false, true] {
                        settings.debugDisableKeychainAccess = keychainDisabled
                        let contribution = try #require(implementation.settingsSnapshot(context: .init(
                            settings: settings,
                            tokenOverride: nil)))
                        #expect(registration.accepts(contribution))
                        let cookie = try #require(registration
                            .cookieSettings(from: .init(contributions: [contribution])))
                        #expect(cookie.cookieSource == (keychainDisabled && mode != .off ? .manual : mode))
                        #expect(cookie.manualCookieHeader == header)
                    }
                }
            }
        }
    }

    @Test
    func `standard app cookie sections keep account overrides scoped and normalized`() {
        let settings = testSettingsStore(suiteName: #function, userDefaults: InMemoryUserDefaults())
        settings.manusManualCookieHeader = "session_id=configured"
        settings.miMoCookieHeader = "mimo=configured"
        let account = ProviderTokenAccount(id: UUID(), label: "Fixture", token: "override", addedAt: 0, lastUsed: nil)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(
            settings: settings,
            tokenOverride: TokenAccountOverride(provider: .manus, account: account))

        #expect(snapshot.manus?.cookieSource == .manual)
        #expect(snapshot.manus?.manualCookieHeader == "session_id=override")
        #expect(snapshot.mimo?.cookieSource == .auto)
        #expect(snapshot.mimo?.manualCookieHeader == "mimo=configured")
        #expect(settings.manusManualCookieHeader == "session_id=configured")
        #expect(settings.tokenAccounts(for: .manus).isEmpty)

        #expect(TokenAccountSupportCatalog.support(for: .qwencloud) == nil)
        settings.qwenCloudCookieHeader = "qwen=configured"
        let unsupportedOverride = ProviderRegistry.makeSettingsSnapshot(
            settings: settings,
            tokenOverride: TokenAccountOverride(provider: .qwencloud, account: account))
        #expect(unsupportedOverride.qwenCloud?.cookieSource == .auto)
        #expect(unsupportedOverride.qwenCloud?.manualCookieHeader == "qwen=configured")
    }
}
