import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct UsageStorePathDebugTests {
    @Test
    func refreshPathDebugInfoPopulatesSnapshot() async throws {
        let suite = "UsageStorePathDebugTests-path"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let deadline = Date().addingTimeInterval(2)
        while store.pathDebugInfo == .empty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(store.pathDebugInfo != .empty)
        #expect(store.pathDebugInfo.effectivePATH.isEmpty == false)
    }
}
