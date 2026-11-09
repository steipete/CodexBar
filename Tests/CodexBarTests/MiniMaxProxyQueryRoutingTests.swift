import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxProxyQueryRoutingTests {
    @Test
    func `typed browser refresh selects separate page and quota cookies for query routed proxy aliases`() async throws {
        let environment = [
            MiniMaxSettingsReader.codingPlanURLKey: "https://proxy.example/forward?target=page",
            MiniMaxSettingsReader.remainsURLKey: "https://proxy.example/forward?target=quota",
        ]
        let browserSession = MiniMaxWebSession(
            cookieHeader: "HERTZ-SESSION=quota-fixture",
            sourceLabel: "Fixture Profile",
            domain: .global,
            cookies: [
                Self.cookie(path: "/user-center", value: "page-fixture"),
                Self.cookie(path: "/v1", value: "quota-fixture"),
            ])
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(url.host == "proxy.example")
            #expect(url.path == "/forward")
            switch items.first(where: { $0.name == "target" })?.value {
            case "page":
                #expect(request.value(forHTTPHeaderField: "Cookie") == "HERTZ-SESSION=page-fixture")
                return try Self.response(
                    url: url,
                    body: "<html>Fixture page without embedded usage.</html>",
                    html: true)
            case "quota":
                #expect(request.value(forHTTPHeaderField: "Cookie") == "HERTZ-SESSION=quota-fixture")
                #expect(items.contains(URLQueryItem(name: "GroupId", value: "123456")))
                return try Self.response(url: url, body: Self.quotaJSON)
            default:
                Issue.record("Only configured page and quota aliases should reach the transport")
                throw URLError(.unsupportedURL)
            }
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchBrowserUsage(
            browserSession: browserSession,
            groupID: "123456",
            region: .global,
            environment: environment,
            includeBillingHistory: false,
            session: stub)

        #expect(snapshot.usedPercent == 25)
        #expect(await stub.requests().count == 2)
    }

    @Test
    func `page query parameters remain route selectors outside billing pagination`() throws {
        let environment = [
            MiniMaxSettingsReader.codingPlanURLKey: "https://proxy.example/forward?page=html",
            MiniMaxSettingsReader.remainsURLKey: "https://proxy.example/forward?page=quota",
        ]

        #expect(try self.origin("https://proxy.example/forward?page=html", environment: environment)?.path ==
            "/user-center/payment/coding-plan")
        #expect(try self.origin("https://proxy.example/forward?page=quota&GroupId=123456", environment: environment)?
            .path ==
            "/v1/api/openplatform/coding_plan/remains")
        #expect(try self.origin("https://proxy.example/forward?page=unknown", environment: environment) == nil)
    }

    @Test
    func `alias query matching preserves duplicate item order and multiplicity`() throws {
        let environment = [
            MiniMaxSettingsReader.codingPlanURLKey: "https://proxy.example/forward?target=page&tag=a&tag=a&tag=b",
        ]
        let configured = "https://proxy.example/forward?target=page&tag=a&tag=a&tag=b"
        #expect(try self.origin(configured, environment: environment)?.path == "/user-center/payment/coding-plan")
        for query in [
            "target=page&tag=b&tag=a&tag=a",
            "target=page&tag=a&tag=b",
            "target=page&tag=a&tag=a&tag=a&tag=b",
            "target=page&tag=a&tag=a&tag=b&unexpected=value",
        ] {
            #expect(try self.origin("https://proxy.example/forward?\(query)", environment: environment) == nil)
        }
    }

    @Test
    func `plain aliases do not consume requests carrying another query route`() throws {
        let environment = [
            MiniMaxSettingsReader.codingPlanURLKey: "https://proxy.example/forward",
            MiniMaxSettingsReader.remainsURLKey: "https://proxy.example/forward?target=quota",
        ]

        #expect(try self.origin("https://proxy.example/forward", environment: environment)?.path ==
            "/user-center/payment/coding-plan")
        #expect(try self.origin("https://proxy.example/forward?target=quota", environment: environment)?.path ==
            "/v1/api/openplatform/coding_plan/remains")
        #expect(try self.origin("https://proxy.example/forward?target=unknown", environment: environment) == nil)
    }

    @Test
    func `billing aliases retain their route while the resolver replaces owned pagination fields`() throws {
        let environment = [
            MiniMaxSettingsReader.codingPlanURLKey: "https://proxy.example/forward?target=page",
            MiniMaxSettingsReader.remainsURLKey: "https://proxy.example/forward?target=quota",
            MiniMaxSettingsReader.billingHistoryURLKey:
                "https://proxy.example/forward?target=billing&page=8&limit=9&aggregate=true",
        ]
        let billing = MiniMaxUsageFetcher.resolveBillingHistoryURL(
            region: .global,
            environment: environment,
            page: 2,
            limit: 50)
        let items = try #require(URLComponents(url: billing, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(Set(items) == Set([
            URLQueryItem(name: "target", value: "billing"),
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "aggregate", value: "false"),
        ]))
        #expect(MiniMaxWebSessionDomain.global.cookieURL(for: billing, region: .global, environment: environment)?
            .path ==
            "/account/amount")
        #expect(try self.origin("https://proxy.example/forward?target=page", environment: environment)?.path ==
            "/user-center/payment/coding-plan")
        #expect(try self.origin("https://proxy.example/forward?target=quota&GroupId=123456", environment: environment)?
            .path ==
            "/v1/api/openplatform/coding_plan/remains")
        #expect(try self.origin(
            "https://proxy.example/forward?target=unknown&page=2&limit=50&aggregate=false",
            environment: environment) == nil)
    }

    @Test
    func `exact quota selectors take priority over mutable billing pagination`() throws {
        let quota = "https://proxy.example/forward?page=quota&limit=route&aggregate=route"
        let environment = [
            MiniMaxSettingsReader.remainsURLKey: quota,
            MiniMaxSettingsReader.billingHistoryURLKey: "https://proxy.example/forward",
        ]
        for suffix in ["", "&GroupId=123456"] {
            #expect(try self.origin(quota + suffix, environment: environment)?.path ==
                "/v1/api/openplatform/coding_plan/remains")
        }
        let billing = MiniMaxUsageFetcher.resolveBillingHistoryURL(
            region: .global, environment: environment, page: 2, limit: 50)
        #expect(MiniMaxWebSessionDomain.global
            .cookieURL(for: billing, region: .global, environment: environment)?.path == "/account/amount")
    }

    @Test
    func `combo proxy aliases preserve their default query values`() throws {
        let environment = [MiniMaxSettingsReader.hostKey: "https://proxy.example"]
        let combo = try MiniMaxSubscriptionMetadataFetcher.resolveComboURL(region: .global, environment: environment)
        let expected = try MiniMaxSubscriptionMetadataFetcher.resolveComboURL(region: .global, environment: [:])

        #expect(MiniMaxWebSessionDomain.global
            .cookieURL(for: combo, region: .global, environment: environment) == expected)
        var modified = try #require(URLComponents(url: combo, resolvingAgainstBaseURL: false))
        modified.queryItems = modified.queryItems?.map {
            $0.name == "cycle_type" ? URLQueryItem(name: $0.name, value: "9") : $0
        }
        #expect(try self.origin(#require(modified.url).absoluteString, environment: environment) == nil)
        modified = try #require(URLComponents(url: combo, resolvingAgainstBaseURL: false))
        modified.queryItems = modified.queryItems?.filter { $0.name != "biz_line" }
        #expect(try self.origin(#require(modified.url).absoluteString, environment: environment) == nil)
    }

    private func origin(_ raw: String, environment: [String: String]) throws -> URL? {
        try MiniMaxWebSessionDomain.global.cookieURL(
            for: #require(URL(string: raw)),
            region: .global,
            environment: environment)
    }

    private static func cookie(path: String, value: String) -> MiniMaxBrowserCookie {
        MiniMaxBrowserCookie(
            domain: "platform.minimax.io",
            includesSubdomains: false,
            path: path,
            name: "HERTZ-SESSION",
            value: value,
            expires: nil,
            isSecure: true)
    }

    private static func response(url: URL, body: String, html: Bool = false) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
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
