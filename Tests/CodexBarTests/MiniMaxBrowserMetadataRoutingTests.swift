import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct MiniMaxBrowserMetadataRoutingTests {
    private static let quotaPath = "/v1/api/openplatform/coding_plan/remains"
    private static let metadataPath = "/v1/api/openplatform/charge/combo/cycle_audio_resource_package"
    private static let groupID = "123456"

    @Test
    func `typed legacy browser refresh keeps www quota and metadata when optional billing is disabled`() async throws {
        let browserSession = try Self.browserSession(
            tokens: [("www.minimaxi.com", "www-fixture")],
            initialHost: "www.minimaxi.com")
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "www.minimaxi.com")
            #expect(Self.cookieValue("HERTZ-SESSION", in: request) == "www-fixture")
            #expect(Self.cookieValue("minimax_group_id_v2", in: request) == Self.groupID)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.httpShouldHandleCookies == false)
            if url.path == Self.quotaPath {
                return Self.response(url: url, body: Self.quotaJSON)
            }
            #expect(url.path == Self.metadataPath)
            #expect(request.value(forHTTPHeaderField: "X-Group-Id") == Self.groupID)
            return Self.response(url: url, body: Self.metadataJSON)
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchBrowserUsage(
            browserSession: browserSession,
            groupID: browserSession.groupID,
            region: .chinaMainland,
            includeBillingHistory: false,
            session: stub)

        #expect(snapshot.usedPercent == 25)
        #expect(snapshot.planName == "TokenPlanMax")
        #expect(snapshot.subscriptionExpiresAt == Date(timeIntervalSince1970: 1_810_656_000))
        #expect(snapshot.billingSummary == nil)
        #expect(await stub.requests().map { $0.url?.path } == [Self.quotaPath, Self.metadataPath])
    }

    @Test
    func `typed browser refresh respects an explicit platform host for metadata`() async throws {
        let browserSession = try Self.browserSession(
            tokens: [
                ("platform.minimaxi.com", "platform-fixture"),
                ("www.minimaxi.com", "www-fixture"),
            ],
            initialHost: "platform.minimaxi.com")
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "platform.minimaxi.com")
            #expect(Self.cookieValue("HERTZ-SESSION", in: request) == "platform-fixture")
            #expect(url.path == Self.quotaPath || url.path == Self.metadataPath)
            if url.path == Self.metadataPath {
                #expect(request.value(forHTTPHeaderField: "X-Group-Id") == Self.groupID)
            }
            return Self.response(url: url, body: url.path == Self.quotaPath ? Self.quotaJSON : Self.metadataJSON)
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchBrowserUsage(
            browserSession: browserSession,
            groupID: browserSession.groupID,
            region: .chinaMainland,
            environment: [MiniMaxSettingsReader.hostKey: "https://platform.minimaxi.com"],
            includeBillingHistory: false,
            session: stub)

        #expect(snapshot.usedPercent == 25)
        #expect(snapshot.planName == "TokenPlanMax")
        #expect(await stub.requests().map { $0.url?.host } == ["platform.minimaxi.com", "platform.minimaxi.com"])
        #expect(await stub.requests().map { $0.url?.path } == [Self.quotaPath, Self.metadataPath])
    }

    @Test
    func `legacy proxy metadata uses its canonical www cookie instead of the platform quota cookie`() async throws {
        let browserSession = try Self.browserSession(
            tokens: [
                ("platform.minimaxi.com", "quota-fixture"),
                ("www.minimaxi.com", "metadata-fixture"),
            ],
            initialHost: "platform.minimaxi.com")
        let stub = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "proxy.example")
            #expect(url.path == Self.quotaPath || url.path == Self.metadataPath)
            #expect(Self.cookieValue("HERTZ-SESSION", in: request) ==
                (url.path == Self.quotaPath ? "quota-fixture" : "metadata-fixture"))
            #expect(Self.cookieValue("minimax_group_id_v2", in: request) == Self.groupID)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if url.path == Self.metadataPath {
                #expect(request.value(forHTTPHeaderField: "X-Group-Id") == Self.groupID)
            }
            return Self.response(url: url, body: url.path == Self.quotaPath ? Self.quotaJSON : Self.metadataJSON)
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchBrowserUsage(
            browserSession: browserSession,
            groupID: browserSession.groupID,
            region: .chinaMainland,
            environment: [MiniMaxSettingsReader.hostKey: "https://proxy.example"],
            includeBillingHistory: false,
            session: stub)

        #expect(snapshot.usedPercent == 25)
        #expect(snapshot.planName == "TokenPlanMax")
        #expect(await stub.requests().map { $0.url?.host } == ["proxy.example", "proxy.example"])
        #expect(await stub.requests().map { $0.url?.path } == [Self.quotaPath, Self.metadataPath])
    }

    @Test(arguments: [
        MiniMaxSettingsReader.hostKey,
        MiniMaxSettingsReader.codingPlanURLKey,
        MiniMaxSettingsReader.remainsURLKey,
        MiniMaxSettingsReader.billingHistoryURLKey,
    ])
    func `typed browser entry rejects invalid original endpoint overrides without network requests`(
        key: String) async throws
    {
        let browserSession = try Self.browserSession(
            tokens: [("www.minimaxi.com", "www-fixture")],
            initialHost: "www.minimaxi.com")
        let stub = ProviderHTTPTransportStub { _ in
            Issue.record("Rejected endpoint overrides must not reach the transport")
            throw URLError(.unsupportedURL)
        }

        await #expect(throws: ProviderEndpointOverrideError.minimax(key)) {
            try await MiniMaxUsageFetcher.fetchBrowserUsage(
                browserSession: browserSession,
                groupID: browserSession.groupID,
                region: .chinaMainland,
                environment: [key: "http://invalid.example"],
                includeBillingHistory: false,
                session: stub)
        }
        #expect(await stub.requests().isEmpty)
    }

    private static func browserSession(
        tokens: [(host: String, token: String)],
        initialHost: String) throws -> MiniMaxWebSession
    {
        let cookies = tokens.flatMap { entry in
            [
                Self.cookie(host: entry.host, name: "HERTZ-SESSION", value: entry.token),
                Self.cookie(host: entry.host, name: "minimax_group_id_v2", value: Self.groupID),
            ]
        }
        let url = try #require(URL(string: "https://\(initialHost)\(Self.quotaPath)"))
        let header = try #require(MiniMaxWebSession.cookieHeader(from: cookies, for: url))
        return MiniMaxWebSession(
            cookieHeader: header,
            sourceLabel: "Fixture Profile",
            domain: .legacyChina,
            cookies: cookies)
    }

    private static func cookie(host: String, name: String, value: String) -> MiniMaxBrowserCookie {
        MiniMaxBrowserCookie(
            domain: host,
            includesSubdomains: false,
            path: "/v1",
            name: name,
            value: value,
            expires: nil,
            isSecure: true)
    }

    private static func cookieValue(_ name: String, in request: URLRequest) -> String? {
        CookieHeaderNormalizer.pairs(from: request.value(forHTTPHeaderField: "Cookie") ?? "")
            .first { $0.name == name }?.value
    }

    private static func response(url: URL, body: String) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!)
    }

    private static let quotaJSON = """
    {"base_resp":{"status_code":0},"model_remains":[{
      "model_name":"general","current_interval_used_percent":"25%","current_interval_total_percent":"100%"
    }]}
    """

    private static let metadataJSON = """
    {"base_resp":{"status_code":0},"data":{"current_subscribe":{
      "current_subscribe_title":"TokenPlanMax","current_subscribe_end_time_ts":1810656000000
    }}}
    """
}
