import Foundation
import SwiftUI
import Testing
@testable import CodexBar
@testable import CodexBarCore

@Suite(.serialized)
@MainActor
struct MuseProviderImplementationTests {
    @Test
    func `cookie source picker exposes api only opt out`() throws {
        let suite = "MuseProviderImplementationTests-cookie-off-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])
        let context = ProviderSettingsContext(
            provider: .muse,
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

        let picker = try #require(MuseProviderImplementation().settingsPickers(context: context)
            .first(where: { $0.id == "muse-cookie-source" }))

        #expect(picker.options.contains(where: { $0.id == ProviderCookieSource.off.rawValue }))
        picker.binding.wrappedValue = ProviderCookieSource.off.rawValue
        #expect(settings.museCookieSource == .off)
        #expect(picker.dynamicSubtitle?() == "Muse cookies disabled.")
    }

    @Test
    func `web-only auto is available without api key`() throws {
        let suite = "MuseProviderImplementationTests-web-auto-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        // No API key, default cookieSource is .auto
        settings.museCookieSource = .auto
        settings.museCookieHeader = ""

        let impl = MuseProviderImplementation()
        let context = ProviderAvailabilityContext(
            provider: .muse,
            settings: settings,
            environment: [:])

        #expect(impl.isAvailable(context: context))
    }

    @Test
    func `web-only manual with header is available`() throws {
        let suite = "MuseProviderImplementationTests-web-manual-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.museCookieSource = .manual
        settings.museCookieHeader = "datr=abc; llm_sess=xyz"

        let impl = MuseProviderImplementation()
        let context = ProviderAvailabilityContext(
            provider: .muse,
            settings: settings,
            environment: [:])

        #expect(impl.isAvailable(context: context))
    }

    @Test
    func `web-only manual without header is not available`() throws {
        let suite = "MuseProviderImplementationTests-web-manual-empty-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.museCookieSource = .manual
        settings.museCookieHeader = ""

        let impl = MuseProviderImplementation()
        let context = ProviderAvailabilityContext(
            provider: .muse,
            settings: settings,
            environment: [:])

        #expect(!impl.isAvailable(context: context))
    }

    @Test
    func `api key is available`() throws {
        let suite = "MuseProviderImplementationTests-api-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.museCookieSource = .off
        settings.museAPIToken = "sk-test"

        let impl = MuseProviderImplementation()
        let context = ProviderAvailabilityContext(
            provider: .muse,
            settings: settings,
            environment: [:])

        #expect(impl.isAvailable(context: context))
    }

    @Test
    func `off with no api key is not available`() throws {
        let suite = "MuseProviderImplementationTests-off-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        settings.museCookieSource = .off
        settings.museAPIToken = ""

        let impl = MuseProviderImplementation()
        let context = ProviderAvailabilityContext(
            provider: .muse,
            settings: settings,
            environment: [:])

        #expect(!impl.isAvailable(context: context))
    }
}
