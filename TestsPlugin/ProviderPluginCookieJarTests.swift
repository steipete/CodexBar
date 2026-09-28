import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginCookieJarTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    #if os(macOS)
    @Test(arguments: BundledPluginTestSupport.engines)
    func `jar import retains interactive authorization across the engine callback`(
        engine: ProviderPluginEngineKind) async throws
    {
        let broker = ProviderInteractionContext.$current.withValue(.userInitiated) {
            ProviderPluginCookieBroker(
                provider: .longcat,
                domains: ["example.test"],
                settings: .init(cookieSource: .auto, manualCookieHeader: nil),
                batches: { _, _ in nil },
                jarImporter: {
                    [.init(
                        header: "",
                        source: ProviderInteractionContext.current == .userInitiated
                            ? "interactive" : "background",
                        origin: "",
                        records: [])]
                })
        }
        let runtime = try Self.runtime(engine: engine, script: """
        for await (const session of ctx.browser.sessions('example.test')) {
          return {identity: {loginMethod: session.source}};
        }
        throw new Error('missing fixture session');
        """, transport: ProviderHTTPTransportHandler { _ in throw URLError(.badURL) })
        let usage = try await runtime.fetchUsage(cookieSessionResolver: { domain, cachedOnly in
            try broker.nextSession(domain: domain, cachedOnly: cachedOnly)
        })
        #expect(usage.identity?.loginMethod == "interactive")
    }
    #endif

    @Test
    func `URL matcher preserves duplicate names and path boundaries`() throws {
        let records = try [
            Self.record("session", "root", domain: "example.test"),
            Self.record("session", "scoped", domain: ".example.test", path: "/api/v1"),
            Self.record("sibling", "excluded", domain: "www.example.test"),
            Self.record("expired", "excluded", domain: ".example.test", expires: Self.now),
            Self.record("secure", "https-only", domain: ".example.test", secure: true),
            Self.record("page", "excluded", domain: ".example.test", path: "/platform"),
        ]
        for (raw, expected) in [
            ("https://example.test/api/v1/me", "session=scoped; secure=https-only; session=root"),
            ("https://example.test/api/v12", "secure=https-only; session=root"),
            ("https://example.test/api/v1%2Fprivate", "secure=https-only; session=root"),
            ("https://api.example.test/api/v1", "session=scoped; secure=https-only"),
            ("http://api.example.test/api/v1", "session=scoped"),
            ("https://example.test.evil.test/api/v1", nil),
        ] {
            let url = try #require(URL(string: raw))
            #expect(ProviderPluginCookieRecord.header(records, for: url, now: Self.now) == expected)
        }
    }

    @Test
    func `same-origin redirects reselect cookies and reject credential-leaking destinations`() throws {
        let jar = ProviderPluginCookieJar()
        let session = try ProviderPluginCookieSession(
            header: "",
            source: "Fixture",
            origin: "https://example.test",
            records: [
                Self.record("session", "root", domain: "example.test"),
                Self.record("session", "scoped", domain: "example.test", path: "/api"),
            ])
        jar.register(session)
        let delegate = ProviderPluginCookieTransport.CookieRedirectDelegate(jar: jar, id: session.id)
        let original = try #require(URL(string: "https://example.test/api/me"))
        for (raw, expected) in [
            ("https://example.test/api/usage", "session=scoped; session=root"),
            ("https://example.test/platform", "session=root"),
            ("https://other.test/api", nil),
            ("http://example.test/api", nil),
        ] {
            var request = try URLRequest(url: #require(URL(string: raw)))
            request.setValue("session=scoped; session=root", forHTTPHeaderField: "Cookie")
            #expect(delegate.redirectedRequest(originalURL: original, request: request)?
                .value(forHTTPHeaderField: "Cookie") == expected)
        }
        jar.reject(id: session.id)
        #expect(delegate.redirectedRequest(originalURL: original, request: URLRequest(url: original)) == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `scripts see metadata only and host selects cookies for every request`(
        engine: ProviderPluginEngineKind) async throws
    {
        let record = try Self.record("session", "private-fixture", domain: "example.test", path: "/api")
        let runtime = try Self.runtime(engine: engine, script: """
        for await (const session of ctx.browser.sessions("example.test")) {
          if (session.header !== undefined || session.records !== undefined || JSON.stringify(session).includes("private-fixture"))
            throw new Error("exposed cookie");
          let denied = false;
          try { await ctx.browser.cookieHeader("example.test"); } catch (_) { denied = true; }
          if (!denied) throw new Error("header bridge was allowed");
          await ctx.http.get("https://example.test/api/me", {cookieSession: session.id});
          await ctx.http.post("https://example.test/api/usage", {cookieSession: session.id, body: {}});
          try { await ctx.http.get("https://example.test/platform", {cookieSession: session.id}); }
          catch (error) {
            if (error.failureKind === "missing-credential") return {primary: {usedPercent: 25}};
            throw error;
          }
          throw new Error("path restriction was ignored");
        }
        """, transport: ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=private-fixture")
            #expect(request.url?.path.hasPrefix("/api/") == true)
            return try Self.response(request)
        })
        let usage = try await runtime.fetchUsage(cookieSessionResolver: { _, _ in
            .init(header: "", source: "Synthetic", origin: "https://example.test", records: [record])
        })
        #expect(usage.primary?.usedPercent == 25)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `forged and previous-fetch session identifiers fail before transport`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try Self.runtime(engine: engine, script: """
        const prior = ctx.cache.get("session") || "forged";
        for await (const session of ctx.browser.sessions("example.test")) {
          ctx.cache.set("session", session.id, 60);
          await ctx.http.get("https://example.test/api", {cookieSession: prior});
          return {primary: {usedPercent: 1}};
        }
        """, transport: ProviderHTTPTransportHandler { _ in
            Issue.record("Rejected sessions must never reach transport")
            throw URLError(.badURL)
        })
        for _ in 0..<2 {
            await #expect(throws: (any Error).self) {
                try await runtime.fetchUsage(cookieSessionResolver: { _, _ in
                    .init(header: "session=fixture", source: "Synthetic", origin: "https://example.test")
                })
            }
        }
    }

    @Test(arguments: [
        "https://other.test/api", "https://example.test:444/api", "https://user:pass@example.test/api",
    ], BundledPluginTestSupport.engines)
    func `manual sessions cannot cross their origin even to declared endpoints`(
        url: String, engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try Self.runtime(engine: engine, script: """
        for await (const session of ctx.browser.sessions("example.test")) {
          await ctx.http.get("\(url)", {cookieSession: session.id});
          return {primary: {usedPercent: 1}};
        }
        """, transport: ProviderHTTPTransportHandler { _ in
            Issue.record("Origin mismatch must never reach transport")
            throw URLError(.badURL)
        })
        await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(cookieSource: .manual, cookieSessionResolver: { _, _ in
                .init(header: "session=fixture", source: "manual", origin: "https://example.test")
            })
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `off never resolves a session`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try Self.runtime(engine: engine, script: """
        for await (const session of ctx.browser.sessions("example.test")) return {primary: {usedPercent: 1}};
        """, transport: ProviderHTTPTransportHandler { _ in throw URLError(.badURL) })
        await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(cookieSource: .off, cookieSessionResolver: { _, _ in
                Issue.record("Off must not import")
                return nil
            })
        }
    }

    private static func runtime(
        engine: ProviderPluginEngineKind, script: String,
        transport: any ProviderHTTPTransport) throws -> ProviderPluginRuntime
    {
        try ProviderPluginRuntime(source: """
        defineProvider({id: "longcat", name: "Fixture", settings: [], endpoints: ["https://example.test", "https://other.test", "https://example.test:444"],
          capabilities: ["browser-cookies", "http-status"], cookieDomains: ["example.test"],
          cookiePolicy: {selection: "request-url", cache: "nonpersistent"},
          async fetchUsage(ctx) { \(script) }
        });
        """, transport: transport, engine: engine)
    }

    @Test(arguments: [
        "{}", "{headers:{Cookie:'session=forged'}}", "{cookieSession:session.id,headers:{Cookie:'session=forged'}}",
        "{cookieSession:session.id,headers:{Host:'other.test'}}",
    ], BundledPluginTestSupport.engines)
    func `raw headers and requests without a candidate fail closed`(
        options: String, engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try Self.runtime(engine: engine, script: """
        for await (const session of ctx.browser.sessions("example.test")) {
          await ctx.http.get("https://example.test/api", \(options));
          return {primary:{usedPercent:1}};
        }
        """, transport: ProviderHTTPTransportHandler { _ in
            Issue.record("Denied cookie request reached transport")
            throw URLError(.badURL)
        })
        await #expect(throws: (any Error).self) {
            try await runtime.fetchUsage(cookieSessionResolver: { _, _ in
                .init(header: "session=fixture", source: "Fixture", origin: "https://example.test")
            })
        }
    }

    @Test(arguments: [
        "null", "true", "{selection:'request-url',cache:'persistent'}",
        "{selection:'request-url',cache:'nonpersistent',unknown:true}",
    ], BundledPluginTestSupport.engines)
    func `cookie policy rejects unsupported contracts`(policy: String, engine: ProviderPluginEngineKind) {
        #expect(throws: ProviderPluginError.self) {
            try ProviderPluginRuntime(source: """
            defineProvider({id:'longcat',name:'Fixture',settings:[],endpoints:['https://example.test'],
              capabilities:['browser-cookies'],cookieDomains:['example.test'],cookiePolicy:\(policy),
              async fetchUsage(){return {primary:{usedPercent:1}};}});
            """, engine: engine)
        }
    }

    private static func response(_ request: URLRequest) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        return try (
            Data("{}".utf8),
            #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
    }

    private static func record(
        _ name: String, _ value: String, domain: String, path: String = "/", secure: Bool = false,
        expires: Date? = nil) throws -> ProviderPluginCookieRecord
    {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return try ProviderPluginCookieRecord(cookie: #require(HTTPCookie(properties: properties)))
    }
}
