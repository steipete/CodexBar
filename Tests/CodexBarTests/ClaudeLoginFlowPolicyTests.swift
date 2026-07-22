import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct ClaudeLoginFlowTests {
    @Test
    func `successful Claude login controller flow preserves selected source and enables provider`() async throws {
        let registry = ProviderRegistry.shared
        let claudeMetadata = try #require(registry.metadata[.claude])

        for source in ClaudeUsageDataSource.allCases {
            let settings = testSettingsStore(
                suiteName: "ClaudeLoginFlowTests-controller-\(source.rawValue)")
            settings.statusChecksEnabled = false
            settings.refreshFrequency = .manual
            settings.providerDetectionCompleted = true
            settings.claudeUsageDataSource = source
            settings.setProviderEnabled(provider: .claude, metadata: claudeMetadata, enabled: false)

            let fetcher = UsageFetcher()
            let store = UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings)

            await withStatusItemControllerForTesting(store: store, settings: settings, fetcher: fetcher) { controller in
                let didLogin = await controller.runClaudeLoginFlow { _, onPhaseChange in
                    onPhaseChange(.requesting)
                    await Task.yield()
                    onPhaseChange(.waitingBrowser)
                    await Task.yield()
                    return ClaudeLoginRunner.Result(
                        outcome: .success,
                        output: "Successfully logged in",
                        authLink: nil)
                }

                #expect(didLogin)
                #expect(controller.loginPhase == .idle)
            }

            #expect(settings.claudeUsageDataSource == source)
            #expect(settings.isProviderEnabledCached(provider: .claude, metadataByProvider: registry.metadata))
        }
    }
}
