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
}
