import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct AugmentProviderRuntimeTests {
    @Test
    func `repeated stop only reports a running keepalive once`() throws {
        let suite = "AugmentProviderRuntimeTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore())
        let metadata = try #require(ProviderRegistry.shared.metadata[.augment])
        settings.setProviderEnabled(provider: .augment, metadata: metadata, enabled: true)

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let runtime = AugmentProviderRuntime()
        let context = ProviderRuntimeContext(provider: .augment, settings: settings, store: store)
        defer { runtime.stop(context: context) }

        runtime.start(context: context)
        #expect(runtime._test_isKeepaliveRunning)
        runtime.stop(context: context)
        settings.setProviderEnabled(provider: .augment, metadata: metadata, enabled: false)
        runtime.stop(context: context)
        runtime.settingsDidChange(context: context)

        #expect(!runtime._test_isKeepaliveRunning)
        #expect(runtime._test_keepaliveStopCount == 1)
    }
}
