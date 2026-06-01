import CodexBarCore
import XCTest
@testable import CodexBar

@MainActor
final class AugmentProviderRuntimeTests: XCTestCase {
    func test_disabledStopIsIdempotent() {
        let suite = "AugmentProviderRuntimeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore())
        if let metadata = ProviderRegistry.shared.metadata[.augment] {
            settings.setProviderEnabled(provider: .augment, metadata: metadata, enabled: false)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        let runtime = AugmentProviderRuntime()
        let context = ProviderRuntimeContext(provider: .augment, settings: settings, store: store)

        runtime.stop(context: context)
        runtime.stop(context: context)
        runtime.settingsDidChange(context: context)

        XCTAssertFalse(store.isEnabled(.augment))
    }
}
