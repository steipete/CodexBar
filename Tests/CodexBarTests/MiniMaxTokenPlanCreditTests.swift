import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MiniMaxTokenPlanCreditTests {
    @Test
    func `parses token plan credit balance from console payload`() throws {
        let data = try Data(contentsOf: Self.fixtureURL(named: "token-plan-credit-normal.json"))
        let snapshot = try MiniMaxTokenPlanCreditFetcher.parseSnapshot(data: data)
        #expect(snapshot.balance == 20000)
        #expect(snapshot.expiresAt == Date(timeIntervalSince1970: 1_784_995_199.999))
        #expect(snapshot.groupIDs == ["2040544334402560487"])
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
    func `token plan credit enrichment is best effort when session is invalid`() async throws {
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

        let enriched = try await MiniMaxUsageFetcher.attachingTokenPlanCreditIfAvailable(
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
    func `web usage fetch still enriches credit when billing history disabled`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
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
            if url.path == "/backend/account/token_plan_credit" {
                return Self.httpResponse(
                    url: url,
                    body: #"{"base_resp":{"status_code":1004,"status_msg":"not login"}}"#,
                    statusCode: 401,
                    contentType: "application/json")
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return Self.httpResponse(url: url, body: "{}", contentType: "application/json")
        }

        let snapshot = try await MiniMaxUsageFetcher.fetchUsage(
            cookieHeader: "HERTZ-SESSION=abc",
            region: .chinaMainland,
            environment: [:],
            includeBillingHistory: false,
            session: transport,
            now: now)

        #expect(snapshot.pointsBalance == nil)
        let requests = await transport.requests()
        #expect(!requests.contains { $0.url?.path.contains("account/amount") == true })
        #expect(requests.contains { $0.url?.path == "/backend/account/token_plan_credit" })
    }

    @Test
    func `token plan credit enrichment propagates cancellation`() async {
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
        let transport = ProviderHTTPTransportStub { _ in
            throw CancellationError()
        }

        await #expect(throws: CancellationError.self) {
            _ = try await MiniMaxUsageFetcher.attachingTokenPlanCreditIfAvailable(
                to: remainsSnapshot,
                context: MiniMaxUsageFetcher.WebFetchContext(
                    cookie: "HERTZ-SESSION=abc",
                    authorizationToken: nil,
                    region: .chinaMainland,
                    environment: [:],
                    transport: transport),
                groupID: nil)
        }
    }

    @Test
    func `token plan credit enrichment forwards group id from curl override`() async throws {
        let creditJSON = try String(contentsOf: Self.fixtureURL(named: "token-plan-credit-normal.json"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "x-group-id") == "2040544334402560487")
            return Self.httpResponse(url: url, body: creditJSON, contentType: "application/json")
        }
        let curl = """
        curl 'https://platform.minimaxi.com/' \\
          -H 'Cookie: HERTZ-SESSION=abc' \\
          -H 'x-group-id: 2040544334402560487'
        """
        guard let override = MiniMaxCookieHeader.override(from: curl),
              let cookie = MiniMaxCookieHeader.normalized(from: override.cookieHeader)
        else {
            Issue.record("Expected curl override to preserve group id")
            return
        }

        let enriched = try await MiniMaxUsageFetcher.attachingTokenPlanCreditIfAvailable(
            to: MiniMaxUsageSnapshot(
                planName: "Max",
                availablePrompts: 1000,
                currentPrompts: 0,
                remainingPrompts: 1000,
                windowMinutes: 300,
                usedPercent: 0,
                resetsAt: nil,
                updatedAt: Date(),
                services: nil),
            context: MiniMaxUsageFetcher.WebFetchContext(
                cookie: cookie,
                authorizationToken: override.authorizationToken,
                region: .chinaMainland,
                environment: [:],
                transport: transport),
            groupID: override.groupID)

        #expect(enriched.pointsBalance == 20000)
    }

    @Test
    func `api usage fetch merges token plan credit when explicit cookie is available`() async throws {
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
        let enriched = try await MiniMaxUsageFetcher.attachingTokenPlanCreditIfAvailable(
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

    @Test
    func `dedicated credit endpoint replaces remains fallback balance`() {
        let snapshot = MiniMaxUsageSnapshot(
            planName: "Plus",
            availablePrompts: 100,
            currentPrompts: 0,
            remainingPrompts: 100,
            windowMinutes: 300,
            usedPercent: 0,
            resetsAt: nil,
            updatedAt: Date(),
            pointsBalance: 5000)

        let enriched = snapshot.withPointsBalanceFromDedicatedEndpoint(20000, expiresAt: nil)
        #expect(enriched.pointsBalance == 20000)
    }

    @Test
    func `credit enrichment fetches missing expiry without replacing existing balance`() async throws {
        let creditJSON = try String(contentsOf: Self.fixtureURL(named: "token-plan-credit-normal.json"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.httpResponse(url: url, body: creditJSON, contentType: "application/json")
        }
        let snapshot = MiniMaxUsageSnapshot(
            planName: "Max",
            availablePrompts: 1000,
            currentPrompts: 0,
            remainingPrompts: 1000,
            windowMinutes: 300,
            usedPercent: 0,
            resetsAt: nil,
            updatedAt: Date(),
            pointsBalance: 12345)

        let enriched = try await MiniMaxUsageFetcher.attachingTokenPlanCreditIfAvailable(
            to: snapshot,
            context: MiniMaxUsageFetcher.WebFetchContext(
                cookie: "HERTZ-SESSION=abc",
                authorizationToken: nil,
                region: .chinaMainland,
                environment: [:],
                transport: transport),
            groupID: nil)

        #expect(enriched.pointsBalance == 12345)
        #expect(enriched.pointsBalanceExpiresAt == Date(timeIntervalSince1970: 1_784_995_199.999))
    }

    @Test
    func `api token fetch resolves china region after global rejection`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.host == "api.minimax.io" {
                return Self.httpResponse(url: url, body: "{}", statusCode: 401, contentType: "application/json")
            }
            #expect(url.host == "api.minimaxi.com")
            return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
        }

        let result = try await MiniMaxUsageFetcher.fetchAPITokenUsage(
            apiToken: "sk-cp-test",
            region: .global,
            now: now,
            session: transport)

        #expect(result.resolvedRegion == .chinaMainland)
    }

    @Test
    func `api credit enrichment uses resolved china web host after global retry`() async throws {
        let now = Date(timeIntervalSince1970: 1_780_282_340)
        let creditJSON = try String(contentsOf: Self.fixtureURL(named: "token-plan-credit-normal.json"))
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.host == "api.minimax.io" {
                return Self.httpResponse(url: url, body: "{}", statusCode: 401, contentType: "application/json")
            }
            if url.host == "api.minimaxi.com", url.path.contains("remains") {
                return Self.httpResponse(url: url, body: Self.percentBasedRemainsJSON, contentType: "application/json")
            }
            #expect(url.host == "www.minimaxi.com")
            #expect(url.path == "/backend/account/token_plan_credit")
            return Self.httpResponse(url: url, body: creditJSON, contentType: "application/json")
        }

        let apiResult = try await MiniMaxUsageFetcher.fetchAPITokenUsage(
            apiToken: "sk-cp-test",
            region: .global,
            now: now,
            session: transport)
        let enriched = try await MiniMaxUsageFetcher.attachingTokenPlanCreditIfAvailable(
            to: apiResult.snapshot,
            context: MiniMaxUsageFetcher.WebFetchContext(
                cookie: "HERTZ-SESSION=abc",
                authorizationToken: nil,
                region: apiResult.resolvedRegion,
                environment: [:],
                transport: transport),
            groupID: nil)

        #expect(apiResult.resolvedRegion == .chinaMainland)
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

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINIMAX_LIVE_TEST"] == "1"))
    func `live env cookie resolves and fetches recharge balance`() async throws {
        let cookieHeader = try #require(MiniMaxSettingsReader.cookieHeader())
        let cookieOverride = MiniMaxCookieHeader.override(from: cookieHeader)
        let config = try #require(try CodexBarConfigStore().load())
        let minimax = try #require(config.providers.first { $0.id == .minimax })
        let apiToken = try #require(minimax.apiKey)
        let apiResult = try await MiniMaxUsageFetcher.fetchAPITokenUsage(
            apiToken: apiToken,
            region: MiniMaxAPIRegion(rawValue: minimax.region ?? "") ?? .global)
        let credit = try await MiniMaxTokenPlanCreditFetcher.fetch(
            cookieHeader: cookieHeader,
            groupID: cookieOverride?.groupID,
            region: apiResult.resolvedRegion,
            environment: [:],
            transport: ProviderHTTPClient.shared)
        print("LIVE_MINIMAX_COOKIE_RESOLVED=true")
        print("LIVE_MINIMAX_RESOLVED_REGION=\(apiResult.resolvedRegion.rawValue)")
        print("LIVE_MINIMAX_BALANCE=\(credit.balance.map { String($0) } ?? "nil")")
        let balanceValue = try #require(credit.balance)
        #expect(balanceValue >= 0)
        if let expectedRaw = ProcessInfo.processInfo.environment["MINIMAX_LIVE_TEST_EXPECTED_BALANCE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !expectedRaw.isEmpty,
            let expected = Double(expectedRaw)
        {
            #expect(balanceValue == expected)
        }
    }

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
