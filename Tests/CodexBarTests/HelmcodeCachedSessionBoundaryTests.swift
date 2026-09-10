import Foundation
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Continuation of `HelmcodeDeploymentDetectionTests` (same serialized suite: the cookie cache is
/// process-global, so cache-touching tests must not run against parallel suites). Split out only to
/// keep each file within the repo's type-body-length limit.
extension HelmcodeDeploymentDetectionTests {
    // MARK: - Session fetch seams

    // (macOS: the importer seam touches SweetCookieKit browser stores.)
    #if os(macOS)

    @Test
    func `imported session fetch skips a rejected session and persists records`() async throws {
        try await self.withTestKeychainCache {
            let stub = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                if request.value(forHTTPHeaderField: "Cookie") == "session=expired" {
                    return try Self.response(url: url, status: 401, body: Self.unauthenticatedBody())
                }
                return try Self.response(url: url, body: Self.quotaFixture())
            }
            let sessions = try [
                Self.makeSession(cookieHeader: "session=expired", value: "expired"),
                Self.makeSession(cookieHeader: "session=fresh", value: "fresh"),
            ]

            let snapshot = try await HelmcodeWebFetchStrategy.fetchImportedSessions(
                sessions,
                deployment: .helmcode)
            { session in
                try await HelmcodeWebFetchStrategy.fetchAndCacheSession(
                    session,
                    deployment: .helmcode,
                    transport: stub)
            }

            #expect(snapshot.toUsageSnapshot().primary?.resetDescription?.contains("glm5.3-flash") == true)
            let cached = HelmcodeCachedSession.decode(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode))?.cookieHeader ?? "")
            #expect(cached?.cookies.first?.name == "session")
            #expect(cached?.cookies.first?.value == "fresh")
        }
    }

    @Test
    func `imported session fetch stops at an api error instead of trying the next session`() async throws {
        try await self.withTestKeychainCache {
            let stub = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                if request.value(forHTTPHeaderField: "Cookie") == "session=expired" {
                    return try Self.response(url: url, status: 401, body: Self.unauthenticatedBody())
                }
                return try Self.response(url: url, status: 500, body: Data(#"{"error":"boom"}"#.utf8))
            }
            let sessions = try [
                Self.makeSession(cookieHeader: "session=expired", value: "expired"),
                Self.makeSession(cookieHeader: "session=broken", value: "broken"),
            ]

            await #expect {
                _ = try await HelmcodeWebFetchStrategy.fetchImportedSessions(
                    sessions,
                    deployment: .helmcode)
                { session in
                    try await HelmcodeWebFetchStrategy.fetchAndCacheSession(
                        session,
                        deployment: .helmcode,
                        transport: stub)
                }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.apiError(500)
            }
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode)) == nil)
        }
    }

    // MARK: - Cache behavior (round 1)

    @Test
    func `cached header is reused without a browser read in cli runtime`() async throws {
        try await self.withTestKeychainCache {
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "nan_session", value: "fake-nan-value", domain: "nan.builders"),
            ])
            let stub = Self.successStub(expectedHost: "cloud-api.nan.builders")

            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(runtime: .cli, env: ["HELMCODE_DEPLOYMENT": "nan"])
            let available = await strategy.isAvailable(context)
            #expect(available == true)
            let result = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                try await strategy.fetch(context)
            }

            #expect(result.sourceLabel == "web · NaN Builders")
            #expect(result.usage.primary?.resetDescription?.contains("helm-model-a") == true)
            let requests = await stub.requests()
            #expect(requests.count == 3)
            #expect(requests.allSatisfy { $0.url?.host == "cloud-api.nan.builders" })
            #expect(requests.first?.value(forHTTPHeaderField: "Cookie") == "nan_session=fake-nan-value")
        }
    }

    @Test
    func `nan and helmcode cache scopes are isolated`() async throws {
        try await self.withTestKeychainCache {
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "nan_session", value: "fake-nan-value", domain: "nan.builders"),
            ])

            // The Helmcode Cloud scope has no entry: no import allowed in CLI runtime, so the
            // fetch fails while the NaN entry survives untouched.
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(runtime: .cli, env: ["HELMCODE_DEPLOYMENT": "helmcode"])
            await #expect {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting
                    .withValue(Self.unexpectedNetworkStub()) {
                        try await strategy.fetch(context)
                    }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookies(.helmcode)
            }
            #expect(
                HelmcodeCachedSession.decode(
                    CookieHeaderCache.load(
                        provider: .helmcode,
                        scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders))?.cookieHeader ?? "")?.cookies.first?
                    .value == "fake-nan-value")
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode)) == nil)
        }
    }

    @Test
    func `off and manual modes never touch the cache`() async throws {
        try await self.withTestKeychainCache {
            Self.storeCachedSession(.helmcode, cookies: [
                Self.record(name: "session", value: "fake-helmcode-value", domain: "helmcode.com"),
            ])
            let strategy = HelmcodeWebFetchStrategy()

            let offContext = Self.makeContext(
                runtime: .cli,
                env: ["HELMCODE_COOKIE": "session=env-value"],
                settings: HelmcodeProviderSettings(cookieSource: .off, manualCookieHeader: nil))
            #expect(await strategy.isAvailable(offContext) == false)
            #expect(HelmcodeCookieHeader.selectCredential(context: offContext) == nil)
            await #expect {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting
                    .withValue(Self.unexpectedNetworkStub()) {
                        try await strategy.fetch(offContext)
                    }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookiesAny
            }

            let manualContext = Self.makeContext(
                runtime: .cli,
                settings: HelmcodeProviderSettings(cookieSource: .manual, manualCookieHeader: ""))
            #expect(await strategy.isAvailable(manualContext) == false)
            await #expect {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting
                    .withValue(Self.unexpectedNetworkStub()) {
                        try await strategy.fetch(manualContext)
                    }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookiesAny
            }

            // Neither mode rewrote or evicted the persisted entry.
            #expect(
                HelmcodeCachedSession.decode(
                    CookieHeaderCache.load(
                        provider: .helmcode,
                        scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode))?.cookieHeader ?? "")?.cookies.first?
                    .value == "fake-helmcode-value")
        }
    }

    @Test
    func `successful import stores records under the deployment scope`() async throws {
        try await self.withTestKeychainCache {
            let session = Self.session(
                cookieHeader: "nan_session=imported-value",
                name: "nan_session",
                domain: "nan.builders")
            let stub = Self.successStub(expectedHost: "cloud-api.nan.builders")

            let fetched = try await HelmcodeWebFetchStrategy.fetchAndCacheSession(
                session,
                deployment: .nanBuilders,
                transport: stub)

            #expect(fetched.toUsageSnapshot().primary?.resetDescription?.contains("helm-model-a") == true)
            let cached = HelmcodeCachedSession.decode(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders))?.cookieHeader ?? "")
            #expect(cached?.cookies.first?.name == "nan_session")
            #expect(cached?.cookies.first?.value == "fixture")
            #expect(cached?.cookies.first?.domain == ".nan.builders")
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders))?.sourceLabel ==
                    "Chrome Profile 1 (Test)")
        }
    }

    @Test
    func `strategy is unavailable without an override cache or browser session`() async throws {
        try await self.withTestKeychainCache {
            let strategy = HelmcodeWebFetchStrategy()

            let cliContext = Self.makeContext(runtime: .cli)
            #expect(await strategy.isAvailable(cliContext) == false)

            await ProviderInteractionContext.$current.withValue(.background) {
                let appContext = Self.makeContext(runtime: .app)
                #expect(await strategy.isAvailable(appContext) == false)
            }
        }
    }

    @Test
    func `off deployment yields no override even with environment cookie`() async throws {
        try await self.withTestKeychainCache {
            let strategy = HelmcodeWebFetchStrategy()
            let offContext = Self.makeContext(
                runtime: .cli,
                env: ["HELMCODE_COOKIE": "session=env-value"],
                settings: HelmcodeProviderSettings(cookieSource: .off, manualCookieHeader: nil))
            #expect(await strategy.isAvailable(offContext) == false)
            #expect(HelmcodeCookieHeader.selectCredential(context: offContext) == nil)

            await #expect(throws: HelmcodeUsageError.missingCookiesAny) {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting
                    .withValue(Self.unexpectedNetworkStub()) {
                        try await strategy.fetch(offContext)
                    }
            }
        }
    }
    #endif

    // MARK: - Dashboard deployment routing (display cache)

    @Test
    func `dashboard deployment follows credential over cache with pinned override`() async throws {
        try await self.withTestKeychainCache {
            // Automatic + manual NaN capture: NaN (the credential decides, beating the display cache).
            let nanManual = HelmcodeProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: nan_session=abc'",
                deploymentSelection: .auto)
            #expect(
                HelmcodeDeploymentResolver.dashboardDeployment(settings: nanManual, environment: [:]) == .nanBuilders)
            // Automatic, no credential, no cache: Helmcode Cloud fallback.
            let auto = HelmcodeProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: nil,
                deploymentSelection: .auto)
            #expect(HelmcodeDeploymentResolver.dashboardDeployment(settings: auto, environment: [:]) == .helmcode)
            // A pinned selection wins over everything.
            let pinned = HelmcodeProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: nan_session=abc'",
                deploymentSelection: .helmcode)
            #expect(HelmcodeDeploymentResolver.dashboardDeployment(settings: pinned, environment: [:]) == .helmcode)
        }
    }

    @Test
    func `dashboard deployment routes bare credentials to cloud without cache fallthrough`() async throws {
        try await self.withTestKeychainCache {
            // A credential IS selected (bare header, no host): fetching routes it to Helmcode Cloud,
            // so the dashboard must NOT fall through to a cached NaN tenant (G3).
            let bareManual = HelmcodeProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: "session=abc",
                deploymentSelection: .auto)
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "session", value: "cached", domain: "nan.builders"),
            ])
            #expect(HelmcodeDeploymentResolver.dashboardDeployment(settings: bareManual, environment: [:]) == .helmcode)
            // No credential selected: the display-path cache decides.
            let auto = HelmcodeProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: nil,
                deploymentSelection: .auto)
            #expect(HelmcodeDeploymentResolver.dashboardDeployment(settings: auto, environment: [:]) == .nanBuilders)
        }
    }
}
