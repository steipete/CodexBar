import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStorePathDebugTests {
    @Test
    func `refresh path debug info populates snapshot`() async throws {
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
            settings: settings,
            startupBehavior: .full)

        let deadline = Date().addingTimeInterval(2)
        while store.pathDebugInfo == .empty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        #expect(store.pathDebugInfo != .empty)
        #expect(store.pathDebugInfo.effectivePATH.isEmpty == false)
    }

    @Test
    func `deepseek debug log includes selected token account`() async throws {
        let suite = "UsageStorePathDebugTests-deepseek-debug-token-account"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())
        settings.addTokenAccount(provider: .deepseek, label: "Primary", token: "sk-deepseek-test")
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])

        let debugLog = await store.debugLog(for: UsageProvider.deepseek)

        #expect(debugLog == "DEEPSEEK_API_KEY=present source=settings-token-account")
    }
}
