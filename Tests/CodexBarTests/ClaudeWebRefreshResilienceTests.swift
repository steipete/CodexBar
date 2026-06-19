import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct ClaudeWebRefreshResilienceTests {
    @Test
    func `web unauthorized respects failure gate while keeping prior Claude snapshot`() async throws {
        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                let prior = Self.makePriorSnapshot()
                let store = try await MainActor.run {
                    try Self.makeStore(
                        suite: "ClaudeWebRefreshResilienceTests-web-unauthorized",
                        prior: prior)
                }

                await store.refreshProvider(.claude)
                let firstResult = await MainActor.run {
                    (
                        updatedAt: store.snapshot(for: .claude)?.updatedAt,
                        hasError: store.error(for: .claude) != nil)
                }

                #expect(firstResult.updatedAt == prior.updatedAt)
                #expect(!firstResult.hasError)

                await store.refreshProvider(.claude)
                let secondResult = await MainActor.run {
                    (
                        updatedAt: store.snapshot(for: .claude)?.updatedAt,
                        error: store.error(for: .claude))
                }

                #expect(secondResult.updatedAt == prior.updatedAt)
                #expect(secondResult.error == ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription)
            }
        }
    }

    @Test
    func `web unauthorized without prior Claude snapshot still surfaces failure`() async throws {
        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")

            try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                let store = try await MainActor.run {
                    try Self.makeStore(
                        suite: "ClaudeWebRefreshResilienceTests-web-unauthorized-no-prior",
                        prior: nil)
                }

                await store.refreshProvider(.claude)
                let result = await MainActor.run {
                    (
                        hasSnapshot: store.snapshot(for: .claude) != nil,
                        error: store.error(for: .claude))
                }

                #expect(!result.hasSnapshot)
                #expect(result.error == ClaudeWebAPIFetcher.FetchError.unauthorized.localizedDescription)
            }
        }
    }

    @MainActor
    private static func makeStore(suite: String, prior: UsageSnapshot?) throws -> UsageStore {
        let settings = self.makeSettingsStore(suite: suite)
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.claudeUsageDataSource = .web

        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            try settings.setProviderEnabled(
                provider: provider,
                metadata: #require(metadata[provider]),
                enabled: provider == .claude)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        if let prior {
            store._setSnapshotForTesting(prior, provider: .claude)
        }

        let baseSpec = try #require(store.providerSpecs[.claude])
        let descriptor = ProviderDescriptor(
            id: .claude,
            metadata: baseSpec.descriptor.metadata,
            branding: baseSpec.descriptor.branding,
            tokenCost: baseSpec.descriptor.tokenCost,
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.web],
                pipeline: ProviderFetchPipeline { _ in [ClaudeWebUnauthorizedFetchStrategy()] }),
            cli: baseSpec.descriptor.cli)
        store.providerSpecs[.claude] = ProviderSpec(
            style: baseSpec.style,
            isEnabled: baseSpec.isEnabled,
            descriptor: descriptor,
            makeFetchContext: baseSpec.makeFetchContext)
        return store
    }

    private static func makePriorSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 34,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: nil),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            identity: ProviderIdentitySnapshot(
                providerID: .claude,
                accountEmail: "claude@example.com",
                accountOrganization: nil,
                loginMethod: "Pro"))
    }

    @MainActor
    private static func makeSettingsStore(suite: String) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            kimiK2TokenStore: InMemoryKimiK2TokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        return settings
    }
}

private struct ClaudeWebUnauthorizedFetchStrategy: ProviderFetchStrategy {
    let id = "test.claude-web-unauthorized"
    let kind: ProviderFetchKind = .web

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        throw ClaudeWebAPIFetcher.FetchError.unauthorized
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
