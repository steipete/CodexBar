import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct DeepgramProviderTests {
    @Test
    func `deepgram field kinds and bindings`() throws {
        let suite = "DeepgramProviderTests-field-kinds"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)

        let context = ProviderSettingsContext(
            provider: .deepgram,
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

        let implementation = DeepgramProviderImplementation()
        let fields = implementation.settingsFields(context: context)

        let apiField = try #require(fields.first(where: { $0.id == "deepgram-api-key" }))
        let projectField = try #require(fields.first(where: { $0.id == "deepgram-project-id" }))

        #expect(apiField.kind == .secure)
        #expect(projectField.kind == .plain)

        // Verify bindings update the SettingsStore
        apiField.binding.wrappedValue = "dg_test_token"
        #expect(settings.deepgramAPIToken == "dg_test_token")

        projectField.binding.wrappedValue = "proj-1234"
        #expect(settings.deepgramProjectID == "proj-1234")
    }
}
