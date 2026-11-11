import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ClaudePlatformAWSPluginTests {
    /// 2026-11-11T15:30:10Z, so the 30-day window starts on 2026-10-13 and the month on 2026-11-01.
    private static let wallClock = Date(timeIntervalSince1970: 1_794_411_010)
    private static let refreshedAt = "2026-11-11T12:02:11Z"

    /// SigV4 over the us-west-2 month-total request, computed independently for the fixture credentials.
    private static let westTotalAuthorization =
        "AWS4-HMAC-SHA256 Credential=AKIAFIXTURE/20261111/us-west-2/aws-external-anthropic/aws4_request, "
            + "SignedHeaders=host;x-amz-date, "
            + "Signature=f2f9f1f0252f37b8224855a1cb543b5c9fa624f4c0f55e33ad6d99f7dddc3c64"

    private struct Fixture: Sendable {
        var totalCode = 200
        var totalBody: [String: String] = [
            "us-west-2": ClaudePlatformAWSPluginTests.page([
                ClaudePlatformAWSPluginTests.costRow(
                    "2026-11-01T00:00:00Z", amount: "41280.000000", list: "51600.000000", requests: 1280,
                    workspace: "wrkspc_fixtureA"),
            ]),
            "us-east-1": ClaudePlatformAWSPluginTests.page([
                ClaudePlatformAWSPluginTests.costRow(
                    "2026-11-01T00:00:00Z", amount: "6000.000000", list: "6000.000000", requests: 150,
                    workspace: "wrkspc_fixtureB"),
                ClaudePlatformAWSPluginTests.costRow(
                    "2026-11-01T00:00:00Z", amount: "1280.000000", list: "1280.000000", requests: 20),
            ]),
        ]
        var dailyCode = 200
        var usageCode = 200
        var workspaceCode = ["us-west-2": 200, "us-east-1": 403]
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `regions are summed into month spend, daily history, and workspace rows`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(engine: engine)
        let cost = try #require(snapshot.providerCost)
        #expect(abs(cost.used - 485.6) < 0.000_001)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "This month")
        #expect(snapshot.primary == nil)
        #expect(snapshot.identity?.loginMethod == "AWS access key")
        #expect(snapshot.dataConfidence == .exact)

        #expect(snapshot.details.map(\.title) == ["Spend", "By region", "By workspace"])
        let spend = snapshot.details[0].rows
        #expect(spend.map(\.label) == ["This month", "Today", "At list prices", "Requests", "Data as of"])
        #expect(spend.map(\.value) == ["$485.60", "$135.60", "$588.80", "1,450", "2026-11-11 12:02 UTC"])
        #expect(snapshot.details[1].rows.map(\.label) == ["us-west-2", "us-east-1"])
        #expect(snapshot.details[1].rows.map(\.value) == ["$412.80", "$72.80"])
        #expect(snapshot.details[1].rows.map(\.secondaryValue) == ["85%", "15%"])
        // us-east-1 denies the workspace list, so its workspace keeps the ID while us-west-2 shows the name.
        #expect(snapshot.details[2].rows.map(\.label) == [
            "Fixture Production", "wrkspc_fixtureB", "No workspace in us-east-1",
        ])
        #expect(snapshot.details[2].rows.map(\.value) == ["$412.80", "$60.00", "$12.80"])

        let history = try #require(snapshot.costUsage)
        #expect(history.historyDays == 30)
        #expect(history.historyLabel == "Last 30 days (UTC)")
        #expect(history.currencyCode == "USD")
        #expect(history.daily.map(\.date) == ["2026-10-20", "2026-11-05", "2026-11-11"])
        #expect(history.daily.map(\.requestCount) == [40, 1000, 450])
        #expect(history.daily.map(\.totalTokens) == [6211, 2300, 450])
        #expect(history.daily.map(\.inputTokens) == [6011, 2000, 400])
        let dailyCost = history.daily.compactMap(\.costUSD)
        #expect(dailyCost.count == 3)
        #expect(abs(dailyCost[0] - 15) < 0.000_001)
        #expect(abs(dailyCost[1] - 350) < 0.000_001)
        #expect(abs(dailyCost[2] - 135.6) < 0.000_001)
        #expect(history.last30DaysTokens == 8961)
        #expect(history.last30DaysRequests == 1490)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a single region omits the region breakdown`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await Self.fetch(engine: engine, regions: "us-west-2")
        #expect(snapshot.details.map(\.title) == ["Spend", "By workspace"])
        #expect(abs((snapshot.providerCost?.used ?? 0) - 412.8) < 0.000_001)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unavailable history keeps the month total without inventing daily spend`(
        engine: ProviderPluginEngineKind) async throws
    {
        var fixture = Fixture()
        fixture.dailyCode = 403
        let withoutDaily = try await Self.fetch(engine: engine, fixture: fixture)
        #expect(withoutDaily.costUsage == nil)
        #expect(withoutDaily.details[0].rows.map(\.label) == [
            "This month", "At list prices", "Requests", "Data as of",
        ])
        #expect(abs((withoutDaily.providerCost?.used ?? 0) - 485.6) < 0.000_001)

        fixture = Fixture()
        fixture.usageCode = 403
        let withoutTokens = try await Self.fetch(engine: engine, fixture: fixture)
        #expect(withoutTokens.costUsage == nil)
        #expect(withoutTokens.details[0].rows.map(\.label).contains("Today"))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `HTTP failures stay classified and name the region without echoing bodies`(
        engine: ProviderPluginEngineKind) async throws
    {
        for (code, kind) in [
            (401, ProviderFetchClassifiedError.Kind.authenticationExpired), (403, .permissionDenied),
            (429, .rateLimited), (503, .providerUnavailable), (400, .apiFailure),
        ] {
            var fixture = Fixture()
            fixture.totalCode = code
            fixture.totalBody["us-west-2"] = "private-response"
            await Self.expectFailure(engine: engine, fixture: fixture, kind: kind) { message in
                #expect(message.contains("us-west-2"))
                #expect(message.contains("HTTP \(code)"))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a denied IAM action is reported from the permission error`(engine: ProviderPluginEngineKind) async throws {
        var fixture = Fixture()
        fixture.totalCode = 403
        fixture.totalBody["us-west-2"] =
            #"{"type":"error","error":{"type":"permission_error","message":"not authorized to perform: "#
            + #"aws-external-anthropic:ListAccountCost"}}"#
        await Self.expectFailure(engine: engine, fixture: fixture, kind: .permissionDenied) { message in
            #expect(message.contains("aws-external-anthropic:ListAccountCost"))
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed cost responses never become zero spend`(engine: ProviderPluginEngineKind) async throws {
        for body in [
            "private-response",
            #"{"data":"private-response"}"#,
            Self.page([#"{"starting_at":"2026-11-01T00:00:00Z","group":{},"cost":{"amount":"private-response"}}"#]),
            Self.page([#"{"group":{},"cost":{"amount":"100.000000"}}"#]),
        ] {
            var fixture = Fixture()
            fixture.totalBody["us-west-2"] = body
            await Self.expectFailure(engine: engine, fixture: fixture, kind: .parseFailure)
        }
        var fixture = Fixture()
        fixture.totalBody["us-west-2"] = Self.page([], hasMore: true)
        await Self.expectFailure(engine: engine, fixture: fixture, kind: .apiFailure)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing or unsupported regions and credentials fail before network access`(
        engine: ProviderPluginEngineKind) async throws
    {
        let secrets = ["ANTHROPIC_AWS_ACCESS_KEY_ID": "AKIAFIXTURE", "ANTHROPIC_AWS_SECRET_ACCESS_KEY": "fixture-secret"]
        for (regions, credentials) in [
            ("", secrets), (" , ", secrets), ("us-west-2, fixture-region-1", secrets),
            ("us-west-2", ["ANTHROPIC_AWS_ACCESS_KEY_ID": "AKIAFIXTURE"]),
            ("us-west-2", ["ANTHROPIC_AWS_SECRET_ACCESS_KEY": "fixture-secret"]),
        ] {
            let runtime = try BundledPluginTestSupport.runtime(
                "claudeplatformaws", engine: engine, wallClock: Self.wallClock,
                transport: ProviderHTTPTransportHandler { request in
                    Issue.record("Unexpected request to \(request.url?.host ?? "unknown host")")
                    throw URLError(.badURL)
                })
            do {
                _ = try await runtime.fetchUsage(settings: ["ANTHROPIC_AWS_REGIONS": regions], secrets: credentials)
                Issue.record("Expected missing credential for regions '\(regions)'")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .missingCredential)
                #expect(!error.message.contains("fixture-secret"))
            }
        }
    }

    // MARK: - Fixtures

    private static func page(_ rows: [String], hasMore: Bool = false) -> String {
        #"{"data":["# + rows.joined(separator: ",") + #"],"has_more":"# + String(hasMore)
            + #","next_page":null,"data_refreshed_at":""# + self.refreshedAt + #""}"#
    }

    private static func costRow(
        _ start: String, amount: String, list: String? = nil, requests: Int, workspace: String? = nil) -> String
    {
        let workspaceValue = workspace.map { "\"\($0)\"" } ?? "null"
        return #"{"starting_at":""# + start + #"","ending_at":""# + start
            + #"","group":{"model":null,"workspace_id":"# + workspaceValue
            + #"},"cost":{"currency":"USD","amount":""# + amount + #"","list_amount":""# + (list ?? amount)
            + #"","requests":"# + String(requests) + "}}"
    }

    private static func usageRow(
        _ start: String, uncached: Int, cacheRead: Int = 0, written5m: Int = 0, written1h: Int = 0,
        output: Int) -> String
    {
        #"{"starting_at":""# + start + #"","group":{"workspace_id":null},"usage":{"uncached_input_tokens":"#
            + String(uncached) + #","cache_read_input_tokens":"# + String(cacheRead)
            + #","cache_creation":{"ephemeral_5m_input_tokens":"# + String(written5m)
            + #","ephemeral_1h_input_tokens":"# + String(written1h) + #"},"output_tokens":"# + String(output)
            + #","total_tokens":0,"requests":1}}"#
    }

    private static func expectFailure(
        engine: ProviderPluginEngineKind,
        fixture: Fixture,
        kind: ProviderFetchClassifiedError.Kind,
        message check: (String) -> Void = { _ in }) async
    {
        do {
            _ = try await self.fetch(engine: engine, fixture: fixture)
            Issue.record("Expected classified failure \(kind)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
            #expect(!error.message.contains("private-response"))
            #expect(!error.message.contains("fixture-secret"))
            check(error.message)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        regions: String = "us-west-2, US-EAST-1, us-west-2",
        fixture: Fixture = Fixture()) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "claudeplatformaws", engine: engine, wallClock: Self.wallClock,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                let host = url.host ?? ""
                let region = host.split(separator: ".").dropFirst().first.map(String.init) ?? ""
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
                #expect(host == "aws-external-anthropic.\(region).api.aws")
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                #expect(request.value(forHTTPHeaderField: "x-amz-date") == "20261111T153010Z")
                #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
                let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
                #expect(authorization.hasPrefix(
                    "AWS4-HMAC-SHA256 Credential=AKIAFIXTURE/20261111/\(region)/aws-external-anthropic/aws4_request, "
                        + "SignedHeaders=host;x-amz-date, Signature="))
                #expect(!authorization.contains("fixture-secret"))

                let west = region == "us-west-2"
                let (body, status): (String, Int)
                switch url.path {
                case "/v1/organizations/analytics/cost" where query.contains("group_by%5B%5D=workspace_id"):
                    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "analytics-usage-cost-2026-08-24")
                    if west {
                        #expect(query == "ending_at=2026-11-11T15%3A30%3A10Z&group_by%5B%5D=workspace_id"
                            + "&limit=1000&starting_at=2026-11-01T00%3A00%3A00Z")
                        #expect(authorization == Self.westTotalAuthorization)
                    }
                    (body, status) = (fixture.totalBody[region] ?? Self.page([]), west ? fixture.totalCode : 200)
                case "/v1/organizations/analytics/cost":
                    #expect(query == "ending_at=2026-11-11T00%3A00%3A00Z&limit=31&order=asc&order_by=time"
                        + "&starting_at=2026-10-13T00%3A00%3A00Z&time_bucket_width=1d")
                    let rows = west
                        ? [
                            Self.costRow("2026-10-20T00:00:00Z", amount: "1500.000000", requests: 40),
                            Self.costRow("2026-11-05T00:00:00Z", amount: "30000.000000", requests: 900),
                        ]
                        : [Self.costRow("2026-11-05T00:00:00Z", amount: "5000.000000", requests: 100)]
                    (body, status) = (Self.page(rows), fixture.dailyCode)
                case "/v1/organizations/analytics/usage" where query.contains("time_bucket_width=1d"):
                    let rows = west
                        ? [
                            Self.usageRow(
                                "2026-10-20T00:00:00Z", uncached: 1000, cacheRead: 5000, written5m: 10, written1h: 1,
                                output: 200),
                            Self.usageRow("2026-11-05T00:00:00Z", uncached: 2000, output: 300),
                        ]
                        : []
                    (body, status) = (Self.page(rows), fixture.usageCode)
                case "/v1/organizations/analytics/usage":
                    #expect(query == "ending_at=2026-11-11T15%3A30%3A10Z&starting_at=2026-11-11T00%3A00%3A00Z")
                    let rows = west ? [Self.usageRow("2026-11-11T00:00:00Z", uncached: 400, output: 50)] : []
                    (body, status) = (Self.page(rows), fixture.usageCode)
                case "/v1/organizations/workspaces":
                    #expect(query == "include_archived=true&include_default=true&limit=1000")
                    #expect(request.value(forHTTPHeaderField: "anthropic-beta") == nil)
                    (body, status) = (
                        #"{"data":[{"id":"wrkspc_fixtureA","type":"workspace","name":" Fixture Production "}],"#
                            + #""has_more":false}"#,
                        fixture.workspaceCode[region] ?? 200)
                default:
                    Issue.record("Unexpected request path \(url.path)")
                    (body, status) = ("{}", 404)
                }
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json", "Retry-After": "0"]))
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(
            settings: ["ANTHROPIC_AWS_REGIONS": regions],
            secrets: [
                "ANTHROPIC_AWS_ACCESS_KEY_ID": "AKIAFIXTURE",
                "ANTHROPIC_AWS_SECRET_ACCESS_KEY": "fixture-secret",
            ])
    }
}
