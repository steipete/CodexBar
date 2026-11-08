import Foundation
import Testing
@testable import CodexBarCore

struct MiniMaxUsageSummaryFetchTests {
    private static let now = ISO8601DateFormatter().date(from: "2026-11-08T04:00:00Z")!
    private static let cookie = "_token=fixture; minimax_group_id_v2=1234"

    @Test
    func `china cookie refresh loads quota and token statistics from the same session`() async throws {
        let transport = Self.transport(summaryBody: Self.summaryJSON)
        let snapshot = try await Self.fetch(transport: transport)

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(snapshot.usageSummary != nil)
        let requests = await transport.requests()
        #expect(requests.compactMap { $0.url?.path }.filter { $0.hasPrefix("/backend/account/token_plan/") } == [
            "/backend/account/token_plan/remains_percent",
            "/backend/account/token_plan/usage_summary",
        ])
        #expect(requests.allSatisfy { $0.url?.path != "/account/amount" })
        let summaryRequest = try #require(requests.last)
        #expect(summaryRequest.url?.host == "www.minimax.cn")
        #expect(summaryRequest.httpMethod == "GET")
        #expect(summaryRequest.value(forHTTPHeaderField: "Cookie") == Self.cookie)
        #expect(summaryRequest.value(forHTTPHeaderField: "X-Group-Id") == "1234")
        #expect(summaryRequest.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func `optional usage disabled skips token statistics`() async throws {
        let transport = Self.transport(summaryBody: Self.summaryJSON)
        let snapshot = try await Self.fetch(transport: transport, includeOptionalUsage: false)

        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(await transport.requests().allSatisfy { $0.url?.path.hasSuffix("usage_summary") != true })
    }

    @Test(arguments: [401, 403, 404, 500])
    func `statistics HTTP failure preserves valid quota`(status: Int) async throws {
        let transport = Self.transport(summaryBody: "{}", summaryStatus: status)
        let snapshot = try await Self.fetch(transport: transport)

        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
        #expect(await transport.requests().filter { $0.url?.path.hasSuffix("usage_summary") == true }.count == 1)
    }

    @Test(arguments: [
        #"{"base_resp":{"status_code":1004,"status_msg":"not login"}}"#,
        #"{"base_resp":{"status_code":0},"date_model_usage":"invalid"}"#,
        "<html>unavailable</html>",
    ])
    func `statistics authentication or schema failure preserves valid quota`(body: String) async throws {
        let snapshot = try await Self.fetch(transport: Self.transport(summaryBody: body))

        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
    }

    @Test
    func `statistics network failure preserves valid quota`() async throws {
        let transport = Self.transport(summaryError: URLError(.notConnectedToInternet))
        let snapshot = try await Self.fetch(transport: transport)

        #expect(snapshot.usageSummary == nil)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 4)
    }

    @Test
    func `statistics cancellation is propagated`() async {
        await #expect(throws: CancellationError.self) {
            try await Self.fetch(transport: Self.transport(summaryError: CancellationError()))
        }
        await #expect(throws: URLError(.cancelled)) {
            try await Self.fetch(transport: Self.transport(summaryError: URLError(.cancelled)))
        }
    }

    @Test
    func `statistics keeps the explicit group used by quota`() async throws {
        let transport = Self.transport(summaryBody: Self.summaryJSON)
        _ = try await Self.fetch(transport: transport, groupID: "5678")
        let requests = await transport.requests()

        let scopedRequests = requests.filter { $0.url?.path.hasPrefix("/backend/account/token_plan/") == true }
        #expect(scopedRequests.count == 2)
        #expect(scopedRequests.allSatisfy { $0.value(forHTTPHeaderField: "X-Group-Id") == "5678" })
    }

    @Test
    func `statistics endpoint excludes legacy global and custom hosts`() {
        let cases: [(MiniMaxAPIRegion, String, [String: String])] = [
            (.global, Self.cookie, [:]),
            (.chinaMainland, "HERTZ-SESSION=fixture", [:]),
            (.chinaMainland, Self.cookie, [MiniMaxSettingsReader.hostKey: "platform.minimaxi.com"]),
            (.chinaMainland, Self.cookie, [MiniMaxSettingsReader.hostKey: "proxy.example"]),
            (.chinaMainland, Self.cookie, [MiniMaxSettingsReader.codingPlanURLKey: "https://proxy.example/page"]),
            (.chinaMainland, Self.cookie, [MiniMaxSettingsReader.remainsURLKey: "https://proxy.example/quota"]),
            (
                .chinaMainland,
                Self.cookie,
                [MiniMaxSettingsReader.billingHistoryURLKey: "https://proxy.example/billing"]),
        ]
        for (region, cookie, environment) in cases {
            let context = MiniMaxUsageFetcher.WebFetchContext(
                cookie: cookie,
                authorizationToken: nil,
                region: region,
                environment: environment,
                transport: Self.transport())
            #expect(MiniMaxUsageFetcher.usageSummaryURL(context: context) == nil)
        }
    }

    @Test
    func `statistics accepts the canonical endpoints used by automatic import`() {
        let context = MiniMaxUsageFetcher.WebFetchContext(
            cookie: Self.cookie,
            authorizationToken: nil,
            region: .chinaMainland,
            environment: [
                MiniMaxSettingsReader.codingPlanURLKey: "https://platform.minimax.cn/console/usage",
                MiniMaxSettingsReader.remainsURLKey:
                    "https://www.minimax.cn/backend/account/token_plan/remains_percent",
            ],
            transport: Self.transport())
        #expect(MiniMaxUsageFetcher.usageSummaryURL(context: context)?.path
            == "/backend/account/token_plan/usage_summary")
    }

    @Test
    func `API key quota does not import a web session or fetch statistics`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.path == "/v1/token_plan/remains")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-cp-fixture")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            return Self.response(url: url, body: Self.quotaJSON)
        }
        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            apiToken: "sk-cp-fixture",
            region: .chinaMainland,
            now: Self.now,
            session: transport)

        #expect(snapshot.usageSummary == nil)
        #expect(await transport.requests().count == 1)
    }

    private static func fetch(
        transport: ProviderHTTPTransportStub,
        includeOptionalUsage: Bool = true,
        groupID: String? = nil) async throws -> MiniMaxUsageSnapshot
    {
        try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: self.cookie,
            groupID: groupID,
            region: .chinaMainland,
            environment: [:],
            includeBillingHistory: includeOptionalUsage,
            session: transport,
            now: self.now)
    }

    private static func transport(
        summaryBody: String = "{}",
        summaryStatus: Int = 200,
        summaryError: (any Error & Sendable)? = nil) -> ProviderHTTPTransportStub
    {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/console/usage":
                return Self.response(url: url, body: "<html></html>", contentType: "text/html")
            case "/backend/account/token_plan/remains_percent":
                #expect(request.value(forHTTPHeaderField: "Cookie") == Self.cookie)
                return Self.response(url: url, body: Self.quotaJSON)
            case "/backend/account/token_plan/usage_summary":
                if let summaryError { throw summaryError }
                return Self.response(url: url, body: summaryBody, status: summaryStatus)
            case "/v1/api/openplatform/charge/combo/cycle_audio_resource_package":
                return Self.response(url: url, body: "{}", status: 404)
            default:
                Issue.record("Unexpected request to \(url.path)")
                return Self.response(url: url, body: "{}", status: 404)
            }
        }
    }

    private static func response(
        url: URL,
        body: String,
        status: Int = 200,
        contentType: String = "application/json") -> (Data, HTTPURLResponse)
    {
        (Data(body.utf8), HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType])!)
    }

    private static let quotaJSON = """
    {"base_resp":{"status_code":0},"model_remains":[{"model_name":"general",
      "current_interval_used_percent":"4%","current_interval_total_percent":"100%"}]}
    """

    private static let summaryJSON = """
    {"base_resp":{"status_code":0},"last_update_time":"11-08 12:00",
      "date_model_usage":[{"date":"2026-11-08","models":[],
        "total_input_token":1000,"total_output_token":200,"total_token":1200,
        "total_cache_read_token":400,"total_cache_create_token":0}]}
    """
}
