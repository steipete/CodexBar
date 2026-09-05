import Foundation
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// All Helmcode strategy tests that touch `CookieHeaderCache`/`KeychainCacheStore` live in this one
/// serialized suite: the cache is process-global, so parallel suites would leak entries into each
/// other. Covers automatic deployment detection, cache reuse and eviction, and the session fetch
/// seams. Modeled on `ZoomMateCookieCacheTests`.
@Suite(.serialized)
struct HelmcodeDeploymentDetectionTests {
    private static let quotaBody = #"""
    {"periodStart":"2026-09-01","models":[{"model":"helm-model-a","cap":1000000,"tokensUsed":250000}]}
    """#
    private static let billingBody = #"{"subscription":{"status":"active","premium":false}}"#
    private static let nanCookieHeader = "nan_session=fake-nan-value"
    private static let helmcodeCookieHeader = "session=fake-helmcode-value"

    // MARK: - Helpers

    private static func makeContext(
        runtime: CodexBarCore.ProviderRuntime,
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

    private func withTestKeychainCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        KeychainCacheStore.setTestStoreForTesting(true)
        Self.clearBothScopes()
        defer {
            Self.clearBothScopes()
            KeychainCacheStore.setTestStoreForTesting(false)
        }
        return try await operation()
    }

    private static func clearBothScopes() {
        for deployment in HelmcodeDeployment.allCases {
            CookieHeaderCache.clear(provider: .helmcode, scope: HelmcodeWebFetchStrategy.cacheScope(deployment))
        }
    }

    private static func unexpectedNetworkStub() -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { _ in
            Issue.record("Unexpected network request")
            throw URLError(.badURL)
        }
    }

    private static func successStub(expectedHost: String) -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == expectedHost)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch url.path {
            case "/api/usage/quota":
                return (Data(Self.quotaBody.utf8), response)
            case "/api/billing":
                return (Data(Self.billingBody.utf8), response)
            case "/api/billing/credits":
                return (Data(#"{"balanceMicros":12500000}"#.utf8), response)
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }
    }

    private static func nanSessions() -> [HelmcodeCookieImporter.SessionInfo] {
        [self.session(cookieHeader: self.nanCookieHeader, name: "nan_session", domain: "nan.builders")]
    }

    private static func helmcodeSessions() -> [HelmcodeCookieImporter.SessionInfo] {
        [self.session(cookieHeader: self.helmcodeCookieHeader, name: "session", domain: "helmcode.com")]
    }

    private static func session(
        cookieHeader: String,
        name: String,
        domain: String) -> HelmcodeCookieImporter.SessionInfo
    {
        let record = BrowserCookieRecord(
            domain: domain,
            name: name,
            path: "/",
            value: "fixture",
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: false,
            scope: .domain)
        let cookies = HelmcodeCookieImporter.makeCookies(from: [record])
        return HelmcodeCookieImporter.SessionInfo(cookies: cookies, sourceLabel: "Chrome Profile 1 (Test)")
    }

    // MARK: - Detection resolution

    @Test
    func `cookie capture host detection picks the pasted tenant`() {
        #expect(HelmcodeDeploymentResolver.detectTenant(fromCookieCapture: nil) == nil)
        #expect(HelmcodeDeploymentResolver.detectTenant(fromCookieCapture: "") == nil)
        #expect(HelmcodeDeploymentResolver.detectTenant(fromCookieCapture: "session=abc123") == nil)
        #expect(HelmcodeDeploymentResolver.detectTenant(
            fromCookieCapture: "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: session=abc'") ==
            .nanBuilders)
        #expect(HelmcodeDeploymentResolver.detectTenant(
            fromCookieCapture: "curl 'https://cloud-api.helmcode.com/api/usage/quota' -H 'Cookie: session=abc'") ==
            .helmcode)
        #expect(HelmcodeDeploymentResolver.detectTenant(
            fromCookieCapture: "curl 'https://example.com/login' -H 'Cookie: session=abc'") == nil)
        #expect(HelmcodeDeploymentResolver.detectTenant(
            fromCookieCapture: "curl 'https://cloud.nothelmcode.com/dashboard' -H 'Cookie: session=abc'") == nil)
        #expect(HelmcodeDeploymentResolver.detectTenant(
            fromCookieCapture: "curl 'https://cloud.nan.builders.evil.example/dashboard' -H 'Cookie: session=abc'")
            == nil)
    }

    #if os(macOS)
    @Test
    func `cache detection picks the only tenant or the newer stored session`() async throws {
        try await self.withTestKeychainCache {
            #expect(HelmcodeDeploymentResolver.detectTenantFromCache() == nil)
            #expect(HelmcodeDeploymentResolver.detectTenantFromCacheForDisplay() == nil)

            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders),
                cookieHeader: Self.nanCookieHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
            #expect(HelmcodeDeploymentResolver.detectTenantFromCache() == .nanBuilders)
            #expect(HelmcodeDeploymentResolver.detectTenantFromCacheForDisplay() == .nanBuilders)

            sleep(1)
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode),
                cookieHeader: Self.helmcodeCookieHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
            #expect(HelmcodeDeploymentResolver.detectTenantFromCache() == .helmcode)
            #expect(HelmcodeDeploymentResolver.detectTenantFromCacheForDisplay() == .helmcode)
        }
    }

    @Test
    func `automatic mode imports the first tenant with a session and labels it`() async throws {
        try await self.withTestKeychainCache {
            let strategy = HelmcodeWebFetchStrategy()
            let nanSessions = Self.nanSessions()
            let helmcodeSessions = Self.helmcodeSessions()

            // Both tenants have sessions: the Helmcode Cloud probe runs first.
            let bothStub = Self.successStub(expectedHost: "cloud-api.helmcode.com")
            let importOverride: (@Sendable (HelmcodeDeployment) -> [HelmcodeCookieImporter.SessionInfo]?)? =
                { deployment in
                    deployment == .helmcode ? helmcodeSessions : nanSessions
                }
            let bothResult = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await HelmcodeWebFetchStrategy.$sessionImporterOverrideForTesting.withValue(importOverride) {
                    try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(bothStub) {
                        try await strategy.fetch(Self.makeContext(runtime: .app))
                    }
                }
            }
            #expect(bothResult.sourceLabel == "web · Helmcode Cloud")
            #expect(bothResult.usage.primary?.resetDescription?.contains("helm-model-a") == true)

            // Only NaN has a session: the NaN tenant is used, labeled, and persisted in its scope.
            Self.clearBothScopes()
            let nanStub = Self.successStub(expectedHost: "cloud-api.nan.builders")
            let nanOverride: (@Sendable (HelmcodeDeployment) -> [HelmcodeCookieImporter.SessionInfo]?)? =
                { deployment in
                    deployment == .nanBuilders ? nanSessions : nil
                }
            let nanResult = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await HelmcodeWebFetchStrategy.$sessionImporterOverrideForTesting.withValue(nanOverride) {
                    try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(nanStub) {
                        try await strategy.fetch(Self.makeContext(runtime: .app))
                    }
                }
            }
            #expect(nanResult.sourceLabel == "web · NaN Builders")
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders))?.cookieHeader ==
                    "nan_session=fixture")

            // No tenant has a session: the error names both dashboards.
            Self.clearBothScopes()
            let noneContext = Self.makeContext(runtime: .app)
            let noSessions: (@Sendable (HelmcodeDeployment) -> [HelmcodeCookieImporter.SessionInfo]?)? = { _ in nil }
            try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await #expect {
                    _ = try await HelmcodeWebFetchStrategy.$sessionImporterOverrideForTesting
                        .withValue(noSessions) {
                            try await strategy.fetch(noneContext)
                        }
                } throws: { error in
                    (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookiesAny
                }
            }
        }
    }

    @Test
    func `cached session decides the tenant and labels the source`() async throws {
        try await self.withTestKeychainCache {
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders),
                cookieHeader: Self.nanCookieHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
            let stub = Self.successStub(expectedHost: "cloud-api.nan.builders")
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(runtime: .app)

            let available = await strategy.isAvailable(context)
            #expect(available == true)
            let result = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                try await strategy.fetch(context)
            }
            #expect(result.sourceLabel == "web · NaN Builders")
        }
    }

    @Test
    func `pinned selection overrides the cached tenant`() async throws {
        try await self.withTestKeychainCache {
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders),
                cookieHeader: Self.nanCookieHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode),
                cookieHeader: Self.helmcodeCookieHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
            let stub = Self.successStub(expectedHost: "cloud-api.helmcode.com")
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(
                runtime: .cli,
                settings: HelmcodeProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil,
                    deploymentSelection: .helmcode))
            let result = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                try await strategy.fetch(context)
            }
            #expect(result.sourceLabel == "web · Helmcode Cloud")
        }
    }

    @Test
    func `manual curl capture goes only to the detected tenant`() async throws {
        try await self.withTestKeychainCache {
            let stub = Self.successStub(expectedHost: "cloud-api.nan.builders")
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(
                runtime: .cli,
                settings: HelmcodeProviderSettings(
                    cookieSource: .manual,
                    manualCookieHeader: "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: nan_session=abc'",
                    deploymentSelection: .auto))
            let result = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                try await strategy.fetch(context)
            }
            #expect(result.sourceLabel == "web · NaN Builders")
        }
    }

    @Test
    func `bare manual cookie falls back to helmcode cloud`() async throws {
        try await self.withTestKeychainCache {
            let stub = Self.successStub(expectedHost: "cloud-api.helmcode.com")
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(
                runtime: .cli,
                env: ["HELMCODE_COOKIE": "session=abc"],
                settings: HelmcodeProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil,
                    deploymentSelection: .auto))
            let result = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                try await strategy.fetch(context)
            }
            #expect(result.sourceLabel == "web · Helmcode Cloud")
        }
    }

    // MARK: - Session fetch seams

    @Test
    func `imported session fetch skips a rejected session and persists a valid one`() async throws {
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
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode))?.cookieHeader == "session=fresh")
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
            CookieHeaderCache.store(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders),
                cookieHeader: Self.nanCookieHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
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
            #expect(requests.first?.value(forHTTPHeaderField: "Cookie") == Self.nanCookieHeader)
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
                cookieHeader: Self.helmcodeCookieHeader,
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
                cookieHeader: Self.nanCookieHeader,
                sourceLabel: "Chrome Profile 1 (Test)")

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
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders))?.cookieHeader ==
                    Self.nanCookieHeader)
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
                cookieHeader: Self.helmcodeCookieHeader,
                sourceLabel: "Chrome Profile 1 (Test)")
            let strategy = HelmcodeWebFetchStrategy()

            let offContext = Self.makeContext(
                runtime: .cli,
                env: ["HELMCODE_COOKIE": "session=env-value"],
                settings: HelmcodeProviderSettings(cookieSource: .off, manualCookieHeader: nil))
            #expect(await strategy.isAvailable(offContext) == false)
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
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode))?.cookieHeader ==
                    Self.helmcodeCookieHeader)
        }
    }

    @Test
    func `successful import stores the header under the deployment scope`() async throws {
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
            let cached = CookieHeaderCache.load(
                provider: .helmcode,
                scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders))
            #expect(cached?.cookieHeader == "nan_session=fixture")
            #expect(cached?.sourceLabel == "Chrome Profile 1 (Test)")
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
            #expect(HelmcodeCookieHeader.resolveCookieOverride(context: offContext) == nil)

            await #expect(throws: HelmcodeUsageError.missingCookiesAny) {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting
                    .withValue(Self.unexpectedNetworkStub()) {
                        try await strategy.fetch(offContext)
                    }
            }
        }
    }

    // MARK: - Dashboard action (app seam)

    @Test @MainActor
    func `helmcode dashboard action follows the selected or detected deployment`() throws {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let suite = "HelmcodeDeploymentDetectionTests-dashboard-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.providerDetectionCompleted = true

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)

        KeychainCacheStore.setTestStoreForTesting(true)
        Self.clearBothScopes()
        defer {
            Self.clearBothScopes()
            KeychainCacheStore.setTestStoreForTesting(false)
        }

        // Automatic with no cached session falls back to Helmcode Cloud.
        settings.helmcodeDeploymentSelection = .auto
        #expect(controller.dashboardURL(for: .helmcode)?.absoluteString == "https://cloud.helmcode.com/dashboard")

        // A cached session decides the tenant while Automatic is selected.
        CookieHeaderCache.store(
            provider: .helmcode,
            scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders),
            cookieHeader: "nan_session=fixture",
            sourceLabel: "Chrome Profile 1 (Test)")
        #expect(controller.dashboardURL(for: .helmcode)?.absoluteString == "https://cloud.nan.builders/dashboard")

        // A pinned selection wins over the cached tenant.
        settings.helmcodeDeploymentSelection = .nanBuilders
        #expect(controller.dashboardURL(for: .helmcode)?.absoluteString == "https://cloud.nan.builders/dashboard")
    }

    // MARK: - Fixture helpers

    private static func quotaFixture() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "quota",
            withExtension: "json",
            subdirectory: "Fixtures/Providers/Helmcode"))
        return try Data(contentsOf: url)
    }

    private static func unauthenticatedBody() -> Data {
        Data(#"{"error":"unauthenticated"}"#.utf8)
    }

    private static func response(url: URL, status: Int = 200, body: Data) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil))
        return (body, response)
    }

    private static func makeSession(
        cookieHeader: String,
        value: String) throws -> HelmcodeCookieImporter.SessionInfo
    {
        let record = BrowserCookieRecord(
            domain: "helmcode.com",
            name: "session",
            path: "/",
            value: value,
            expires: Date(timeIntervalSince1970: 1_900_000_000),
            isSecure: true,
            isHTTPOnly: false,
            scope: .domain)
        let cookies = HelmcodeCookieImporter.makeCookies(from: [record])
        let url = try #require(URL(string: "https://cloud-api.helmcode.com/api/usage/quota"))
        #expect(HelmcodeCookieHeader.header(from: cookies, for: url) == cookieHeader)
        return HelmcodeCookieImporter.SessionInfo(cookies: cookies, sourceLabel: "Chrome Profile 1 (Test)")
    }
    #endif
}
