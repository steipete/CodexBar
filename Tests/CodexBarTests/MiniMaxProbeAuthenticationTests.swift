import Foundation
import Testing
#if os(macOS)
import SweetCookieKit
#endif
@testable import CodexBarCore

struct MiniMaxProbeAuthenticationTests {
    @Test(arguments: [false, true], [false, true])
    func `analytics cookies never turn a quota only session into an unauthenticated page probe`(
        analyticsFirst: Bool,
        signInPage: Bool) async throws
    {
        for includeAnalytics in [false, true] {
            let cookies = Self.quotaCookies(analyticsFirst: analyticsFirst, includeAnalytics: includeAnalytics)
            let stub = ProviderHTTPTransportStub { request in
                let url = try #require(request.url)
                if url.path == "/console/usage" {
                    Issue.record("A page without request-specific authentication must be skipped locally")
                    return try Self.response(
                        url: url,
                        body: signInPage ? "<html>Sign in</html>" : "{}",
                        status: signInPage ? 200 : 401,
                        html: signInPage)
                }
                #expect(url.host == "www.minimax.cn")
                #expect(url.path == "/backend/account/token_plan/remains_percent")
                #expect(CookieHeaderNormalizer.pairs(from: request.value(forHTTPHeaderField: "Cookie") ?? "")
                    .contains { $0.name == "_token" && $0.value == "quota-fixture" })
                return try Self.response(url: url, body: Self.quotaJSON)
            }

            let snapshot = try await self.fetch(cookies: cookies, stub: stub)
            #expect(snapshot.usedPercent == 25)
            #expect(await stub.requests().count == 1)
        }
    }

    @Test
    func `proxy page aliases require canonical request authentication`() async throws {
        let environment = [
            MiniMaxSettingsReader.codingPlanURLKey: "https://proxy.example/capture/page",
            MiniMaxSettingsReader.remainsURLKey: "https://proxy.example/capture/quota",
        ]
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "proxy.example")
            #expect(url.path == "/capture/quota")
            return try Self.response(url: url, body: Self.quotaJSON)
        }

        let snapshot = try await self.fetch(cookies: Self.quotaCookies(), stub: stub, environment: environment)
        #expect(snapshot.usedPercent == 25)
        #expect(await stub.requests().count == 1)
    }

    @Test(arguments: [MiniMaxWebSessionDomain.global, .legacyChina])
    func `unrelated token cookies do not block a WWW HERTZ quota session`(
        domain: MiniMaxWebSessionDomain) async throws
    {
        let cookies = [
            Self.cookie(domain: domain.rootDomain, path: "/", name: "_token", value: "other-product", subdomains: true),
            Self.cookie(domain: "www.\(domain.rootDomain)", path: "/v1", name: "HERTZ-SESSION", value: "www-fixture"),
        ]
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "www.\(domain.rootDomain)")
            #expect(url.path == "/v1/api/openplatform/coding_plan/remains")
            return try Self.response(url: url, body: Self.quotaJSON)
        }
        let session = MiniMaxWebSession(
            cookieHeader: "HERTZ-SESSION=www-fixture",
            sourceLabel: "Fixture Profile",
            domain: domain,
            cookies: cookies)

        let snapshot = try await MiniMaxUsageFetcher.fetchBrowserUsage(
            browserSession: session,
            region: domain == .global ? .global : .chinaMainland,
            includeBillingHistory: false,
            session: stub)
        #expect(snapshot.usedPercent == 25)
        #expect(await stub.requests().count == 1)
    }

    @Test(arguments: ["_token", "HERTZ-SESSION"], [false, true])
    func `server rejection of a genuinely authenticated page remains an authentication error`(
        name: String,
        signInPage: Bool) async
    {
        let cookies = Self.quotaCookies() + [Self.cookie(
            domain: "platform.minimax.cn",
            path: "/console",
            name: name,
            value: "expired-fixture")]
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/console/usage")
            return try Self.response(
                url: url,
                body: signInPage ? "<html>Sign in</html>" : "{}",
                status: signInPage ? 200 : 401,
                html: signInPage)
        }

        await #expect(throws: MiniMaxUsageError.invalidCredentials) {
            try await self.fetch(cookies: cookies, stub: stub)
        }
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `valid scoped HERTZ page sessions still return complete HTML quota`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/console/usage")
            #expect(CookieHeaderNormalizer.pairs(from: request.value(forHTTPHeaderField: "Cookie") ?? "")
                .contains { $0.name == "HERTZ-SESSION" && $0.value == "page-fixture" })
            return try Self.response(
                url: url,
                body: "<script id=\"__NEXT_DATA__\">\(Self.quotaJSON)</script>",
                html: true)
        }
        let cookies = Self.quotaCookies() + [Self.cookie(
            domain: "platform.minimax.cn",
            path: "/console",
            name: "HERTZ-SESSION",
            value: "page-fixture")]

        #expect(try await self.fetch(cookies: cookies, stub: stub).usedPercent == 25)
        #expect(await stub.requests().count == 1)
    }

    @Test(arguments: [false, true])
    func `an independent bearer can authenticate probes but an out of scope cookie bearer cannot`(
        cookieDerived: Bool) async throws
    {
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "analytics=fixture")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer storage-fixture")
            return try Self.response(url: #require(request.url), body: "{}")
        }
        let transport = self.transport(
            cookies: Self.quotaCookies(),
            stub: stub,
            cookieBearer: cookieDerived ? "storage-fixture" : nil)
        var request = try URLRequest(url: #require(URL(string: "https://platform.minimax.cn/console/usage")))
        request.setValue("Bearer storage-fixture", forHTTPHeaderField: "Authorization")

        if cookieDerived {
            await #expect(throws: MiniMaxUsageError.self) { try await transport.data(for: request) }
        } else {
            _ = try await transport.data(for: request)
        }
        #expect(await stub.requests().count == (cookieDerived ? 0 : 1))
    }

    @Test(arguments: [
        "https://platform.minimax.cn/account/amount",
        "https://www.minimax.cn/v1/api/openplatform/charge/combo/cycle_audio_resource_package",
    ])
    func `optional endpoints retain their existing nonstandard cookie authentication`(url: String) async throws {
        let url = try #require(URL(string: url))
        let cookies = try [Self.cookie(
            domain: #require(url.host),
            path: url.path,
            name: "optional-session",
            value: "fixture")]
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "optional-session=fixture")
            return try Self.response(url: #require(request.url), body: "{}")
        }

        _ = try await self.transport(cookies: cookies, stub: stub).data(for: URLRequest(url: url))
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `HERTZ cookie names preserve case insensitive authentication and bearer compatibility`() throws {
        let cookies = [Self.cookie(
            domain: "platform.minimax.cn",
            path: "/console",
            name: "hertz-session",
            value: "page-fixture")]
        let stub = ProviderHTTPTransportStub { _ in throw URLError(.unsupportedURL) }
        let transport = self.transport(cookies: cookies, stub: stub, cookieBearer: "page-fixture")
        var request = try URLRequest(url: #require(URL(string: "https://platform.minimax.cn/console/usage")))
        request.setValue("Bearer page-fixture", forHTTPHeaderField: "Authorization")

        let authenticated = try transport.authenticatedRequest(request)
        #expect(authenticated.value(forHTTPHeaderField: "Authorization") == "Bearer page-fixture")
        #expect(authenticated.value(forHTTPHeaderField: "Cookie") == "hertz-session=page-fixture")
        #expect(MiniMaxWebSession
            .hasAuthenticationCookie(in: "HERTZ-SESSION= ; _token=", domain: .chinaMainland) == false)
    }

    #if os(macOS)
    @Test(arguments: [MiniMaxWebSessionDomain.global, .legacyChina])
    func `import chooses the authenticated WWW header and its group over unrelated root cookies`(
        domain: MiniMaxWebSessionDomain) throws
    {
        let records = [
            BrowserCookieRecord(
                domain: domain.rootDomain,
                name: "_token",
                path: "/",
                value: "other-product",
                expires: nil,
                isSecure: true,
                isHTTPOnly: true,
                scope: .domain),
            BrowserCookieRecord(
                domain: "www.\(domain.rootDomain)",
                name: "HERTZ-SESSION",
                path: "/v1",
                value: "www-fixture",
                expires: nil,
                isSecure: true,
                isHTTPOnly: true,
                scope: .hostOnly),
            BrowserCookieRecord(
                domain: "www.\(domain.rootDomain)",
                name: "minimax_group_id_v2",
                path: "/v1",
                value: "123456",
                expires: nil,
                isSecure: true,
                isHTTPOnly: true,
                scope: .hostOnly),
        ]
        let imported = MiniMaxCookieImporter.SessionInfo(records: records, sourceLabel: "Fixture Profile")
        let session = try #require(imported.webSessions(for: domain == .global ? .global : .chinaMainland).first)

        #expect(session.domain == domain)
        #expect(CookieHeaderNormalizer.pairs(from: session.cookieHeader).contains {
            $0.name == "HERTZ-SESSION" && $0.value == "www-fixture"
        })
        #expect(session.groupID == "123456")
    }
    #endif

    private static func quotaCookies(
        analyticsFirst: Bool = false,
        includeAnalytics: Bool = true) -> [MiniMaxBrowserCookie]
    {
        let token = self.cookie(domain: "www.minimax.cn", path: "/backend", name: "_token", value: "quota-fixture")
        guard includeAnalytics else { return [token] }
        let analytics = self.cookie(
            domain: "minimax.cn",
            path: "/",
            name: "analytics",
            value: "fixture",
            subdomains: true)
        return analyticsFirst ? [analytics, token] : [token, analytics]
    }

    private static func cookie(
        domain: String,
        path: String,
        name: String,
        value: String,
        subdomains: Bool = false) -> MiniMaxBrowserCookie
    {
        MiniMaxBrowserCookie(
            domain: domain,
            includesSubdomains: subdomains,
            path: path,
            name: name,
            value: value,
            expires: nil,
            isSecure: true)
    }

    private func transport(
        cookies: [MiniMaxBrowserCookie],
        stub: ProviderHTTPTransportStub,
        environment: [String: String] = [:],
        cookieBearer: String? = nil) -> MiniMaxBrowserSessionTransport
    {
        MiniMaxBrowserSessionTransport(
            session: MiniMaxWebSession(
                cookieHeader: "_token=quota-fixture",
                sourceLabel: "Fixture Profile",
                domain: .chinaMainland,
                cookies: cookies),
            region: .chinaMainland,
            environment: environment,
            cookieBearer: cookieBearer,
            transport: stub)
    }

    private func fetch(
        cookies: [MiniMaxBrowserCookie],
        stub: ProviderHTTPTransportStub,
        environment: [String: String] = [:]) async throws -> MiniMaxUsageSnapshot
    {
        try await MiniMaxUsageFetcher.fetchBrowserUsage(
            browserSession: MiniMaxWebSession(
                cookieHeader: "_token=quota-fixture",
                sourceLabel: "Fixture Profile",
                domain: .chinaMainland,
                cookies: cookies),
            region: .chinaMainland,
            environment: environment,
            includeBillingHistory: false,
            session: stub)
    }

    private static func response(
        url: URL,
        body: String,
        status: Int = 200,
        html: Bool = false) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": html ? "text/html" : "application/json"]))
        return (Data(body.utf8), response)
    }

    private static let quotaJSON = """
    {"base_resp":{"status_code":0},"model_remains":[{
      "model_name":"general","current_interval_used_percent":"25%","current_interval_total_percent":"100%"
    }]}
    """
}
