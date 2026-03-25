import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PerplexityProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_740_000_000)

    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    private func makeContext(
        settings: ProviderSettingsSnapshot?,
        env: [String: String] = [:]) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private func stubSnapshot(now: Date = Self.now) -> PerplexityUsageSnapshot {
        PerplexityUsageSnapshot(
            response: PerplexityCreditsResponse(
                balanceCents: 500,
                renewalDateTs: now.addingTimeInterval(3600).timeIntervalSince1970,
                currentPeriodPurchasedCents: 0,
                creditGrants: [
                    PerplexityCreditGrant(type: "recurring", amountCents: 1000, expiresAtTs: nil),
                ],
                totalUsageCents: 500),
            now: now)
    }

    private func withIsolatedCacheStore<T>(operation: () async throws -> T) async rethrows -> T {
        let service = "perplexity-provider-tests-\(UUID().uuidString)"
        return try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            return try await operation()
        }
    }

    @Test
    func offModeIgnoresEnvironmentSessionCookie() async {
        let strategy = PerplexityWebFetchStrategy()
        let settings = ProviderSettingsSnapshot.make(
            perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                cookieSource: .off,
                manualCookieHeader: nil))
        let context = self.makeContext(
            settings: settings,
            env: ["PERPLEXITY_COOKIE": "authjs.session-token=env-token"])

        #expect(await strategy.isAvailable(context) == false)
    }

    @Test
    func manualModeInvalidCookieDoesNotFallBackToCacheOrEnvironment() async {
        await self.withIsolatedCacheStore {
            CookieHeaderCache.store(
                provider: .perplexity,
                cookieHeader: "\(PerplexityCookieHeader.defaultSessionCookieName)=cached-token",
                sourceLabel: "web")

            let strategy = PerplexityWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                    cookieSource: .manual,
                    manualCookieHeader: "foo=bar"))
            let context = self.makeContext(
                settings: settings,
                env: ["PERPLEXITY_COOKIE": "authjs.session-token=env-token"])

            do {
                _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue { _, _, _ in
                    self.stubSnapshot()
                } operation: {
                    try await strategy.fetch(context)
                }
                Issue.record("Expected invalid manual-cookie error instead of falling back to cache/environment")
            } catch let error as PerplexityAPIError {
                #expect(error == .invalidCookie)
            } catch {
                Issue.record("Expected PerplexityAPIError.invalidCookie, got \(error)")
            }
        }
    }

    @Test
    func environmentTokenDoesNotPopulateBrowserCookieCache() async throws {
        try await self.withIsolatedCacheStore {
            PerplexityCookieImporter.importSessionOverrideForTesting = { _, _ in
                throw PerplexityCookieImportError.noCookies
            }
            defer {
                PerplexityCookieImporter.importSessionOverrideForTesting = nil
            }

            let strategy = PerplexityWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = self.makeContext(
                settings: settings,
                env: ["PERPLEXITY_COOKIE": "authjs.session-token=env-token"])

            _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue { _, _, _ in
                self.stubSnapshot()
            } operation: {
                try await strategy.fetch(context)
            }

            #expect(CookieHeaderCache.load(provider: .perplexity) == nil)
        }
    }

    @Test
    func manualTokenDoesNotPopulateBrowserCookieCache() async throws {
        try await self.withIsolatedCacheStore {
            let strategy = PerplexityWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                    cookieSource: .manual,
                    manualCookieHeader: "authjs.session-token=manual-token"))
            let context = self.makeContext(settings: settings)

            _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue { _, _, _ in
                self.stubSnapshot()
            } operation: {
                try await strategy.fetch(context)
            }

            #expect(CookieHeaderCache.load(provider: .perplexity) == nil)
        }
    }
}
