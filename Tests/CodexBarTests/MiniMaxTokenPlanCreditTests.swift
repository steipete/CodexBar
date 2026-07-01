import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MiniMaxTokenPlanCreditTests {
    @Test
    func `parses token plan credit balance from console payload`() throws {
        let data = try Data(contentsOf: Self.fixtureURL(named: "token-plan-credit-normal.json"))
        let balance = try MiniMaxTokenPlanCreditFetcher.parseBalance(data: data)
        #expect(balance == 20000)
    }

    @Test
    func `parses token plan credit balance from balance breakdown fallback`() throws {
        let body = """
        {
          "balance_breakdown": { "total_balance": 15000 },
          "base_resp": { "status_code": 0 }
        }
        """
        let balance = try MiniMaxTokenPlanCreditFetcher.parseBalance(data: Data(body.utf8))
        #expect(balance == 15000)
    }

    @Test
    func `parses token plan credit balance from total minus used fallback`() throws {
        let body = """
        {
          "total_credits": 20000,
          "used_credits": 3500,
          "base_resp": { "status_code": 0 }
        }
        """
        let balance = try MiniMaxTokenPlanCreditFetcher.parseBalance(data: Data(body.utf8))
        #expect(balance == 16500)
    }

    @Test
    func `token plan credit enrichment is best effort when session is invalid`() async {
        let remainsSnapshot = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: 1000,
            currentPrompts: 0,
            remainingPrompts: 1000,
            windowMinutes: 300,
            usedPercent: 0,
            resetsAt: nil,
            updatedAt: Date(),
            services: nil)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.httpResponse(
                url: url,
                body: #"{"base_resp":{"status_code":1004,"status_msg":"not login"}}"#,
                statusCode: 401,
                contentType: "application/json")
        }

        let enriched = await MiniMaxUsageFetcher.attachingTokenPlanCreditIfAvailable(
            to: remainsSnapshot,
            context: MiniMaxUsageFetcher.WebFetchContext(
                cookie: "HERTZ-SESSION=abc",
                authorizationToken: nil,
                region: .chinaMainland,
                environment: [:],
                transport: transport),
            groupID: nil)

        #expect(enriched.pointsBalance == nil)
        #expect(enriched.planName == "Max")
    }

    @Test
    func `web usage fetch merges token plan credit balance`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let creditJSON = try String(contentsOf: Self.fixtureURL(named: "token-plan-credit-normal.json"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.contains("coding-plan") {
                return Self.httpResponse(
                    url: url,
                    body: "<html><main>Coding Plan</main></html>",
                    contentType: "text/html")
            }
            if url.path.contains("coding_plan/remains") {
                return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
            }
            #expect(url.host == "www.minimaxi.com")
            #expect(url.path == "/backend/account/token_plan_credit")
            return Self.httpResponse(url: url, body: creditJSON, contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "HERTZ-SESSION=abc",
            region: .chinaMainland,
            environment: [:],
            includeBillingHistory: false,
            session: transport,
            now: now)

        #expect(snapshot.pointsBalance == 20000)
        #expect(snapshot.toUsageSnapshot().providerCost?.used == 20000)
        let requests = await transport.requests()
        #expect(requests.contains { $0.url?.path == "/backend/account/token_plan_credit" })
    }

    @Test
    func `api usage fetch merges token plan credit when cached cookie is available`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let creditJSON = try String(contentsOf: Self.fixtureURL(named: "token-plan-credit-normal.json"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path == "/v1/token_plan/remains" {
                return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
            }
            #expect(url.path == "/backend/account/token_plan_credit")
            return Self.httpResponse(url: url, body: creditJSON, contentType: "application/json")
        }

        let remainsSnapshot = try await MiniMaxUsageFetcher.fetchUsage(
            apiToken: "sk-cp-test",
            region: .chinaMainland,
            now: now,
            session: transport)
        let enriched = await MiniMaxUsageFetcher.attachingTokenPlanCreditIfAvailable(
            to: remainsSnapshot,
            context: MiniMaxUsageFetcher.WebFetchContext(
                cookie: "_token=abc; minimax_group_id_v2=2040544334402560487",
                authorizationToken: nil,
                region: .chinaMainland,
                environment: [:],
                transport: transport),
            groupID: "2040544334402560487")

        #expect(remainsSnapshot.pointsBalance == nil)
        #expect(enriched.pointsBalance == 20000)
    }

    private static func fixtureURL(named name: String) throws -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Providers/MiniMax", isDirectory: true)
        return root.appendingPathComponent(name)
    }

    private static let percentBasedRemainsJSON = """
    {
      "model_remains": [
        {
          "start_time": 1780279200000,
          "end_time": 1780297200000,
          "remains_time": 16659830,
          "current_interval_total_count": 0,
          "current_interval_usage_count": 0,
          "model_name": "general",
          "current_weekly_total_count": 0,
          "current_weekly_usage_count": 0,
          "weekly_start_time": 1780243200000,
          "weekly_end_time": 1780848000000,
          "weekly_remains_time": 567459830,
          "current_interval_status": 1,
          "current_interval_remaining_percent": 96,
          "current_weekly_status": 1,
          "current_weekly_remaining_percent": 99
        }
      ],
      "base_resp": { "status_code": 0, "status_msg": "success" }
    }
    """

    private static func httpResponse(
        url: URL,
        body: String,
        statusCode: Int = 200,
        contentType: String) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        return (Data(body.utf8), response)
    }
}
