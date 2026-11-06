import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStorePathDebugTests {
    @Test
    func `path diagnostics stay unloaded until requested`() async throws {
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
            startupBehavior: .testing)

        let diagnosticsWereLoaded = store.pathDebugInfo != .empty
        #expect(!diagnosticsWereLoaded)
        var loads = 0
        let snapshot = PathDebugSnapshot(
            codexBinary: "/synthetic/bin/codex",
            claudeBinary: nil,
            geminiBinary: nil,
            effectivePATH: "/synthetic/bin:/usr/bin",
            loginShellPATH: "/synthetic/bin")
        await store.refreshPathDebugInfo {
            loads += 1
            return snapshot
        }
        #expect(loads == 1)
        #expect(store.pathDebugInfo == snapshot)
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
