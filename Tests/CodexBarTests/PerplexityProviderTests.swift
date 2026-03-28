import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct PerplexityProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_740_000_000)

    private final class LockedArray<Element>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Element] = []

        func append(_ value: Element) {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.values.append(value)
        }

        func snapshot() -> [Element] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0

        func increment() {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.value += 1
        }

        func snapshot() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

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
            let fetchOverride: @Sendable (String, String, Date) async throws -> PerplexityUsageSnapshot = { _, _, _ in
                self.stubSnapshot()
            }

            do {
                _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                    try await strategy.fetch(context)
                })
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
            PerplexityCookieImporter.invalidateImportSessionCache()
            PerplexityCookieImporter.importSessionsOverrideForTesting = nil
            PerplexityCookieImporter.importSessionOverrideForTesting = { _, _ in
                throw PerplexityCookieImportError.noCookies
            }
            defer {
                PerplexityCookieImporter.importSessionsOverrideForTesting = nil
                PerplexityCookieImporter.importSessionOverrideForTesting = nil
                PerplexityCookieImporter.invalidateImportSessionCache()
            }

            let strategy = PerplexityWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = self.makeContext(
                settings: settings,
                env: ["PERPLEXITY_COOKIE": "authjs.session-token=env-token"])
            let fetchOverride: @Sendable (String, String, Date) async throws -> PerplexityUsageSnapshot = { _, _, _ in
                self.stubSnapshot()
            }

            _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                try await strategy.fetch(context)
            })

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
            let fetchOverride: @Sendable (String, String, Date) async throws -> PerplexityUsageSnapshot = { _, _, _ in
                self.stubSnapshot()
            }

            _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                try await strategy.fetch(context)
            })

            #expect(CookieHeaderCache.load(provider: .perplexity) == nil)
        }
    }

    @Test
    func bareEnvironmentTokenFallsBackToAuthJSCookieName() async throws {
        try await self.withIsolatedCacheStore {
            PerplexityCookieImporter.invalidateImportSessionCache()
            PerplexityCookieImporter.importSessionsOverrideForTesting = nil
            PerplexityCookieImporter.importSessionOverrideForTesting = { _, _ in
                throw PerplexityCookieImportError.noCookies
            }
            defer {
                PerplexityCookieImporter.importSessionsOverrideForTesting = nil
                PerplexityCookieImporter.importSessionOverrideForTesting = nil
                PerplexityCookieImporter.invalidateImportSessionCache()
            }

            let attemptedCookieNames = LockedArray<String>()
            let strategy = PerplexityWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = self.makeContext(
                settings: settings,
                env: ["PERPLEXITY_SESSION_TOKEN": "env-token"])
            let fetchOverride: @Sendable (String, String, Date) async throws
                -> PerplexityUsageSnapshot = { token, cookieName, _ in
                    #expect(token == "env-token")
                    attemptedCookieNames.append(cookieName)
                    if cookieName == "authjs.session-token" {
                        return self.stubSnapshot()
                    }
                    throw PerplexityAPIError.invalidToken
                }

            _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                try await strategy.fetch(context)
            })

            #expect(attemptedCookieNames.snapshot() == [
                "__Secure-authjs.session-token",
                "authjs.session-token",
            ])
        }
    }

    @Test
    func validEnvironmentCookieWinsAfterInvalidBrowserSession() async throws {
        try await self.withIsolatedCacheStore {
            PerplexityCookieImporter.invalidateImportSessionCache()
            PerplexityCookieImporter.importSessionsOverrideForTesting = nil
            PerplexityCookieImporter.importSessionOverrideForTesting = { _, _ in
                let cookie = try #require(HTTPCookie(properties: [
                    .domain: "www.perplexity.ai",
                    .path: "/",
                    .name: PerplexityCookieHeader.defaultSessionCookieName,
                    .value: "browser-token",
                    .secure: "TRUE",
                ]))
                return PerplexityCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Chrome")
            }
            defer {
                PerplexityCookieImporter.importSessionsOverrideForTesting = nil
                PerplexityCookieImporter.importSessionOverrideForTesting = nil
                PerplexityCookieImporter.invalidateImportSessionCache()
            }

            let attemptedTokens = LockedArray<String>()
            let strategy = PerplexityWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = self.makeContext(
                settings: settings,
                env: ["PERPLEXITY_COOKIE": "authjs.session-token=env-token"])
            let fetchOverride: @Sendable (String, String, Date) async throws
                -> PerplexityUsageSnapshot = { token, _, _ in
                    attemptedTokens.append(token)
                    if token == "browser-token" {
                        throw PerplexityAPIError.invalidToken
                    }
                    if token == "env-token" {
                        return self.stubSnapshot()
                    }
                    Issue.record("Unexpected token \(token)")
                    throw PerplexityAPIError.invalidToken
                }

            _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                try await strategy.fetch(context)
            })

            #expect(attemptedTokens.snapshot() == ["browser-token", "env-token"])
        }
    }

    @Test
    func laterBrowserSessionWinsAfterEarlierImportedSessionFailsAuth() async throws {
        try await self.withIsolatedCacheStore {
            PerplexityCookieImporter.invalidateImportSessionCache()
            PerplexityCookieImporter.importSessionOverrideForTesting = nil
            PerplexityCookieImporter.importSessionsOverrideForTesting = { _, _ in
                let staleCookie = try #require(HTTPCookie(properties: [
                    .domain: "www.perplexity.ai",
                    .path: "/",
                    .name: "__Secure-authjs.session-token",
                    .value: "stale-browser-token",
                    .secure: "TRUE",
                ]))
                let liveCookie = try #require(HTTPCookie(properties: [
                    .domain: "www.perplexity.ai",
                    .path: "/",
                    .name: "__Secure-authjs.session-token",
                    .value: "live-browser-token",
                    .secure: "TRUE",
                ]))
                return [
                    PerplexityCookieImporter.SessionInfo(cookies: [staleCookie], sourceLabel: "Chrome"),
                    PerplexityCookieImporter.SessionInfo(cookies: [liveCookie], sourceLabel: "Safari"),
                ]
            }
            defer {
                PerplexityCookieImporter.importSessionsOverrideForTesting = nil
                PerplexityCookieImporter.importSessionOverrideForTesting = nil
                PerplexityCookieImporter.invalidateImportSessionCache()
            }

            let attemptedTokens = LockedArray<String>()
            let strategy = PerplexityWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = self.makeContext(settings: settings)
            let fetchOverride: @Sendable (String, String, Date) async throws
                -> PerplexityUsageSnapshot = { token, _, _ in
                    attemptedTokens.append(token)
                    if token == "stale-browser-token" {
                        throw PerplexityAPIError.invalidToken
                    }
                    if token == "live-browser-token" {
                        return self.stubSnapshot()
                    }
                    Issue.record("Unexpected token \(token)")
                    throw PerplexityAPIError.invalidToken
                }

            _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                try await strategy.fetch(context)
            })

            #expect(attemptedTokens.snapshot() == ["stale-browser-token", "live-browser-token"])
        }
    }

    @Test
    func autoModeReusesBrowserImportBetweenAvailabilityAndFetch() async throws {
        try await self.withIsolatedCacheStore {
            let importCount = LockedCounter()
            PerplexityCookieImporter.invalidateImportSessionCache()
            PerplexityCookieImporter.importSessionsOverrideForTesting = nil
            PerplexityCookieImporter.importSessionOverrideForTesting = { _, _ in
                importCount.increment()
                let cookie = try #require(HTTPCookie(properties: [
                    .domain: "www.perplexity.ai",
                    .path: "/",
                    .name: PerplexityCookieHeader.defaultSessionCookieName,
                    .value: "browser-token",
                    .secure: "TRUE",
                ]))
                return PerplexityCookieImporter.SessionInfo(cookies: [cookie], sourceLabel: "Chrome")
            }
            defer {
                PerplexityCookieImporter.importSessionsOverrideForTesting = nil
                PerplexityCookieImporter.importSessionOverrideForTesting = nil
                PerplexityCookieImporter.invalidateImportSessionCache()
            }

            let strategy = PerplexityWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                perplexity: ProviderSettingsSnapshot.PerplexityProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = self.makeContext(settings: settings)
            let fetchOverride: @Sendable (String, String, Date) async throws
                -> PerplexityUsageSnapshot = { token, _, _ in
                    #expect(token == "browser-token")
                    return self.stubSnapshot()
                }

            #expect(await strategy.isAvailable(context))

            _ = try await PerplexityUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                try await strategy.fetch(context)
            })

            #expect(importCount.snapshot() == 1)
        }
    }
}
