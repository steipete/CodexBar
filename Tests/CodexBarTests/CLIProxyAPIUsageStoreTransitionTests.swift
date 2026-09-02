import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension CLIProxyAPIUsageStoreTests {
    @Test
    func `startup missing credential isolates attribution from the former configuration`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .claude)
        var isolationGenerations: [String?] = []
        var refreshes: [(UsageProvider, Bool)] = []

        let collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .notConfigured,
            collectorState: CLIProxyAPIUsageCollectorState(
                configurationGeneration: "former-generation"),
            isExplicitlyDisconnected: { false },
            publishAttributionIsolation: { expectedGeneration in
                isolationGenerations.append(expectedGeneration)
                return true
            },
            configurationGeneration: { "former-generation" },
            refresh: { provider, force in
                refreshes.append((provider, force))
            })

        #expect(collectorState.configurationAvailability == .unavailable)
        #expect(collectorState.configurationGeneration == "former-generation")
        #expect(isolationGenerations == ["former-generation"])
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(refreshes.map(\.0) == [.claude, .codex])
        #expect(refreshes.map(\.1) == [true, true])
    }

    @Test
    func `stale collector replacement stays pending without publishing disconnect isolation`() async {
        let settings = testSettingsStore(suiteName: "CLIProxyAPIUsageStoreTests-\(UUID().uuidString)")
        settings.costUsageEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .codex)
        store.publishTokenSnapshot(Self.tokenSnapshot(), for: .claude)
        var refreshes: [(UsageProvider, Bool)] = []

        var collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .notConfigured,
            collectorState: CLIProxyAPIUsageCollectorState(
                configurationAvailability: .available,
                configurationGeneration: "old-generation"),
            isExplicitlyDisconnected: { false },
            publishAttributionIsolation: { _ in
                Issue.record("A superseded collector must not disconnect the replacement configuration.")
                return false
            },
            configurationGeneration: { "replacement-generation" },
            refresh: { provider, force in
                refreshes.append((provider, force))
            })

        #expect(collectorState.configurationAvailability == .unavailable)
        #expect(collectorState.configurationGeneration == "replacement-generation")
        #expect(collectorState.configurationTransitionPending)
        #expect(store.tokenSnapshot(for: .codex) == nil)
        #expect(store.tokenSnapshot(for: .claude) == nil)
        #expect(refreshes.isEmpty)

        collectorState = await store.handleCLIProxyAPIUsageCollectionResult(
            .collected(0),
            collectorState: collectorState,
            configurationGeneration: { "replacement-generation" },
            refresh: { provider, force in
                refreshes.append((provider, force))
            })

        #expect(collectorState.configurationAvailability == .available)
        #expect(!collectorState.configurationTransitionPending)
        #expect(refreshes.map(\.0) == [.claude, .codex])
        #expect(refreshes.map(\.1) == [true, true])
    }
}
