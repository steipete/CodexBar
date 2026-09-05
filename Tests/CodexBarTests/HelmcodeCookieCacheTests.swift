import Foundation
import SweetCookieKit
import Testing
@testable import CodexBarCore

/// Covers the `.auto` cookie-cache handoff: a validated dashboard session is persisted through
/// `CookieHeaderCache` scoped by deployment, and later resolutions (background refreshes, the
/// bundled CLI) run from the cached header without rereading the browser. Modeled on
/// `ZoomMateCookieCacheTests`.
@Suite(.serialized)
struct HelmcodeCookieCacheTests {
    private static let cachedHeader = "nan_session=fake-session-value"
    private static let quotaBody = #"""
    {"periodStart":"2026-09-01T00:00:00Z","models":[{"model":"helm-model-a","cap":1000000,"tokensUsed":250000}]}
    """#
    private static let creditsBody = #"{"balanceMicros":12500000,"currency":"eur"}"#

    private static func makeContext(
        runtime: ProviderRuntime,
        env: [String: String] = [:],
        settings: CodexBarCore.HelmcodeProviderSettings? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: .web,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 15,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings.map { snapshot in ProviderSettingsSnapshot.make(helmcode: snapshot) },
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static func successStub() -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            switch url.path {
            case "/api/usage/quota":
                return (Data(Self.quotaBody.utf8), response)
            case "/api/billing/credits":
                return (Data(Self.creditsBody.utf8), response)
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }
    }

    private static func clearBothScopes() {
        for deployment in HelmcodeDeployment.allCases {
            CookieHeaderCache.clear(provider: .helmcode, scope: HelmcodeWebFetchStrategy.cacheScope(deployment))
        }
    }

    private func withTestKeychainCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer {
            Self.clearBothScopes()
            KeychainCacheStore.setTestStoreForTesting(false)
        }
        return try await operation()
    }

    #if os(macOS)
    @Test
    func `cached header is reused without a browser read in cli runtime`() async throws {
        try await self.withTestKeychainCache {
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders),
                cookieHeader: Self.cachedHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
            let stub = Self.successStub()

            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(runtime: .cli, env: ["HELMCODE_DEPLOYMENT": "nan"])
            let available = await strategy.isAvailable(context)
            #expect(available == true)
            let result = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                try await strategy.fetch(context)
            }

            #expect(result.sourceLabel == "web")
            #expect(result.usage.primary?.resetDescription?.contains("helm-model-a") == true)
            let requests = await stub.requests()
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.url?.host == "cloud-api.nan.builders" })
            #expect(
                requests.first?.value(forHTTPHeaderField: "Cookie") == Self.cachedHeader)
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders)) != nil)
        }
    }

    @Test
    func `rejected cached session evicts the scoped entry and surfaces invalid session`() async throws {
        try await self.withTestKeychainCache {
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode),
                cookieHeader: Self.cachedHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
            let stub = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(#"{"error":"unauthenticated"}"#.utf8), response)
            }

            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(runtime: .cli)
            await #expect {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                    try await strategy.fetch(context)
                }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.invalidSession(.helmcode)
            }
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode)) == nil)
        }
    }

    @Test
    func `nan and helmcode cache scopes are isolated`() async throws {
        try await self.withTestKeychainCache {
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders),
                cookieHeader: Self.cachedHeader,
                sourceLabel: "Chrome Profile 1 (Test)")

            // The Helmcode Cloud scope has no entry: no import allowed in CLI runtime, so the
            // fetch fails with missingCookies while the NaN entry survives untouched.
            let stub = ProviderHTTPTransportStub { _ in
                Issue.record("Unexpected network request")
                throw URLError(.badURL)
            }
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(runtime: .cli, env: ["HELMCODE_DEPLOYMENT": "helmcode"])
            await #expect {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                    try await strategy.fetch(context)
                }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookies(.helmcode)
            }
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders))?.cookieHeader ==
                    Self.cachedHeader)
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode)) == nil)
        }
    }

    @Test
    func `off and manual modes never touch the cache`() async throws {
        try await self.withTestKeychainCache {
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode),
                cookieHeader: Self.cachedHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
            let stub = ProviderHTTPTransportStub { _ in
                Issue.record("Unexpected network request")
                throw URLError(.badURL)
            }
            let strategy = HelmcodeWebFetchStrategy()

            let offContext = Self.makeContext(
                runtime: .cli,
                env: ["HELMCODE_COOKIE": "session=env-value"],
                settings: HelmcodeProviderSettings(cookieSource: .off, manualCookieHeader: nil))
            #expect(await strategy.isAvailable(offContext) == false)
            await #expect {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                    try await strategy.fetch(offContext)
                }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookies(.helmcode)
            }

            let manualContext = Self.makeContext(
                runtime: .cli,
                settings: HelmcodeProviderSettings(cookieSource: .manual, manualCookieHeader: ""))
            #expect(await strategy.isAvailable(manualContext) == false)
            await #expect {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                    try await strategy.fetch(manualContext)
                }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookies(.helmcode)
            }

            // Neither mode rewrote or evicted the persisted entry.
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode))?.cookieHeader ==
                    Self.cachedHeader)
        }
    }

    @Test
    func `successful import stores the header under the deployment scope`() async throws {
        try await self.withTestKeychainCache {
            let record = BrowserCookieRecord(
                domain: "nan.builders",
                name: "nan_session",
                path: "/",
                value: "imported-value",
                expires: Date(timeIntervalSince1970: 1_900_000_000),
                isSecure: true,
                isHTTPOnly: true,
                scope: .domain)
            let session = HelmcodeCookieImporter.SessionInfo(
                cookies: HelmcodeCookieImporter.makeCookies(from: [record]),
                sourceLabel: "Chrome Profile 1 (Test)")
            let stub = Self.successStub()

            let fetched = try await HelmcodeWebFetchStrategy.fetchAndCacheSession(
                session,
                deployment: .nanBuilders,
                transport: stub)

            #expect(fetched.toUsageSnapshot().primary?.resetDescription?.contains("helm-model-a") == true)
            let cached = CookieHeaderCache.load(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders))
            #expect(cached?.cookieHeader == "nan_session=imported-value")
            #expect(cached?.sourceLabel == "Chrome Profile 1 (Test)")
        }
    }
    #endif
}
