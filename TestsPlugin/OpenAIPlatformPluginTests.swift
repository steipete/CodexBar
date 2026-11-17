import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct OpenAIPlatformPluginTests {
    private static let now = Date(timeIntervalSince1970: 1_795_000_000)
    private static let origin = "https://platform.openai.com"
    private static let key = "oai-auth:onboard"

    /// A synthetic JWT whose payload carries only `exp`, relative to the fixed wall clock.
    private static func jwt(expiresIn seconds: TimeInterval) -> String {
        func encode(_ text: String) -> String {
            Data(text.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(encode("{\"alg\":\"none\"}")).\(encode("{\"exp\":\(Int(self.now.timeIntervalSince1970 + seconds))}")).sig"
    }

    private static func entry(_ id: String, token: String) -> ProviderPluginLocalStorageEntry {
        .init(
            id: id,
            label: "Profile \(id)",
            value: "{\"accessToken\":\"\(token)\",\"refreshToken\":\"synthetic-refresh\"}")
    }

    private static var grantsBody: String {
        let soon = Int(now.timeIntervalSince1970) + 10 * 86400
        let later = Int(now.timeIntervalSince1970) + 30 * 86400
        return """
        {"object":"credit_summary","total_granted":129,"total_used":11.49,"total_available":117.51,"grants":{"data":[
        {"id":"chatgpt_api_credits_promo_a","grant_amount":124,"used_amount":10.49,"effective_at":1,"expires_at":\(soon)},
        {"id":"credit_grant_b","grant_amount":5,"used_amount":1,"effective_at":1,"expires_at":\(later)},
        {"id":"credit_grant_old","grant_amount":9,"used_amount":9,"effective_at":1,"expires_at":1}]}}
        """
    }

    /// Answers the login exchange per access token and the grants read per session key.
    private actor Fixture: ProviderHTTPTransport {
        var loginStatus: [String: Int]
        var grantsStatus: [String: Int]
        let grantsBody: String
        var requests: [String] = []
        var bodies: [String] = []

        init(
            loginStatus: [String: Int] = [:],
            grantsStatus: [String: Int] = [:],
            grantsBody: String = OpenAIPlatformPluginTests.grantsBody)
        {
            self.loginStatus = loginStatus
            self.grantsStatus = grantsStatus
            self.grantsBody = grantsBody
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let bearer = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(
                of: "Bearer ",
                with: "")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            self.requests.append("\(request.httpMethod ?? "") \(url.path)")
            self.bodies.append(String(data: request.httpBody ?? Data(), encoding: .utf8) ?? "")
            let isLogin = url.path.hasSuffix("/onboarding/login")
            let status = isLogin ? self.loginStatus[bearer] ?? 200 : self.grantsStatus[bearer] ?? 200
            let body = isLogin
                ? "{\"user\":{\"session\":{\"sensitive_id\":\"sess-\(bearer.suffix(6))\"}}}"
                : self.grantsBody
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
        }
    }

    private static func fetch(
        _ engine: ProviderPluginEngineKind,
        fixture: Fixture,
        entries: [ProviderPluginLocalStorageEntry],
        sourceMode: ProviderSourceMode = .web,
        resolverCalls: Counter = Counter()) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "openai-platform", engine: engine, wallClock: Self.now, transport: fixture)
        return try await runtime.fetchUsage(
            now: Self.now,
            sourceMode: sourceMode,
            localStorageResolver: { origin, key in
                #expect(origin == Self.origin && key == Self.key)
                resolverCalls.increment()
                return entries
            })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `subscription grant maps to the balance lane with the soonest expiry`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture()
        let token = Self.jwt(expiresIn: 86400)
        let usage = try await Self.fetch(engine, fixture: fixture, entries: [Self.entry("a", token: token)])
        let primary = try #require(usage.primary)
        #expect(abs(primary.usedPercent - 10.49 / 124 * 100) < 0.000_001)
        #expect(primary.resetDescription?.hasPrefix("$113.51 of $124.00 left · Expires ") == true)
        let cost = try #require(usage.providerCost)
        #expect(cost.balance == 117.51)
        #expect(cost.period == "Prepaid credits")
        #expect(cost.resetsAt == Self.now.addingTimeInterval(10 * 86400))
        #expect(usage.detailRow(label: "Credit grant")?.value == "$4.00 of $5.00 left")
        #expect(usage.identity?.loginMethod == "Platform session")
        #expect(await fixture.requests == [
            "POST /v1/dashboard/onboarding/login",
            "GET /v1/dashboard/billing/credit_grants",
        ])
        #expect(await fixture.bodies.first == "{\"app\":\"api\"}")
    }

    @Test(arguments: [24, 25, 200], BundledPluginTestSupport.engines)
    func `many grants retain the balance and subscription within the detail row limit`(
        count: Int, engine: ProviderPluginEngineKind) async throws
    {
        let expiry = Int(Self.now.timeIntervalSince1970) + 86400
        let grants: [[String: Any]] = [[
            "id": "chatgpt_api_credits_promo_subscription", "grant_amount": 124,
            "used_amount": 10.49, "effective_at": 1, "expires_at": expiry,
        ]] + (0..<count).map { [
            "id": "credit_grant_\($0)", "grant_amount": 1, "used_amount": 0,
            "effective_at": 1, "expires_at": expiry,
        ] }
        let body = try JSONSerialization.data(withJSONObject: [
            "total_granted": 124 + count, "total_used": 10.49, "total_available": 113.51 + Double(count),
            "grants": ["data": grants],
        ])
        let fixture = Fixture(grantsBody: String(decoding: body, as: UTF8.self))
        let usage = try await Self.fetch(engine, fixture: fixture, entries: [
            Self.entry("fixture", token: Self.jwt(expiresIn: 3600)),
        ])
        #expect(usage.providerCost?.balance == 113.51 + Double(count))
        #expect(usage.primary?.resetDescription?.hasPrefix("$113.51 of $124.00 left") == true)
        #expect(usage.details.count == 1)
        #expect(usage.details.first?.rows.count == ProviderDetailSection.maximumRowsPerSection)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired tokens are skipped without a request and a rejected token moves to the next profile`(
        engine: ProviderPluginEngineKind) async throws
    {
        let dead = Self.jwt(expiresIn: -60)
        let rejected = Self.jwt(expiresIn: 3600) + "r"
        let live = Self.jwt(expiresIn: 7200)
        let fixture = Fixture(loginStatus: [rejected: 401])
        let usage = try await Self.fetch(engine, fixture: fixture, entries: [
            Self.entry("dead", token: dead), Self.entry("rejected", token: rejected), Self.entry("live", token: live),
        ])
        #expect(usage.providerCost?.balance == 117.51)
        #expect(await fixture.requests == [
            "POST /v1/dashboard/onboarding/login",
            "POST /v1/dashboard/onboarding/login",
            "GET /v1/dashboard/billing/credit_grants",
        ])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a rejected session key also moves to the next profile`(engine: ProviderPluginEngineKind) async throws {
        let first = Self.jwt(expiresIn: 3600) + "1"
        let second = Self.jwt(expiresIn: 3600) + "2"
        let fixture = Fixture(grantsStatus: ["sess-\(first.suffix(6))": 401])
        let usage = try await Self.fetch(engine, fixture: fixture, entries: [
            Self.entry("one", token: first), Self.entry("two", token: second),
        ])
        #expect(usage.providerCost?.balance == 117.51)
        #expect(await fixture.requests.count == 4)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `no session reports a missing credential and expired or rejected sessions report expiry`(
        engine: ProviderPluginEngineKind) async throws
    {
        let missing = await #expect(throws: (any Error).self) {
            try await Self.fetch(engine, fixture: Fixture(), entries: [])
        }
        #expect(String(describing: missing).contains("Sign in at platform.openai.com"))
        for entries in [
            [Self.entry("dead", token: Self.jwt(expiresIn: -1))],
            [Self.entry("rejected", token: Self.jwt(expiresIn: 60))],
        ] {
            let fixture = Fixture(loginStatus: [Self.jwt(expiresIn: 60): 401])
            let expired = await #expect(throws: (any Error).self) {
                try await Self.fetch(engine, fixture: fixture, entries: entries)
            }
            #expect(String(describing: expired).contains("session expired"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `rate limits and server errors are classified without trying other profiles`(
        engine: ProviderPluginEngineKind) async throws
    {
        let expectations: [(Int, String)] = [
            (403, "Sign in at platform.openai.com again"),
            (429, "Wait a moment and refresh"),
            (503, "temporarily unavailable"),
            (418, "Check platform.openai.com in your browser"),
        ]
        for (status, expectedDetail) in expectations {
            let token = Self.jwt(expiresIn: 3600)
            let fixture = Fixture(loginStatus: [token: status])
            let error = await #expect(throws: (any Error).self) {
                try await Self.fetch(engine, fixture: fixture, entries: [
                    Self.entry("a", token: token), Self.entry("b", token: Self.jwt(expiresIn: 7200)),
                ])
            }
            let message = String(describing: error)
            #expect(message.contains("HTTP \(status)"))
            #expect(message.contains(expectedDetail))
            #expect(await fixture.requests == ["POST /v1/dashboard/onboarding/login"])
        }
    }

    @Test
    func `selected token account routes to api instead of ambient web`() {
        let credentials = OpenAIAPIProviderDescriptor.descriptor.credentials
        #expect(credentials?.tokenAccountSupport?.passiveSourceModes == [.web])
        #expect(credentials?.selectedAccountSourceMode(base: .web, account: nil, config: nil) == .web)
        #expect(credentials?.selectedAccountSourceMode(base: .auto, account: nil, config: nil) == .auto)
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Work",
            token: "sk-admin-work",
            addedAt: 1_700_000_000,
            lastUsed: nil)
        #expect(credentials?.selectedAccountSourceMode(base: .web, account: account, config: nil) == .api)
    }

    @Test(arguments: [ProviderSourceMode.auto, .api, .web])
    func `only the web source routes to the browser session plugin`(mode: ProviderSourceMode) async {
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: mode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: UnusedClaudeFetcher(),
            browserDetection: BrowserDetection(
                homeDirectory: "/nonexistent/openai-fixture",
                fileExists: { _ in false },
                directoryContents: { _ in nil }))
        let strategies = await OpenAIAPIProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(strategies.map(\.id) == [mode == .web ? "openai.platform" : "openai.js"])
    }

    private static func inline(_ grant: String, script: String, engine: ProviderPluginEngineKind) throws
        -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(source: """
        defineProvider({id:'openai',name:'Synthetic',settings:[],endpoints:['https://example.test'],
          capabilities:['browser-local-storage'],localStorage:\(grant),
          async fetchUsage(ctx){\(script)}});
        """, engine: engine)
    }

    private static let declared = "[{origin:'\(origin)',keys:['\(key)']}]"

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a declared grant loads and exposes only its origin and keys`(engine: ProviderPluginEngineKind) throws {
        let runtime = try Self.inline(Self.declared, script: "return {empty:true}", engine: engine)
        #expect(runtime.manifest.localStorageKeys == [Self.origin: [Self.key]])
        #expect(runtime.manifest.capabilities.contains(.browserLocalStorage))
    }

    @Test(arguments: [
        "[]",
        "[{origin:'http://platform.openai.com',keys:['k']}]",
        "[{origin:'https://platform.openai.com/path',keys:['k']}]",
        "[{origin:'https://platform.openai.com',keys:[]}]",
        "[{origin:'https://platform.openai.com',keys:['']}]",
        "[{origin:'https://platform.openai.com',keys:['k'],extra:true}]",
        "[{origin:'https://platform.openai.com',keys:['k']},{origin:'https://platform.openai.com',keys:['j']}]",
        "'https://platform.openai.com'",
    ], BundledPluginTestSupport.engines)
    func `malformed grants are rejected`(grant: String, engine: ProviderPluginEngineKind) {
        #expect(throws: ProviderPluginError.self) {
            try Self.inline(grant, script: "return {empty:true}", engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `the capability needs a grant and a grant needs the capability`(engine: ProviderPluginEngineKind) {
        #expect(throws: ProviderPluginError.self) {
            try ProviderPluginRuntime(source: """
            defineProvider({id:'openai',name:'Synthetic',settings:[],endpoints:['https://example.test'],
              capabilities:['browser-local-storage'],async fetchUsage(){return {empty:true}}});
            """, engine: engine)
        }
        #expect(throws: ProviderPluginError.self) {
            try ProviderPluginRuntime(source: """
            defineProvider({id:'openai',name:'Synthetic',settings:[],endpoints:['https://example.test'],
              localStorage:\(Self.declared),async fetchUsage(){return {empty:true}}});
            """, engine: engine)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `user installed plugins cannot request browser local storage`(engine: ProviderPluginEngineKind) {
        #expect(throws: ProviderPluginError.self) {
            try ProviderPluginRuntime(source: """
            defineProvider({id:'synthetic',name:'Synthetic',settings:[],endpoints:['https://example.test'],
              capabilities:['browser-local-storage'],localStorage:\(Self.declared),
              async fetchUsage(){return {empty:true}}});
            """, enforcesUserResponsePolicy: true, allowsDynamicID: true, engine: engine)
        }
    }

    @Test(arguments: [
        ("https://evil.test", "oai-auth:onboard"),
        ("https://platform.openai.com", "other-key"),
        ("http://platform.openai.com", "oai-auth:onboard"),
        ("not a url", "oai-auth:onboard"),
    ], BundledPluginTestSupport.engines)
    func `undeclared origins and keys are denied before the resolver runs`(
        target: (String, String), engine: ProviderPluginEngineKind) async throws
    {
        let calls = Counter()
        let runtime = try Self.inline(Self.declared, script: """
        await ctx.browser.localStorage('\(target.0)', '\(target.1)');
        return {empty:true};
        """, engine: engine)
        await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(sourceMode: .web, localStorageResolver: { _, _ in
                calls.increment()
                return []
            })
        }
        #expect(calls.value == 0)
    }

    @Test(arguments: [ProviderCookieSource.off, .manual], BundledPluginTestSupport.engines)
    func `configured off and manual sources block the browser before discovery`(
        source: ProviderCookieSource, engine: ProviderPluginEngineKind) async throws
    {
        let calls = Counter()
        let fixture = Fixture()
        let runtime = try BundledPluginTestSupport.runtime(
            "openai-platform", engine: engine, wallClock: Self.now, transport: fixture)
        let config = ProviderConfig(id: .openai, source: .web, cookieSource: source)
        let registration = OpenAIAPIProviderDescriptor.descriptor.settingsSection
        let settings = registration.credentialContribution(context: .init(config: config, account: nil))
            .map { ProviderSettingsSnapshot(contributions: [$0]) }
        let browser = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli, sourceMode: .web, includeCredits: true, webTimeout: 1,
            webDebugDumpHTML: false, verbose: false, env: [:], settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browser), browserDetection: browser)
        let cookies = ProviderPluginCookieBroker(provider: .openai, domains: [], context: context)
        await #expect(throws: (any Error).self) {
            try await runtime.fetchResult(cookies: cookies, now: Self.now, localStorageResolver: { _, _ in
                calls.increment()
                return [Self.entry("fixture", token: Self.jwt(expiresIn: 3600))]
            })
        }
        #expect(calls.value == 0)
        #expect(await fixture.requests.isEmpty)
    }

    @Test(arguments: [ProviderSourceMode.auto, .api], BundledPluginTestSupport.engines)
    func `only an explicit web source reaches browser local storage`(
        mode: ProviderSourceMode, engine: ProviderPluginEngineKind) async throws
    {
        let calls = Counter()
        let runtime = try Self.inline(Self.declared, script: """
        await ctx.browser.localStorage('\(Self.origin)', '\(Self.key)');
        return {empty:true};
        """, engine: engine)
        await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(sourceMode: mode, localStorageResolver: { _, _ in
                calls.increment()
                return []
            })
        }
        #expect(calls.value == 0)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a missing host resolver fails closed`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.inline(Self.declared, script: """
        await ctx.browser.localStorage('\(Self.origin)', '\(Self.key)');
        return {empty:true};
        """, engine: engine)
        await #expect(throws: (any Error).self) { try await runtime.fetchUsage(sourceMode: .web) }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `returned values are redacted from errors`(engine: ProviderPluginEngineKind) async throws {
        let secret = "synthetic-secret-token-value"
        let runtime = try Self.inline(Self.declared, script: """
        const entries = await ctx.browser.localStorage('\(Self.origin)', '\(Self.key)');
        throw ctx.fail.apiFailure('leaked ' + entries[0].value);
        """, engine: engine)
        let error = await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(sourceMode: .web, localStorageResolver: { _, _ in
                [.init(id: "p", label: "Profile", value: secret)]
            })
        }
        #expect(!String(describing: error).contains(secret))
    }
}

private struct UnusedClaudeFetcher: ClaudeUsageFetching {
    func detectVersion() -> String? { nil }
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot { throw CancellationError() }
    func debugRawProbe(model _: String) async -> String { "unused" }
}
