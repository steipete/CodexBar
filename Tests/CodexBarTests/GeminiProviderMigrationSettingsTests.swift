import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct GeminiProviderMigrationSettingsTests {
    private func makeSettings() -> SettingsStore {
        let suite = "GeminiProviderMigrationSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        return settings
    }

    private func makeStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
    }

    private func makeContext(settings: SettingsStore, store: UsageStore) -> ProviderSettingsContext {
        ProviderSettingsContext(
            provider: .gemini,
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
            requestConfirmation: { _ in },
            runLoginFlow: {})
    }

    @Test
    func `typed predicate accepts consumer tier deprecated only`() {
        #expect(UsageStore.isGeminiConsumerTierDeprecationError(GeminiStatusProbeError.consumerTierDeprecated))
        #expect(!UsageStore.isGeminiConsumerTierDeprecationError(GeminiStatusProbeError.notLoggedIn))
        #expect(!UsageStore.isGeminiConsumerTierDeprecationError(nil))
    }

    @Test
    func `not logged in proactive hint does not satisfy typed predicate`() {
        let message = GeminiStatusProbeError.notLoggedIn.errorDescription ?? ""
        #expect(GeminiStatusProbeError.isConsumerTierDeprecationSignal(message))
        #expect(!UsageStore.isGeminiConsumerTierDeprecationError(GeminiStatusProbeError.notLoggedIn))
    }

    @Test
    func `settings action appears when deprecation was observed`() {
        let settings = self.makeSettings()
        let store = self.makeStore(settings: settings)
        store.syncGeminiConsumerTierDeprecationObservation(from: GeminiStatusProbeError.consumerTierDeprecated)

        let impl = GeminiProviderImplementation()
        let actions = impl.settingsActions(context: self.makeContext(settings: settings, store: store))

        #expect(actions.map(\.id) == ["gemini-antigravity-migration"])
    }

    @Test
    func `settings action hidden for not logged in even with proactive hint text stored`() {
        let settings = self.makeSettings()
        let store = self.makeStore(settings: settings)
        store.errors[.gemini] = GeminiStatusProbeError.notLoggedIn.errorDescription
        store.syncGeminiConsumerTierDeprecationObservation(from: GeminiStatusProbeError.notLoggedIn)

        let impl = GeminiProviderImplementation()
        let actions = impl.settingsActions(context: self.makeContext(settings: settings, store: store))

        #expect(actions.isEmpty)
        #expect(!store.geminiObservedConsumerTierDeprecation)
    }

    @Test
    func `settings action hidden for unauthenticated401 style failures`() {
        let unauthenticatedBody = """
        {"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}
        """
        #expect(!GeminiStatusProbeError.isConsumerTierDeprecationSignal(unauthenticatedBody))

        let settings = self.makeSettings()
        let store = self.makeStore(settings: settings)
        store.errors[.gemini] = GeminiStatusProbeError.notLoggedIn.errorDescription
        store.syncGeminiConsumerTierDeprecationObservation(from: GeminiStatusProbeError.notLoggedIn)

        let impl = GeminiProviderImplementation()
        let actions = impl.settingsActions(context: self.makeContext(settings: settings, store: store))

        #expect(actions.isEmpty)
    }
}
