import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct DeepSeekProfileTransitionTests {
    @Test(arguments: [false, true])
    func `forced web profile transition clears stale balance with an api key`(
        isCancellation: Bool) async throws
    {
        let apiKey = "test-deepseek-api-key"
        let suite = "DeepSeekProfileTransitionTests-forced-web-\(isCancellation)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.updateProviderConfig(provider: .deepseek) { $0.source = .web }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [DeepSeekSettingsReader.apiKeyEnvironmentKey: apiKey])
        store.snapshots[.deepseek] = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$8.06 from previous profile"),
            secondary: nil,
            deepseekPlatformProfiles: [
                DeepSeekPlatformProfile(id: "chrome:Default", name: "Chrome — Personal"),
                DeepSeekPlatformProfile(id: "chrome:Profile 2", name: "Chrome — Work"),
            ],
            updatedAt: Date())

        let context = Self.settingsContext(settings: settings, store: store)
        let picker = try #require(DeepSeekProviderImplementation().settingsPickers(context: context).first)
        picker.binding.wrappedValue = "chrome:Profile 2"

        #expect(store.deepseekProfileTransitionSnapshot?.primary?.resetDescription == "Refreshing")
        #expect(store.deepseekProfileTransitionSnapshot?.primary?.resetDescription?.contains("$8.06") == false)

        let outcome = if isCancellation {
            ProviderFetchOutcome(result: .failure(CancellationError()), attempts: [])
        } else {
            ProviderFetchOutcome(result: .failure(DeepSeekUsageError.apiError("offline")), attempts: [])
        }
        await store.applySelectedOutcome(outcome, provider: .deepseek, account: nil, fallbackSnapshot: nil)

        #expect(store.deepseekProfileTransitionSnapshot?.primary?.resetDescription == "Unavailable")
        #expect(store.deepseekProfileTransitionSnapshot?.primary?.resetDescription?.contains("$8.06") == false)
    }

    private static func settingsContext(
        settings: SettingsStore,
        store: UsageStore) -> ProviderSettingsContext
    {
        ProviderSettingsContext(
            provider: .deepseek,
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
}
