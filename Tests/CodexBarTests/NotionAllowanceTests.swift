import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NotionAllowanceTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `Notion retains actual credit allowance through the plugin and menu card`(
        engine: ProviderPluginEngineKind) async throws
    {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Providers/Notion")
        let spaces = try Data(contentsOf: directory.appendingPathComponent("get-spaces.json"))
        let fixture = try Data(contentsOf: directory.appendingPathComponent("get-credit-rate-limit-status.json"))
        var payload = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var allowance = try #require(payload["billingPeriodWindow"] as? [String: Any])
        allowance["limit"] = 250
        payload["billingPeriodWindow"] = allowance
        let usage = try JSONSerialization.data(withJSONObject: payload)
        let now = Date(timeIntervalSince1970: 1_787_136_000)
        let runtime = try BundledPluginTestSupport.runtime(
            "notion",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let body: Data
                switch request.url?.path {
                case "/api/v3/getSpaces": body = spaces
                case "/api/v3/getCreditRateLimitStatus": body = usage
                default: throw URLError(.badURL)
                }
                let response = try #require(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil))
                return (body, response)
            })
        let snapshot = try await runtime.fetchUsage(now: now, cookieSource: .manual, cookieSessionResolver: { _, _ in
            .init(
                header: "token_v2=fixture",
                source: "Fixture",
                origin: "https://app.notion.com",
                id: "fixture-session")
        })
        #expect(snapshot.primary?.quotaLimit == 100)
        #expect(snapshot.secondary?.quotaLimit == 250)
        #expect(snapshot.secondary?.quotaUnit == "credits")
        let model = MonthlyPacingTargetTests.model(window: nil, snapshot: snapshot, now: now)
        let monthly = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(monthly.dailyTargetText == "≈ 21.09 credits / day to last until reset")
        #expect(model.metrics.first { $0.id == "primary" }?.dailyTargetText == nil)
    }
}
