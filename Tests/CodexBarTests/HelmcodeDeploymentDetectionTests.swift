import Foundation
import SweetCookieKit
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// All Helmcode strategy tests that touch `CookieHeaderCache`/`KeychainCacheStore` live in this one
/// serialized suite: the cache is process-global, so parallel suites would leak entries into each
/// other. Covers credential selection, deployment detection, candidate validation, cached-session
/// records, and the session fetch seams. Modeled on `ZoomMateCookieCacheTests`.
@Suite(.serialized)
struct HelmcodeDeploymentDetectionTests {
    final class CaptureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]

        func set(_ key: String, _ value: String?) {
            self.lock.lock()
            self.values[key] = value
            self.lock.unlock()
        }

        func value(for key: String) -> String? {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.values[key]
        }

        func append(_ value: String) {
            self.lock.lock()
            self.stored.append(value)
            self.lock.unlock()
        }

        var all: [String] {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.stored
        }

        private var stored: [String] = []
    }

    private static let quotaBody = #"""
    {"periodStart":"2026-09-01","models":[{"model":"helm-model-a","cap":1000000,"tokensUsed":250000}]}
    """#
    private static let billingBody = #"{"subscription":{"status":"active","premium":false}}"#
    private static let nanCookieHeader = "nan_session=fake-nan-value"
    private static let helmcodeCookieHeader = "session=fake-helmcode-value"
    private static let farFuture = Date(timeIntervalSince1970: 1_900_000_000)

    // MARK: - Helpers

    static func makeContext(
        runtime: CodexBarCore.ProviderRuntime,
        env: [String: String] = [:],
        settings: CodexBarCore.HelmcodeProviderSettings? = nil,
        verbose: Bool = false) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: .web,
            includeCredits: false,
            includeOptionalUsage: false,
            webTimeout: 15,
            webDebugDumpHTML: false,
            verbose: verbose,
            env: env,
            settings: settings.map { snapshot in ProviderSettingsSnapshot.make(helmcode: snapshot) },
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    func withTestKeychainCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        KeychainCacheStore.setTestStoreForTesting(true)
        Self.clearBothScopes()
        defer {
            Self.clearBothScopes()
            KeychainCacheStore.setTestStoreForTesting(false)
        }
        return try await operation()
    }

    static func clearBothScopes() {
        for deployment in HelmcodeDeployment.allCases {
            CookieHeaderCache.clear(provider: .helmcode, scope: HelmcodeWebFetchStrategy.cacheScope(deployment))
        }
    }

    static func record(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expires: Date? = farFuture,
        secure: Bool = true) -> HelmcodeCachedCookie
    {
        HelmcodeCachedCookie(
            name: name,
            value: value,
            domain: "." + domain,
            path: path,
            expires: expires,
            isSecure: secure,
            isHTTPOnly: false)
    }

    static func storeCachedSession(
        _ deployment: HelmcodeDeployment,
        cookies: [HelmcodeCachedCookie],
        sourceLabel: String = "Chrome Profile 1 (Test)")
    {
        CookieHeaderCache.store(
            provider: .helmcode,
            scope: HelmcodeWebFetchStrategy.cacheScope(deployment),
            cookieHeader: HelmcodeCachedSession(cookies: cookies).encodedForStorage() ?? "",
            sourceLabel: sourceLabel)
    }

    static func legacyFlatStore(_ deployment: HelmcodeDeployment, header: String) {
        CookieHeaderCache.store(
            provider: .helmcode,
            scope: HelmcodeWebFetchStrategy.cacheScope(deployment),
            cookieHeader: header,
            sourceLabel: "Chrome Profile 1 (Test)")
    }

    static func helmcodeRejectedStub() -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.host == "cloud-api.helmcode.com" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(#"{"error":"unauthenticated"}"#.utf8), response)
            }
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch url.path {
            case "/api/usage/quota":
                return (Data(Self.quotaBody.utf8), ok)
            case "/api/billing":
                return (Data(Self.billingBody.utf8), ok)
            case "/api/billing/credits":
                return (Data(#"{"balanceMicros":12500000}"#.utf8), ok)
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }
    }

    static func unexpectedNetworkStub() -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { _ in
            Issue.record("Unexpected network request")
            throw URLError(.badURL)
        }
    }

    static func successStub(expectedHost: String) -> ProviderHTTPTransportStub {
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

    static func session(
        cookieHeader: String,
        name: String,
        domain: String) -> HelmcodeCookieImporter.SessionInfo
    {
        let record = BrowserCookieRecord(
            domain: domain,
            name: name,
            path: "/",
            value: "fixture",
            expires: Self.farFuture,
            isSecure: true,
            isHTTPOnly: false,
            scope: .domain)
        let cookies = HelmcodeCookieImporter.makeCookies(from: [record])
        return HelmcodeCookieImporter.SessionInfo(cookies: cookies, sourceLabel: "Chrome Profile 1 (Test)")
    }

    // MARK: - Credential selection (F1)

    @Test
    func `manual empty falls through to the environment credential with its own capture`() {
        // F1: an empty manual value is not a credential, so the environment NaN capture is selected
        // WITH its own raw text — host detection then routes it to NaN, never to Helmcode Cloud.
        let selected = HelmcodeCookieHeader.selectCredential(
            cookieSource: .manual,
            manualCookieHeader: "   ",
            environment: [
                "HELMCODE_COOKIE": "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: nan_session=abc'",
            ])
        #expect(selected?.origin == .environment)
        #expect(selected?.cookieHeader == "nan_session=abc")
        #expect(selected?.rawCapture.contains("cloud.nan.builders") == true)
        // A bare manual text is still manual (no env fall-through).
        let bareManual = HelmcodeCookieHeader.selectCredential(
            cookieSource: .manual,
            manualCookieHeader: "session=abc",
            environment: ["HELMCODE_COOKIE": "session=env"])
        #expect(bareManual?.origin == .manual)
        #expect(bareManual?.cookieHeader == "session=abc")
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

            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "nan_session", value: "nan", domain: "nan.builders"),
            ])
            #expect(HelmcodeDeploymentResolver.detectTenantFromCache() == .nanBuilders)
            #expect(HelmcodeDeploymentResolver.detectTenantFromCacheForDisplay() == .nanBuilders)

            sleep(1)
            Self.storeCachedSession(.helmcode, cookies: [
                Self.record(name: "session", value: "helm", domain: "helmcode.com"),
            ])
            #expect(HelmcodeDeploymentResolver.detectTenantFromCache() == .helmcode)
            #expect(HelmcodeDeploymentResolver.detectTenantFromCacheForDisplay() == .helmcode)
        }
    }

    @Test
    func `manual empty with environment nan capture sends the nan credential only to nan`() async throws {
        try await self.withTestKeychainCache {
            let stub = Self.successStub(expectedHost: "cloud-api.nan.builders")
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(
                runtime: .cli,
                env: ["HELMCODE_COOKIE": "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: nan_session=abc'"],
                settings: HelmcodeProviderSettings(
                    cookieSource: .manual,
                    manualCookieHeader: "   ",
                    deploymentSelection: .auto))
            let result = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                try await strategy.fetch(context)
            }
            #expect(result.sourceLabel == "web · NaN Builders")
            let requests = await stub.requests()
            #expect(requests.count == 3)
            #expect(requests.allSatisfy { $0.url?.host == "cloud-api.nan.builders" })
        }
    }

    @Test
    func `manual nan capture wins over environment helmcode capture`() async throws {
        try await self.withTestKeychainCache {
            let stub = Self.successStub(expectedHost: "cloud-api.nan.builders")
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(
                runtime: .cli,
                env: ["HELMCODE_COOKIE": "curl 'https://cloud-api.helmcode.com' -H 'Cookie: session=helm'"],
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
    func `automatic mode validates candidates and commits the winning tenant`() async throws {
        try await self.withTestKeychainCache {
            let strategy = HelmcodeWebFetchStrategy()
            let nanSessions = Self.nanSessions()
            let helmcodeSessions = Self.helmcodeSessions()

            // Both tenants import: the Helmcode Cloud candidate is validated first.
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
            #expect(HelmcodeDeploymentResolver.detectTenantFromCache() == .helmcode)

            // Helmcode has stale cookies (rejected by the server), NaN is valid: NaN is chosen and
            // cached, the rejected Helmcode scope stays empty.
            Self.clearBothScopes()
            let mixedStub = Self.helmcodeRejectedStub()
            let mixedOverride: (@Sendable (HelmcodeDeployment) -> [HelmcodeCookieImporter.SessionInfo]?)? =
                { deployment in
                    deployment == .helmcode ? helmcodeSessions : nanSessions
                }
            let mixedResult = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await HelmcodeWebFetchStrategy.$sessionImporterOverrideForTesting.withValue(mixedOverride) {
                    try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(mixedStub) {
                        try await strategy.fetch(Self.makeContext(runtime: .app))
                    }
                }
            }
            #expect(mixedResult.sourceLabel == "web · NaN Builders")
            #expect(HelmcodeDeploymentResolver.detectTenantFromCache() == .nanBuilders)
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode)) == nil)
        }
    }

    @Test
    func `cached candidate rejection evicts and resumes detection at the other tenant`() async throws {
        try await self.withTestKeychainCache {
            // Cached Helmcode session is stale (the server rejects it); a fresh NaN import works.
            Self.storeCachedSession(.helmcode, cookies: [
                Self.record(name: "session", value: "stale", domain: "helmcode.com"),
            ])
            let nanSessions = Self.nanSessions()
            let rejectionStub = Self.helmcodeRejectedStub()
            let strategy = HelmcodeWebFetchStrategy()
            let importOverride: (@Sendable (HelmcodeDeployment) -> [HelmcodeCookieImporter.SessionInfo]?)? =
                { deployment in
                    deployment == .nanBuilders ? nanSessions : nil
                }
            let result = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await HelmcodeWebFetchStrategy.$sessionImporterOverrideForTesting.withValue(importOverride) {
                    try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(rejectionStub) {
                        try await strategy.fetch(Self.makeContext(runtime: .app))
                    }
                }
            }
            #expect(result.sourceLabel == "web · NaN Builders")
            #expect(HelmcodeDeploymentResolver.detectTenantFromCache() == .nanBuilders)
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode)) == nil)
        }
    }

    @Test
    func `all candidates rejected leaves both scopes empty`() async throws {
        try await self.withTestKeychainCache {
            Self.storeCachedSession(.helmcode, cookies: [
                Self.record(name: "session", value: "stale", domain: "helmcode.com"),
            ])
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "nan_session", value: "stale", domain: "nan.builders"),
            ])
            let stub = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"error":"unauthenticated"}"#.utf8), response)
            }
            let strategy = HelmcodeWebFetchStrategy()
            let importOverride: (@Sendable (HelmcodeDeployment) -> [HelmcodeCookieImporter.SessionInfo]?)? = { _ in
                nil
            }
            try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                try await HelmcodeWebFetchStrategy.$sessionImporterOverrideForTesting
                    .withValue(importOverride) {
                        try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                            await #expect {
                                _ = try await strategy.fetch(Self.makeContext(runtime: .app))
                            } throws: { error in
                                (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookiesAny
                            }
                        }
                    }
            }
            // Two cached candidates were validated (401 each); imports yielded nothing.
            #expect(await stub.requests().count == 2)
            #expect(await stub.requests().allSatisfy { request in
                request.url?.host == "cloud-api.helmcode.com" || request.url?.host == "cloud-api.nan.builders"
            })
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.helmcode)) == nil)
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders)) == nil)
        }
    }

    @Test
    func `cached session decides the tenant and labels the source`() async throws {
        try await self.withTestKeychainCache {
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "nan_session", value: "fake-nan-value", domain: "nan.builders"),
            ])
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
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "nan_session", value: "fake-nan-value", domain: "nan.builders"),
            ])
            Self.storeCachedSession(.helmcode, cookies: [
                Self.record(name: "session", value: "fake-helmcode-value", domain: "helmcode.com"),
            ])
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

    // MARK: - Cached session records (F2)

    @Test
    func `cached records keep cookie path scope per endpoint`() async throws {
        try await self.withTestKeychainCache {
            // One cookie scoped to /api/usage and one general cookie: quota gets both, billing and
            // credits only the general one.
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "scoped", value: "quota-only", domain: "nan.builders", path: "/api/usage"),
                Self.record(name: "general", value: "everywhere", domain: "nan.builders"),
            ])
            let cookieByPath = CaptureBox()
            let stub = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                cookieByPath.set(url.path, request.value(forHTTPHeaderField: "Cookie"))
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
            let strategy = HelmcodeWebFetchStrategy()
            let result = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(stub) {
                try await strategy.fetch(Self.makeContext(runtime: .cli))
            }
            #expect(result.sourceLabel == "web · NaN Builders")
            let quotaCookie = try #require(cookieByPath.value(for: "/api/usage/quota"))
            #expect(quotaCookie.contains("scoped=quota-only"))
            #expect(quotaCookie.contains("general=everywhere"))
            let billingCookie = try #require(cookieByPath.value(for: "/api/billing"))
            #expect(billingCookie == "general=everywhere")
            let creditsCookie = try #require(cookieByPath.value(for: "/api/billing/credits"))
            #expect(creditsCookie == "general=everywhere")
        }
    }

    @Test
    func `expired cached cookies are excluded and the scope is cleared`() async throws {
        try await self.withTestKeychainCache {
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(
                    name: "nan_session",
                    value: "stale",
                    domain: "nan.builders",
                    expires: Date(timeIntervalSince1970: 100)),
            ])
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(runtime: .cli)
            await #expect {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting
                    .withValue(Self.unexpectedNetworkStub()) {
                        try await strategy.fetch(context)
                    }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookiesAny
            }
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders)) == nil)
        }
    }

    @Test
    func `redirect responses surface instead of being followed with the credential`() async throws {
        try await self.withTestKeychainCache {
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "nan_session", value: "live", domain: "nan.builders"),
            ])
            let requestCount = CaptureBox()
            requestCount.set("count", "0")
            let lines = CaptureBox()
            let sink: (@Sendable (String) -> Void)? = { line in
                lines.append(line)
            }
            let redirectStub = ProviderHTTPTransportStub { request in
                requestCount.set("count", String((Int(requestCount.value(for: "count") ?? "0") ?? 0) + 1))
                let url = try #require(request.url)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: ["Location": "https://evil.example/capture"])
                return try (Data(#"{"error":"redirect"}"#.utf8), #require(response))
            }
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(
                runtime: .cli,
                settings: HelmcodeProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil,
                    deploymentSelection: .nanBuilders))

            try await HelmcodeWebFetchStrategy.$verboseSinkForTesting.withValue(sink) {
                await #expect {
                    _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting
                        .withValue(redirectStub) {
                            try await strategy.fetch(context)
                        }
                } throws: { error in
                    (error as? HelmcodeUsageError) == HelmcodeUsageError.invalidSession(.nanBuilders)
                }
            }
            // The 3xx surfaced as the terminal response: exactly one request, nothing followed.
            #expect(requestCount.value(for: "count") == "1")
            let joined = lines.all.joined(separator: "\n")
            #expect(joined.contains(
                "helmcode: redirect refused cloud-api.nan.builders/api/usage/quota -> evil.example/capture"))
        }
    }

    @Test
    func `legacy flat cache entry is a miss that clears the scope`() async throws {
        try await self.withTestKeychainCache {
            Self.legacyFlatStore(.nanBuilders, header: "nan_session=legacy-flat-header")
            let strategy = HelmcodeWebFetchStrategy()
            let context = Self.makeContext(runtime: .cli)
            await #expect {
                _ = try await HelmcodeWebFetchStrategy.$transportOverrideForTesting
                    .withValue(Self.unexpectedNetworkStub()) {
                        try await strategy.fetch(context)
                    }
            } throws: { error in
                (error as? HelmcodeUsageError) == HelmcodeUsageError.missingCookiesAny
            }
            #expect(
                CookieHeaderCache.load(
                    provider: .helmcode,
                    scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders)) == nil)
        }
    }

    @Test
    func `verbose diagnostics document the cookie boundary`() async throws {
        try await self.withTestKeychainCache {
            Self.storeCachedSession(.nanBuilders, cookies: [
                Self.record(name: "scoped", value: "quota-only", domain: "nan.builders", path: "/api/usage"),
                Self.record(name: "general", value: "everywhere", domain: "nan.builders"),
                Self.record(
                    name: "stale",
                    value: "old",
                    domain: "nan.builders",
                    expires: Date(timeIntervalSince1970: 100)),
            ])
            let lines = CaptureBox()
            let strategy = HelmcodeWebFetchStrategy()
            let sink: (@Sendable (String) -> Void)? = { line in
                lines.append(line)
            }
            let result = try await HelmcodeWebFetchStrategy.$verboseSinkForTesting.withValue(sink) {
                try await HelmcodeWebFetchStrategy.$transportOverrideForTesting.withValue(
                    Self.successStub(expectedHost: "cloud-api.nan.builders"))
                {
                    try await strategy.fetch(Self.makeContext(runtime: .cli, verbose: true))
                }
            }
            #expect(result.sourceLabel == "web · NaN Builders")
            let joined = lines.all.joined(separator: "\n")
            #expect(joined.contains("candidate NaN Builders (cache)"))
            #expect(joined.contains("excluded-expired=[stale]"))
            #expect(joined.contains("excluded-path=[scoped]"))
            #expect(joined.contains(
                "GET cloud-api.nan.builders/api/usage/quota cookies=[scoped, general] excluded-expired=[stale]"))
            #expect(joined.contains(
                "GET cloud-api.nan.builders/api/billing cookies=[general] excluded-expired=[stale] " +
                    "excluded-path=[scoped]"))
        }
    }

    @Test
    func `verbose diagnostics document header credential requests`() async throws {
        let lines = CaptureBox()
        let sink: (@Sendable (String) -> Void)? = { line in
            lines.append(line)
        }
        let stub = Self.successStub(expectedHost: "cloud-api.nan.builders")
        let snapshot = try await HelmcodeUsageFetcher.fetchUsage(
            cookieHeader: "nan_session=proof",
            deployment: .nanBuilders,
            transport: stub,
            verbose: sink)
        #expect(snapshot.toUsageSnapshot().primary?.resetDescription?.contains("helm-model-a") == true)
        let joined = lines.all.joined(separator: "\n")
        #expect(joined.contains("GET cloud-api.nan.builders/api/usage/quota credential=header"))
        #expect(joined.contains("GET cloud-api.nan.builders/api/billing credential=header"))
        #expect(joined.contains("GET cloud-api.nan.builders/api/billing/credits credential=header"))
        #expect(!joined.contains("cookies=["))
    }

    // MARK: - Dashboard action (app seam, F4)

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

        // Automatic with no credential and no cached session falls back to Helmcode Cloud.
        settings.helmcodeDeploymentSelection = .auto
        #expect(controller.dashboardURL(for: .helmcode)?.absoluteString == "https://cloud.helmcode.com/dashboard")

        // A cached session decides the tenant while Automatic is selected.
        CookieHeaderCache.store(
            provider: .helmcode,
            scope: HelmcodeWebFetchStrategy.cacheScope(.nanBuilders),
            cookieHeader: HelmcodeCachedSession(cookies: [
                Self.record(name: "nan_session", value: "fixture", domain: "nan.builders"),
            ]).encodedForStorage() ?? "",
            sourceLabel: "Chrome Profile 1 (Test)")
        #expect(controller.dashboardURL(for: .helmcode)?.absoluteString == "https://cloud.nan.builders/dashboard")

        // A manual NaN capture beats the cache (the credential decides, F4).
        settings.helmcodeCookieHeader =
            "curl 'https://cloud.nan.builders/dashboard' -H 'Cookie: nan_session=abc'"
        settings.helmcodeCookieSource = .manual
        #expect(controller.dashboardURL(for: .helmcode)?.absoluteString == "https://cloud.nan.builders/dashboard")

        // A pinned selection wins over everything.
        settings.helmcodeDeploymentSelection = .helmcode
        #expect(controller.dashboardURL(for: .helmcode)?.absoluteString == "https://cloud.helmcode.com/dashboard")
    }

    // MARK: - Fixture helpers

    static func quotaFixture() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "quota",
            withExtension: "json",
            subdirectory: "Fixtures/Providers/Helmcode"))
        return try Data(contentsOf: url)
    }

    static func unauthenticatedBody() -> Data {
        Data(#"{"error":"unauthenticated"}"#.utf8)
    }

    static func response(url: URL, status: Int = 200, body: Data) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil))
        return (body, response)
    }

    static func makeSession(
        cookieHeader: String,
        value: String) throws -> HelmcodeCookieImporter.SessionInfo
    {
        let record = BrowserCookieRecord(
            domain: "helmcode.com",
            name: "session",
            path: "/",
            value: value,
            expires: Self.farFuture,
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
