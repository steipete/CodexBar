import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct LiteLLMModelUsageTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `model activity combines flat and nested metrics without changing budgets`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine: engine)
        let section = try #require(usage.details.first { $0.title == "Model activity · 30d UTC" })
        #expect(section.rows.map(\.label) == ["fixture-alpha", "fixture-beta"])
        #expect(section.rows[0].value == "60 tokens · 3 requests")
        #expect(section.rows[0].secondaryValue == "Input 40 · Output 20")
        #expect(usage.providerCost?.used == 12)
        #expect(usage.primary?.usedPercent == 12)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `model activity can split one day across pages`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(engine: engine, scenario: "split")
        let section = try #require(usage.details.first)
        #expect(section.rows.first?.value == "60 tokens · 3 requests")
        #expect(usage.providerCost?.used == 12)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `activity is opt in and unavailable history preserves budgets`(engine: ProviderPluginEngineKind) async throws {
        for scenario in [
            "off",
            "team",
            "forbidden",
            "network",
            "malformed",
            "overflow",
            "pages",
            "duplicate",
            "range",
            "label",
            "empty",
        ] {
            let usage = try await Self.fetch(engine: engine, scenario: scenario)
            #expect(usage.providerCost?.used == 12)
            #expect(usage.details.isEmpty)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `activity limits displayed models while retaining complete counters`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await Self.fetch(engine: engine, scenario: "models")
        let section = try #require(usage.details.first)
        #expect(section.rows.count == 20)
        #expect(section.rows.first?.label == "fixture-24")
        #expect(section.rows.last?.label == "fixture-5")
    }

    static func fetch(
        engine: ProviderPluginEngineKind,
        scenario: String = "normal") async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let url = try #require(request.url)
            let body: String
            var statusCode = 200
            switch url.path {
            case "/key/info":
                body = scenario == "team"
                    ? #"{"info":{"team_id":"fixture-team"}}"#
                    : #"{"info":{"user_id":"fixture+user"}}"#
            case "/user/info":
                body = #"{"user_info":{"user_id":"fixture+user","spend":12,"max_budget":100}}"#
            case "/team/info":
                body = #"{"team_info":{"team_id":"fixture-team","spend":12,"max_budget":100}}"#
            case "/user/daily/activity":
                #expect(scenario != "off" && scenario != "team")
                let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                #expect(query["user_id"] == "fixture+user")
                #expect(query["start_date"] == "2026-08-26")
                #expect(query["end_date"] == "2026-09-24")
                #expect(query["page_size"] == "1000")
                #expect(query["api_key"] == nil)
                let page = try #require(Int(query["page"] ?? ""))
                #expect((1...3).contains(page))
                switch scenario {
                case "forbidden":
                    statusCode = 403
                    body = "{}"
                case "network": throw URLError(.timedOut)
                case "malformed": body = #"{"results":[{"date":"2026-09-24"}]}"#
                case "overflow":
                    body = Self.page(date: "2026-09-24", models: """
                    {"fixture-alpha":{"prompt_tokens":0,"completion_tokens":0,"total_tokens":1e100,"api_requests":0}}
                    """)
                case "range": body = Self.page(date: "2026-08-25", models: "{}")
                case "label": body = Self.page(date: "2026-09-24", models: #"{"":{}}"#)
                case "empty": body = #"{"results":[],"metadata":{"has_more":false}}"#
                case "models":
                    let models = (0..<25).map {
                        "\"fixture-\($0)\":{\"prompt_tokens\":\($0),\"completion_tokens\":0," +
                            "\"total_tokens\":\($0),\"api_requests\":1}"
                    }.joined(separator: ",")
                    body = Self.page(date: "2026-09-24", models: "{\(models)}")
                default:
                    let date = ["duplicate", "split"].contains(scenario) ? "2026-09-24" : "2026-09-\(25 - page)"
                    let counters = #"{"prompt_tokens":20,"completion_tokens":10,"total_tokens":30,"api_requests":1}"#
                    let models = page == 1
                        ? #"{"fixture-alpha":\#(counters),"fixture-beta":\#(counters)}"#
                        : """
                        {"fixture-alpha":{"metrics":{
                          "prompt_tokens":20,"completion_tokens":10,"total_tokens":30,"api_requests":2}}}
                        """
                    body = Self.page(
                        date: date,
                        models: models,
                        pages: scenario == "pages" ? 4 : 2,
                        page: scenario == "duplicate" ? 1 : page)
                }
            default:
                Issue.record("Unexpected endpoint \(url.path)")
                body = "{}"
            }
            return (Data(body.utf8), HTTPURLResponse(
                url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!)
        }
        return try await BundledPluginTestSupport.runtime("litellm", engine: engine, transport: transport)
            .fetchUsage(
                settings: [
                    "LITELLM_BASE_URL": "https://proxy.example.com",
                    "LITELLM_MODEL_USAGE_ENABLED": scenario == "off" ? "false" : "true",
                ],
                secrets: ["LITELLM_API_KEY": "fixture-key"],
                now: ISO8601DateParser.parse("2026-09-24T12:00:00Z")!)
    }

    private static func page(date: String, models: String, pages: Int = 1, page: Int = 1) -> String {
        """
        {"results":[{"date":"\(date)","breakdown":{"models":\(models)}}],
         "metadata":{"total_pages":\(pages),"page":\(page)}}
        """
    }
}
