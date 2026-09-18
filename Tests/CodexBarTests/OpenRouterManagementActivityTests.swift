import Foundation
import Testing
@testable import CodexBarCore

struct OpenRouterManagementActivityTests {
    @Test(arguments: BundledPluginTestSupport.engines, [
        ("https://openrouter.ai/api/v1", true),
        ("https://OPENROUTER.AI:443/api/v1///", true),
        ("https://openrouter.ai:444/api/v1", false),
        ("https://proxy.example/api/v1", false),
        ("https://openrouter.ai/API/v1", false),
    ])
    func `only official API metadata promotes the primary management credential`(
        engine: ProviderPluginEngineKind, base: (String, Bool)) async throws
    {
        let fixture = try await Self.fetch(engine: engine, base: base.0, managementFlag: "true")
        let activity = fixture.requests.filter { $0.url?.path == "/api/v1/activity" }
        #expect(activity.count == (base.1 ? 2 : 0))
        #expect(activity.allSatisfy { $0.url?.host == "openrouter.ai" })
        #expect(activity.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer primary-fixture" })
        #expect((fixture.snapshot.costUsage != nil) == base.1)
        #expect(fixture.snapshot.primary?.usedPercent == 25)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `separate management credential wins and activity stays compact`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixture = try await Self.fetch(engine: engine, managementFlag: "true", separateKey: true)
        for request in fixture.requests {
            let isActivity = request.url?.path == "/api/v1/activity"
            #expect(request.value(forHTTPHeaderField: "Authorization")
                == (isActivity ? "Bearer separate-fixture" : "Bearer primary-fixture"))
        }
        let section = try #require(fixture.snapshot.details
            .first { $0.title == "Activity (last 30 completed UTC days)" })
        #expect(section.rows.map(\.label) == ["Tokens", "Requests", "Models"])
        #expect(section.rows.map(\.value) == ["150", "2", "1"])
        #expect(fixture.snapshot.costUsage?.last30DaysTokens == 150)
        #expect(fixture.snapshot.costUsage?.daily.first?.reasoningTokens == 80)
        #expect(fixture.snapshot.costUsage?.daily.first?.modelBreakdowns?.count == 1)
        #expect(fixture.snapshot.providerCost == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["false", #""true""#, "null", "42"])
    func `unrecognized credential metadata preserves quota without promoting activity`(
        engine: ProviderPluginEngineKind, flag: String) async throws
    {
        let fixture = try await Self.fetch(engine: engine, managementFlag: flag)
        #expect(fixture.snapshot.primary?.usedPercent == 25)
        #expect(fixture.snapshot.costUsage == nil)
        #expect(fixture.requests.count == 2)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `failed promoted activity preserves quota and balance`(engine: ProviderPluginEngineKind) async throws {
        let fixture = try await Self.fetch(engine: engine, managementFlag: "true", activityStatus: 403)
        #expect(fixture.snapshot.primary?.usedPercent == 25)
        #expect(fixture.snapshot.detailRow(label: "Remaining")?.value == "$60.00")
        #expect(fixture.snapshot.costUsage == nil)
        #expect(!fixture.snapshot.details.contains { $0.title?.hasPrefix("Activity") == true })
        #expect(fixture.snapshot.detailRow(label: "Last 30 days")?.secondaryValue == "Management API key required")
    }

    private static func fetch(
        engine: ProviderPluginEngineKind,
        base: String = "https://openrouter.ai/api/v1",
        managementFlag: String,
        separateKey: Bool = false,
        activityStatus: Int = 200) async throws -> (snapshot: UsageSnapshot, requests: [URLRequest])
    {
        let recorder = RequestRecorder()
        let runtime = try BundledPluginTestSupport.runtime(
            "openrouter",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                await recorder.append(request)
                let path = request.url?.path ?? ""
                let isActivity = path == "/api/v1/activity"
                let body = if isActivity {
                    #"""
                    {"data":[{"date":"2026-08-17","model":"example-model","prompt_tokens":100,
                    "completion_tokens":50,"reasoning_tokens":80,"requests":2,"usage":1}]}
                    """#
                } else if path.hasSuffix("/key") {
                    "{\"data\":{\"limit\":20,\"usage\":5,\"is_management_key\":\(managementFlag)}}"
                } else {
                    #"{"data":{"total_credits":100,"total_usage":40}}"#
                }
                let url = try #require(request.url)
                return try (Data(body.utf8), #require(HTTPURLResponse(
                    url: url,
                    statusCode: isActivity ? activityStatus : 200,
                    httpVersion: nil,
                    headerFields: nil)))
            })
        var secrets = ["OPENROUTER_API_KEY": "primary-fixture"]
        if separateKey { secrets["OPENROUTER_MANAGEMENT_API_KEY"] = "separate-fixture" }
        let snapshot = try await runtime.fetchUsage(
            settings: ["OPENROUTER_API_URL": base],
            secrets: secrets,
            now: Date(timeIntervalSince1970: 1_787_079_600))
        return await (snapshot, recorder.requests)
    }

    private actor RequestRecorder {
        var requests: [URLRequest] = []
        func append(_ request: URLRequest) { self.requests.append(request) }
    }
}
