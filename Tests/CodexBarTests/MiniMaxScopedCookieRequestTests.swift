import Foundation
import Testing
#if os(macOS)
import SweetCookieKit
#endif
@testable import CodexBarCore

struct MiniMaxScopedCookieRequestTests {
    private static let pagePath = "/user-center/payment/coding-plan"
    private static let quotaPath = "/v1/api/openplatform/coding_plan/remains"
    private static let metadataPath = "/v1/api/openplatform/charge/combo/cycle_audio_resource_package"

    @Test
    func `page and quota requests receive only their matching same name cookie`() async throws {
        let cookies = [
            self.cookie(host: "platform.minimax.io", path: "/user-center", value: "page-fixture"),
            self.cookie(host: "platform.minimax.io", path: "/v1", value: "quota-fixture"),
        ]
        let session = self.session(cookies: cookies)
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let isPage = url.path == Self.pagePath
            #expect(isPage || url.path == Self.quotaPath)
            #expect(request.value(forHTTPHeaderField: "Cookie") ==
                "HERTZ-SESSION=\(isPage ? "page-fixture" : "quota-fixture")")
            #expect(request.httpShouldHandleCookies == false)
            return Self.response(url: url, body: isPage ? "<html></html>" : Self.quotaJSON, html: isPage)
        }

        let snapshot = try await self.fetch(session, stub: stub)
        #expect(snapshot.usedPercent == 25)
        #expect(await stub.requests().map { $0.url?.path } == [Self.pagePath, Self.quotaPath])
    }

    @Test
    func `www only legacy session skips unmatched platform requests locally`() async throws {
        let session = self.session(
            cookies: [self.cookie(host: "www.minimaxi.com", path: "/v1", value: "www-fixture")],
            domain: .legacyChina)
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "www.minimaxi.com")
            #expect(url.path == Self.quotaPath)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "HERTZ-SESSION=www-fixture")
            return Self.response(url: url, body: Self.quotaJSON)
        }

        let snapshot = try await self.fetch(session, stub: stub)
        #expect(snapshot.usedPercent == 25)
        #expect(await stub.requests().count == 1)
    }

    @Test(arguments: [false, true])
    func `missing matching cookies require an independent storage bearer`(hasStorageBearer: Bool) async throws {
        let session = self.session(cookies: [])
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer storage-fixture")
            return try Self.response(url: #require(request.url), body: "{}")
        }
        let transport = self.transport(session, stub: stub)
        var request = try URLRequest(url: #require(URL(string: "https://platform.minimax.io\(Self.quotaPath)")))
        request.setValue("HERTZ-SESSION=stale-header", forHTTPHeaderField: "Cookie")
        if hasStorageBearer { request.setValue("Bearer storage-fixture", forHTTPHeaderField: "Authorization") }

        if hasStorageBearer {
            _ = try await transport.data(for: request)
        } else {
            await #expect(throws: MiniMaxUsageError.self) { try await transport.data(for: request) }
        }
        #expect(await stub.requests().count == (hasStorageBearer ? 1 : 0))
    }

    @Test
    func `optional requests do not inherit a page cookie or its derived bearer`() async throws {
        let session = self.session(cookies: [
            self.cookie(host: "platform.minimaxi.com", path: "/user-center", value: "page-fixture"),
            self.cookie(
                host: "platform.minimaxi.com",
                path: "/v1/api/openplatform/coding_plan",
                value: "quota-fixture"),
            self.cookie(
                host: "platform.minimaxi.com",
                path: "/v1/api/openplatform/charge/combo",
                value: "metadata-fixture"),
            self.cookie(host: "platform.minimaxi.com", path: "/account", value: "billing-fixture"),
        ], domain: .legacyChina)
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let values = [
                Self.pagePath: "page-fixture",
                Self.quotaPath: "quota-fixture",
                Self.metadataPath: "metadata-fixture",
                "/account/amount": "billing-fixture",
            ]
            let value = try #require(values[url.path])
            #expect(request.value(forHTTPHeaderField: "Cookie") == "HERTZ-SESSION=\(value)")
            #expect(request.value(forHTTPHeaderField: "Authorization") ==
                (url.path == Self.pagePath ? "Bearer page-fixture" : nil))
            switch url.path {
            case Self.pagePath: return Self.response(url: url, body: "<html></html>", html: true)
            case Self.quotaPath: return Self.response(url: url, body: Self.quotaJSON)
            default:
                return Self.response(
                    url: url,
                    body: #"{"base_resp":{"status_code":0},"charge_records":[],"total_cnt":0}"#)
            }
        }
        let snapshot = try await self.fetch(
            session,
            stub: stub,
            bearer: "page-fixture",
            cookieBearer: "page-fixture",
            groupID: "123456",
            optional: true)

        #expect(snapshot.usedPercent == 25)
        #expect(snapshot.billingSummary != nil)
        #expect(await stub.requests().map { $0.url?.path } == [
            Self.pagePath,
            Self.quotaPath,
            Self.metadataPath,
            "/account/amount",
        ])
    }

    @Test
    func `proxy page and quota aliases keep canonical cookie paths and proxy URLs`() async throws {
        let environment = [
            MiniMaxSettingsReader.codingPlanURLKey: "https://proxy.example/capture/page",
            MiniMaxSettingsReader.remainsURLKey: "https://proxy.example/capture/quota",
        ]
        let session = self.session(cookies: [
            self.cookie(host: "platform.minimax.io", path: "/user-center", value: "page-fixture"),
            self.cookie(host: "platform.minimax.io", path: "/v1", value: "quota-fixture"),
        ])
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let isPage = url.path == "/capture/page"
            #expect(url.host == "proxy.example")
            #expect(isPage || url.path == "/capture/quota")
            #expect(request.value(forHTTPHeaderField: "Cookie") ==
                "HERTZ-SESSION=\(isPage ? "page-fixture" : "quota-fixture")")
            return Self.response(url: url, body: isPage ? "<html></html>" : Self.quotaJSON, html: isPage)
        }

        #expect(try await self.fetch(session, stub: stub, environment: environment).usedPercent == 25)
        #expect(await stub.requests().map { $0.url?.path } == ["/capture/page", "/capture/quota"])
    }

    @Test
    func `a scoped override makes the whole session uncacheable without retaining a stale root cookie`() async throws {
        let root = self.cookie(host: "minimax.cn", subdomains: true, value: "root-fixture", name: "_token")
        let scoped = self.cookie(host: "www.minimax.cn", path: "/backend", value: "quota-fixture", name: "_token")
        let session = self.session(cookies: [root, scoped], domain: .chinaMainland, header: "_token=quota-fixture")
        let stub = ProviderHTTPTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Cookie") == "_token=quota-fixture")
            return try Self.response(url: #require(request.url), body: "{}")
        }

        #expect(self.session(cookies: [root], domain: .chinaMainland, header: "_token=root-fixture")
            .cacheableCookieHeader == "_token=root-fixture")
        #expect(session.cacheableCookieHeader == nil)
        _ = try await self.transport(session, stub: stub).data(for: URLRequest(url: session.domain.quotaURL))
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `host only root cookies are neither cached nor sent to subdomains`() async throws {
        let session = self.session(cookies: [self.cookie(host: "minimax.io", value: "root-fixture")])
        let stub = ProviderHTTPTransportStub { _ in
            Issue.record("A host-only root cookie must not reach a subdomain")
            throw URLError(.unsupportedURL)
        }
        #expect(session.cacheableCookieHeader == nil)
        #expect(try session
            .cookieHeader(for: #require(URL(string: "https://minimax.io/"))) == "HERTZ-SESSION=root-fixture")
        await #expect(throws: MiniMaxUsageError.self) {
            try await self.transport(session, stub: stub).data(for: URLRequest(url: session.domain.quotaURL))
        }
        #expect(await stub.requests().isEmpty)
    }

    @Test(arguments: [
        "https://www.minimax.cn/backend/account/token_plan/remains_percent",
        "https://platform.minimaxi.com/v1/api/openplatform/coding_plan/remains",
        "http://platform.minimax.io/v1/api/openplatform/coding_plan/remains",
        "https://proxy.example/unknown",
    ])
    func `unapproved origins cannot receive cookies or independent storage bearers`(url: String) async throws {
        let session = self.session(cookies: [
            self.cookie(host: "minimax.io", subdomains: true, value: "root-fixture"),
        ])
        let stub = ProviderHTTPTransportStub { _ in
            Issue.record("An unapproved origin must be rejected locally")
            throw URLError(.unsupportedURL)
        }
        var request = try URLRequest(url: #require(URL(string: url)))
        request.setValue("Bearer storage-fixture", forHTTPHeaderField: "Authorization")
        await #expect(throws: MiniMaxUsageError.self) {
            try await self.transport(session, stub: stub).data(for: request)
        }
        #expect(await stub.requests().isEmpty)
    }

    @Test
    func `same origin redirects rescope cookies and drop an inapplicable cookie bearer`() throws {
        let session = self.session(cookies: [
            self.cookie(host: "platform.minimax.io", path: "/page", value: "page-fixture"),
            self.cookie(host: "platform.minimax.io", path: "/next", value: "next-fixture"),
            self.cookie(host: "www.minimax.io", path: "/next", value: "www-fixture"),
        ])
        let stub = ProviderHTTPTransportStub { _ in throw URLError(.unsupportedURL) }
        let delegate = MiniMaxBrowserSessionRedirectDelegate(transport: self.transport(
            session,
            stub: stub,
            cookieBearer: "page-fixture"))
        var redirected = try URLRequest(url: #require(URL(string: "https://platform.minimax.io/next")))
        redirected.setValue("HERTZ-SESSION=page-fixture", forHTTPHeaderField: "Cookie")
        redirected.setValue("Bearer page-fixture", forHTTPHeaderField: "Authorization")
        let originalURL = try #require(URL(string: "https://platform.minimax.io/page"))
        let scoped = try #require(delegate.redirectRequest(originalURL: originalURL, request: redirected))

        #expect(scoped.value(forHTTPHeaderField: "Cookie") == "HERTZ-SESSION=next-fixture")
        #expect(scoped.value(forHTTPHeaderField: "Authorization") == nil)
        redirected.url = try #require(URL(string: "https://platform.minimax.io/empty"))
        #expect(delegate.redirectRequest(originalURL: originalURL, request: redirected) == nil)
        redirected.url = try #require(URL(string: "https://www.minimax.io/next"))
        #expect(delegate.redirectRequest(originalURL: originalURL, request: redirected) == nil)
    }

    #if os(macOS)
    @Test
    func `page only browser records remain importable without widening a host only root cookie`() async throws {
        let records = [
            BrowserCookieRecord(
                domain: "platform.minimax.io",
                name: "HERTZ-SESSION",
                path: "/user-center",
                value: "page-fixture",
                expires: nil,
                isSecure: true,
                isHTTPOnly: true,
                scope: .hostOnly),
            BrowserCookieRecord(
                domain: "minimax.io",
                name: "root-only",
                path: "/",
                value: "root-fixture",
                expires: nil,
                isSecure: true,
                isHTTPOnly: true,
                scope: .hostOnly),
        ]
        let imported = MiniMaxCookieImporter.SessionInfo(records: records, sourceLabel: "Fixture Profile")
        let session = try #require(imported.webSessions(for: .global).first)
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == Self.pagePath)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "HERTZ-SESSION=page-fixture")
            return Self.response(url: url, body: "<script id=\"__NEXT_DATA__\">\(Self.quotaJSON)</script>", html: true)
        }

        #expect(session.cacheableCookieHeader == nil)
        #expect(try session.cookieHeader(for: #require(URL(string: "https://www.minimax.io\(Self.quotaPath)"))) == nil)
        #expect(try await self.fetch(session, stub: stub).usedPercent == 25)
        #expect(await stub.requests().count == 1)
    }
    #endif

    private func cookie(
        host: String,
        subdomains: Bool = false,
        path: String = "/",
        value: String,
        name: String = "HERTZ-SESSION") -> MiniMaxBrowserCookie
    {
        MiniMaxBrowserCookie(
            domain: host,
            includesSubdomains: subdomains,
            path: path,
            name: name,
            value: value,
            expires: nil,
            isSecure: true)
    }

    private func session(
        cookies: [MiniMaxBrowserCookie],
        domain: MiniMaxWebSessionDomain = .global,
        header: String = "HERTZ-SESSION=initial-fixture") -> MiniMaxWebSession
    {
        MiniMaxWebSession(cookieHeader: header, sourceLabel: "Fixture Profile", domain: domain, cookies: cookies)
    }

    private func transport(
        _ session: MiniMaxWebSession,
        stub: ProviderHTTPTransportStub,
        environment: [String: String] = [:],
        cookieBearer: String? = nil) -> MiniMaxBrowserSessionTransport
    {
        MiniMaxBrowserSessionTransport(
            session: session,
            region: session.domain == .global ? .global : .chinaMainland,
            environment: session.domain.environment(environment),
            cookieBearer: cookieBearer,
            transport: stub)
    }

    private func fetch(
        _ session: MiniMaxWebSession,
        stub: ProviderHTTPTransportStub,
        environment: [String: String] = [:],
        bearer: String? = nil,
        cookieBearer: String? = nil,
        groupID: String? = nil,
        optional: Bool = false) async throws -> MiniMaxUsageSnapshot
    {
        try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: session.cookieHeader,
            authorizationToken: bearer,
            groupID: groupID,
            region: session.domain == .global ? .global : .chinaMainland,
            environment: session.domain.environment(environment),
            includeBillingHistory: optional,
            session: self.transport(session, stub: stub, environment: environment, cookieBearer: cookieBearer))
    }

    private static func response(url: URL, body: String, html: Bool = false) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": html ? "text/html" : "application/json"])!)
    }

    private static let quotaJSON = """
    {"base_resp":{"status_code":0},"model_remains":[{
      "model_name":"general","current_interval_used_percent":"25%","current_interval_total_percent":"100%"
    }]}
    """
}
