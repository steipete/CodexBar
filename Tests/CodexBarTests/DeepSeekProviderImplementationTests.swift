import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct DeepSeekProviderImplementationTests {
    @Test
    func `settings actions include usage dashboard link`() throws {
        let suite = "DeepSeekProviderImplementationTests-actions"
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
            settings: settings)
        let context = ProviderSettingsContext(
            provider: .deepseek,
            settings: settings,
            store: store,
            boolBinding: { _ in .constant(false) },
            stringBinding: { _ in .constant("") },
            statusText: { _ in nil },
            setStatusText: { _, _ in },
            lastAppActiveRunAt: { _ in nil },
            setLastAppActiveRunAt: { _, _ in },
            requestConfirmation: { _ in })

        let actions = DeepSeekProviderImplementation().settingsActions(context: context)
        #expect(actions.count == 1)
        #expect(actions[0].actions.first?.title == "Open Usage Dashboard")
    }

    @Test
    func `web only session makes provider available`() throws {
        let suite = "DeepSeekProviderImplementationTests-availability"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.deepSeekCookieSource = .manual
        settings.deepSeekCookieHeader = "session=manual"

        let available = DeepSeekProviderImplementation().isAvailable(context: ProviderAvailabilityContext(
            provider: .deepseek,
            settings: settings,
            environment: [:]))
        #expect(available)
    }

    @Test
    func `auto mode stays available before cached browser session exists`() throws {
        #if os(macOS)
        CookieHeaderCache.clear(provider: .deepseek)
        defer { CookieHeaderCache.clear(provider: .deepseek) }

        let suite = "DeepSeekProviderImplementationTests-auto-availability"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.deepSeekCookieSource = .auto
        settings.deepSeekCookieHeader = ""

        let available = DeepSeekProviderImplementation().isAvailable(context: ProviderAvailabilityContext(
            provider: .deepseek,
            settings: settings,
            environment: [:]))
        #expect(available)
        #endif
    }

    @Test
    func `source mode honors configured usage source`() throws {
        let suite = "DeepSeekProviderImplementationTests-source-mode"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.deepSeekUsageDataSource = .web

        let mode = DeepSeekProviderImplementation().sourceMode(context: ProviderSourceModeContext(
            provider: .deepseek,
            settings: settings))
        #expect(mode == .web)
    }
}
