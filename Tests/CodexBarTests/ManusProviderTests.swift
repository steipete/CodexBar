import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ManusProviderTests {
    private static let now = Date(timeIntervalSince1970: 1_744_000_000)

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

    private func stubResponse() -> ManusCreditsResponse {
        ManusCreditsResponse(
            totalCredits: 120,
            freeCredits: 20,
            periodicCredits: 80,
            addonCredits: 10,
            refreshCredits: 30,
            maxRefreshCredits: 300,
            proMonthlyCredits: 100,
            eventCredits: 10,
            nextRefreshTime: Date(timeIntervalSince1970: 1_744_003_600),
            refreshInterval: "daily")
    }

    private func withIsolatedCacheStore<T>(operation: () async throws -> T) async rethrows -> T {
        let service = "manus-provider-tests-\(UUID().uuidString)"
        return try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            return try await operation()
        }
    }

    @Test
    func `off mode ignores environment session token`() async {
        let strategy = ManusWebFetchStrategy()
        let settings = ProviderSettingsSnapshot.make(
            manus: ProviderSettingsSnapshot.ManusProviderSettings(
                cookieSource: .off,
                manualCookieHeader: nil))
        let context = self.makeContext(
            settings: settings,
            env: ["MANUS_SESSION_TOKEN": "env-token"])

        #expect(await strategy.isAvailable(context) == false)
    }

    @Test
    func `manual mode invalid cookie does not fall back to cache or environment`() async {
        await self.withIsolatedCacheStore {
            CookieHeaderCache.store(
                provider: .manus,
                cookieHeader: "session_id=cached-token",
                sourceLabel: "web")

            let strategy = ManusWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                manus: ProviderSettingsSnapshot.ManusProviderSettings(
                    cookieSource: .manual,
                    manualCookieHeader: "foo=bar"))
            let context = self.makeContext(
                settings: settings,
                env: ["MANUS_SESSION_TOKEN": "env-token"])

            do {
                _ = try await strategy.fetch(context)
                Issue.record("Expected invalid manual cookie instead of falling back to cache/environment")
            } catch let error as ManusAPIError {
                #expect(error == .invalidCookie)
            } catch {
                Issue.record("Expected ManusAPIError.invalidCookie, got \(error)")
            }
        }
    }

    @Test
    func `environment token does not populate browser cache`() async throws {
        try await self.withIsolatedCacheStore {
            #if os(macOS)
            ManusCookieImporter.importSessionsOverrideForTesting = { _, _ in
                throw ManusCookieImportError.noCookies
            }
            ManusCookieImporter.importSessionOverrideForTesting = nil
            defer {
                ManusCookieImporter.importSessionsOverrideForTesting = nil
                ManusCookieImporter.importSessionOverrideForTesting = nil
            }
            #endif

            let strategy = ManusWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                manus: ProviderSettingsSnapshot.ManusProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = self.makeContext(
                settings: settings,
                env: ["MANUS_SESSION_TOKEN": "env-token"])
            let fetchOverride: @Sendable (String, Date) async throws -> ManusCreditsResponse = { token, _ in
                #expect(token == "env-token")
                return self.stubResponse()
            }

            _ = try await ManusUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                try await strategy.fetch(context)
            })

            #expect(CookieHeaderCache.load(provider: .manus) == nil)
        }
    }

    #if os(macOS)
    @Test
    func `invalid browser token falls back to environment token`() async throws {
        try await self.withIsolatedCacheStore {
            let browserCookie = try #require(HTTPCookie(properties: [
                .domain: "manus.im",
                .path: "/",
                .name: "session_id",
                .value: "browser-token",
                .secure: "TRUE",
            ]))
            ManusCookieImporter.importSessionOverrideForTesting = { _, _ in
                ManusCookieImporter.SessionInfo(cookies: [browserCookie], sourceLabel: "Chrome")
            }
            ManusCookieImporter.importSessionsOverrideForTesting = nil
            defer {
                ManusCookieImporter.importSessionOverrideForTesting = nil
                ManusCookieImporter.importSessionsOverrideForTesting = nil
            }

            let attempts = LockedArray<String>()
            let strategy = ManusWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                manus: ProviderSettingsSnapshot.ManusProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = self.makeContext(
                settings: settings,
                env: ["MANUS_SESSION_TOKEN": "env-token"])
            let fetchOverride: @Sendable (String, Date) async throws -> ManusCreditsResponse = { token, _ in
                attempts.append(token)
                if token == "browser-token" {
                    throw ManusAPIError.invalidToken
                }
                #expect(token == "env-token")
                return self.stubResponse()
            }

            _ = try await ManusUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                try await strategy.fetch(context)
            })

            #expect(attempts.snapshot() == ["browser-token", "env-token"])
            #expect(CookieHeaderCache.load(provider: .manus) == nil)
        }
    }

    @Test
    func `browser token populates cache after successful fetch`() async throws {
        try await self.withIsolatedCacheStore {
            let browserCookie = try #require(HTTPCookie(properties: [
                .domain: "manus.im",
                .path: "/",
                .name: "session_id",
                .value: "browser-token",
                .secure: "TRUE",
            ]))
            ManusCookieImporter.importSessionOverrideForTesting = { _, _ in
                ManusCookieImporter.SessionInfo(cookies: [browserCookie], sourceLabel: "Chrome")
            }
            ManusCookieImporter.importSessionsOverrideForTesting = nil
            defer {
                ManusCookieImporter.importSessionOverrideForTesting = nil
                ManusCookieImporter.importSessionsOverrideForTesting = nil
            }

            let strategy = ManusWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                manus: ProviderSettingsSnapshot.ManusProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = self.makeContext(settings: settings)
            let fetchOverride: @Sendable (String, Date) async throws -> ManusCreditsResponse = { token, _ in
                #expect(token == "browser-token")
                return self.stubResponse()
            }

            _ = try await ManusUsageFetcher.$fetchCreditsOverride.withValue(fetchOverride, operation: {
                try await strategy.fetch(context)
            })

            let cached = CookieHeaderCache.load(provider: .manus)
            #expect(cached?.cookieHeader == "session_id=browser-token")
        }
    }
    #endif

    @Test
    func `settings reader accepts full cookie header from environment`() {
        let env = ["MANUS_COOKIE": "foo=bar; session_id=env-cookie-token; baz=qux"]
        #expect(ManusSettingsReader.sessionToken(environment: env) == "env-cookie-token")
    }

    @Test
    func `parse response tolerates sparse live payload`() throws {
        let data = Data("""
        {
          "totalCredits": 2869,
          "freeCredits": 1500,
          "periodicCredits": 1369,
          "proMonthlyCredits": 4000,
          "maxRefreshCredits": 300,
          "nextRefreshTime": "2026-04-13T00:00:00Z",
          "refreshInterval": "daily",
          "userFlag": { "drc16": true }
        }
        """.utf8)

        let response = try ManusUsageFetcher.parseResponse(data)
        #expect(response.totalCredits == 2869)
        #expect(response.periodicCredits == 1369)
        #expect(response.proMonthlyCredits == 4000)
        #expect(response.refreshCredits == 0)
        #expect(response.addonCredits == 0)
        #expect(response.maxRefreshCredits == 300)
        #expect(response.nextRefreshTime != nil)

        let snapshot = response.toUsageSnapshot(now: Self.now)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.primary?.usedPercent ?? 0 > 65)
        #expect(snapshot.primary?.resetDescription == "Total 2,869 • Free 1,500")
        #expect(snapshot.secondary?.usedPercent == 100)
        #expect(snapshot.secondary?.resetDescription == "Daily: 0 / 300")
    }

    @Test
    func `parse response rejects payload without credits fields`() {
        let data = Data(#"{"error":"unauthorized","message":"session expired"}"#.utf8)

        #expect(throws: ManusAPIError.self) {
            try ManusUsageFetcher.parseResponse(data)
        }
    }

    @Test
    func `parse response accepts wrapped envelope`() throws {
        let data = Data("""
        {
          "data": {
            "totalCredits": 100,
            "proMonthlyCredits": 200,
            "periodicCredits": 50,
            "maxRefreshCredits": 10,
            "refreshCredits": 5
          }
        }
        """.utf8)

        let response = try ManusUsageFetcher.parseResponse(data)
        #expect(response.totalCredits == 100)
        #expect(response.periodicCredits == 50)
    }
}
