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
    func `ordinary auth errors do not set migration observation`() {
        let settings = self.makeSettings()
        let store = self.makeStore(settings: settings)

        store.observeGeminiConsumerTierDeprecation(from: GeminiStatusProbeError.notLoggedIn)

        #expect(!store.geminiObservedConsumerTierDeprecation)
    }

    @Test
    func `settings action appears when deprecation was observed`() {
        let settings = self.makeSettings()
        let store = self.makeStore(settings: settings)
        store.observeGeminiConsumerTierDeprecation(from: GeminiStatusProbeError.consumerTierDeprecated)

        let impl = GeminiProviderImplementation()
        let antigravity = ProviderDescriptorRegistry.descriptor(for: .antigravity).metadata
        let wasEnabled = settings.isProviderEnabled(provider: .antigravity, metadata: antigravity)
        let actions = impl.settingsActions(context: self.makeContext(settings: settings, store: store))

        #expect(actions.map(\.id) == ["gemini-antigravity-migration"])
        #expect(settings.isProviderEnabled(provider: .antigravity, metadata: antigravity) == wasEnabled)
    }

    @Test
    func `settings action hidden for ordinary not logged in errors`() {
        let settings = self.makeSettings()
        let store = self.makeStore(settings: settings)
        store.errors[.gemini] = GeminiStatusProbeError.notLoggedIn.errorDescription
        store.observeGeminiConsumerTierDeprecation(from: GeminiStatusProbeError.notLoggedIn)

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
        store.observeGeminiConsumerTierDeprecation(from: GeminiStatusProbeError.notLoggedIn)

        let impl = GeminiProviderImplementation()
        let actions = impl.settingsActions(context: self.makeContext(settings: settings, store: store))

        #expect(actions.isEmpty)
    }

    @Test
    func `migration observation is store scoped and survives unrelated failures`() {
        let firstSettings = self.makeSettings()
        let firstStore = self.makeStore(settings: firstSettings)
        let secondSettings = self.makeSettings()
        let secondStore = self.makeStore(settings: secondSettings)

        firstStore.observeGeminiConsumerTierDeprecation(from: GeminiStatusProbeError.consumerTierDeprecated)
        firstStore.observeGeminiConsumerTierDeprecation(from: GeminiStatusProbeError.notLoggedIn)

        #expect(firstStore.geminiObservedConsumerTierDeprecation)
        #expect(!secondStore.geminiObservedConsumerTierDeprecation)

        firstStore.clearGeminiConsumerTierDeprecationObservation()
        #expect(!firstStore.geminiObservedConsumerTierDeprecation)
    }
}
