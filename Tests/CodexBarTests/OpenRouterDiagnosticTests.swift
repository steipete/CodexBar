import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct OpenRouterDiagnosticTests {
    @Test(arguments: BundledPluginTestSupport.engines, OpenRouterDiagnosticFixture.Endpoint.allCases)
    func `invalid JSON is a response failure for each optional endpoint`(
        engine: ProviderPluginEngineKind,
        endpoint: OpenRouterDiagnosticFixture.Endpoint) async throws
    {
        let snapshot = try await OpenRouterDiagnosticFixture.fetch(
            engine: engine, endpoint: endpoint, result: .response(200, #"{"data":["#))
        Self.expectDegradation(snapshot, endpoint: endpoint, reason: "Response was invalid")
    }

    @Test(arguments: BundledPluginTestSupport.engines, OpenRouterDiagnosticFixture.Endpoint.allCases)
    func `numeric parser failures preserve other optional sources`(
        engine: ProviderPluginEngineKind,
        endpoint: OpenRouterDiagnosticFixture.Endpoint) async throws
    {
        let body = switch endpoint {
        case .credits: #"{"data":{"total_credits":"many","total_usage":40}}"#
        case .key: #"{"data":{"limit":"twenty"}}"#
        case .history, .dated: OpenRouterDiagnosticFixture.activity(prompt: #""not-a-number""#)
        }
        let snapshot = try await OpenRouterDiagnosticFixture.fetch(
            engine: engine, endpoint: endpoint, result: .response(200, body))
        Self.expectDegradation(snapshot, endpoint: endpoint, reason: "Response was invalid")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `validation wording does not determine activity diagnostics`(engine: ProviderPluginEngineKind) async throws {
        let bodies = [
            OpenRouterDiagnosticFixture.activity(model: String(repeating: "x", count: 65)),
            OpenRouterDiagnosticFixture.activity(prompt: "5000000000000000", completion: "4007199254740992"),
            #"""
            {"data":[
              {"date":"2026-08-17","model":"example/a","prompt_tokens":1,
               "completion_tokens":1,"requests":1,"usage":1e308},
              {"date":"2026-08-17","model":"example/b","prompt_tokens":1,
               "completion_tokens":1,"requests":1,"usage":1e308}
            ]}
            """#,
        ]
        for body in bodies {
            let snapshot = try await OpenRouterDiagnosticFixture.fetch(
                engine: engine, endpoint: .history, result: .response(200, body))
            Self.expectDegradation(snapshot, endpoint: .history, reason: "Response was invalid")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `accepted model and row token boundaries remain usable`(engine: ProviderPluginEngineKind) async throws {
        let snapshot = try await OpenRouterDiagnosticFixture.fetch(
            engine: engine,
            endpoint: .history,
            result: .response(200, OpenRouterDiagnosticFixture.activity(
                model: String(repeating: "x", count: 64),
                prompt: "5000000000000000",
                completion: "4007199254740991")),
            otherActivityBody: #"{"data":[]}"#)
        #expect(snapshot.costUsage?.last30DaysTokens == 9_007_199_254_740_991)
        #expect(snapshot.costUsage?.last30DaysCostUSD == 1)
        #expect(snapshot.costUsage?.last30DaysRequests == 1)
        #expect(snapshot.detailRow(label: "Last 30 days") == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines, OpenRouterDiagnosticFixture.Endpoint.allCases)
    func `transport errors remain request failures regardless of parsing words`(
        engine: ProviderPluginEngineKind,
        endpoint: OpenRouterDiagnosticFixture.Endpoint) async throws
    {
        for (result, reason) in [
            (OpenRouterDiagnosticFixture.Result.timeout, "Request timed out"),
            (.offline, "Request failed"),
            (.misleadingTransportError, "Request failed"),
        ] {
            let snapshot = try await OpenRouterDiagnosticFixture.fetch(
                engine: engine,
                endpoint: endpoint,
                result: result)
            Self.expectDegradation(snapshot, endpoint: endpoint, reason: reason)
            let cli = CLIRenderer.renderText(
                provider: .openrouter,
                snapshot: snapshot,
                credits: nil,
                context: RenderContext(header: "OpenRouter", status: nil, useColor: false, resetStyle: .countdown),
                now: OpenRouterReasoningTestSupport.now)
            #expect(cli.contains(reason))
            let json = try #require(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
            for forbidden in [
                "private transport detail",
                "fixture-key",
                "fixture-management-key",
                "__CODEXBAR_FAILURE",
            ] {
                #expect(!cli.contains(forbidden))
                #expect(!json.contains(forbidden))
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, OpenRouterDiagnosticFixture.Endpoint.allCases)
    func `HTTP failures retain their status even with malformed response bodies`(
        engine: ProviderPluginEngineKind,
        endpoint: OpenRouterDiagnosticFixture.Endpoint) async throws
    {
        for status in [403, 429, 500] {
            let snapshot = try await OpenRouterDiagnosticFixture.fetch(
                engine: engine, endpoint: endpoint, result: .response(status, "not-json"))
            let reason = status == 403 && endpoint.isActivity
                ? "Management API key required" : "Request returned HTTP \(status)"
            Self.expectDegradation(snapshot, endpoint: endpoint, reason: reason)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `missing key data retains the existing unavailable diagnostic`(engine: ProviderPluginEngineKind) async throws {
        for body in ["{}", #"{"data":null}"#, #"{"data":[]}"#] {
            let snapshot = try await OpenRouterDiagnosticFixture.fetch(
                engine: engine, endpoint: .key, result: .response(200, body))
            Self.expectDegradation(snapshot, endpoint: .key, reason: "Response was unavailable")
        }
    }

    private static func expectDegradation(
        _ snapshot: UsageSnapshot,
        endpoint: OpenRouterDiagnosticFixture.Endpoint,
        reason: String)
    {
        let label = switch endpoint {
        case .credits: "Balance"
        case .key: "API key limit"
        case .history, .dated: "Last 30 days"
        }
        #expect(snapshot.detailRow(label: label)?.value == "Unavailable right now")
        #expect(snapshot.detailRow(label: label)?.secondaryValue == reason)
        if endpoint != .credits { #expect(snapshot.detailRow(label: "Remaining")?.value == "$60.00") }
        if endpoint != .key {
            #expect(snapshot.primary?.usedPercent == 25)
            #expect(snapshot.detailRow(label: "API key used")?.value == "$5.00")
            #expect(snapshot.detailRow(label: "Today")?.value == "$1.00")
        }
        if endpoint.isActivity {
            #expect(snapshot.costUsage == nil)
        } else {
            #expect(snapshot.costUsage?.last30DaysTokens == 2)
            #expect(snapshot.costUsage?.last30DaysCostUSD == 1)
        }
    }
}

enum OpenRouterDiagnosticFixture {
    enum Endpoint: CaseIterable, Sendable {
        case credits, key, history, dated

        var isActivity: Bool {
            self == .history || self == .dated
        }
    }

    enum Result: Sendable {
        case response(Int, String)
        case timeout, offline, misleadingTransportError
    }

    static func activity(
        model: String = "example/model", prompt: String = "1", completion: String = "1") -> String
    {
        """
        {"data":[{"date":"2026-08-17","model":"\(model)","prompt_tokens":\(prompt),
          "completion_tokens":\(completion),"requests":1,"usage":1}]}
        """
    }

    static func fetch(
        engine: ProviderPluginEngineKind,
        endpoint: Endpoint,
        result: Result,
        otherActivityBody: String = Self.activity()) async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url, url.scheme == "https", url.host == "openrouter.ai",
                  request.httpMethod == "GET"
            else { throw URLError(.unsupportedURL) }
            let current: Endpoint
            let defaultBody: String
            switch url.path {
            case "/api/v1/credits":
                current = .credits
                defaultBody = #"{"data":{"total_credits":100,"total_usage":40}}"#
            case "/api/v1/key":
                current = .key
                defaultBody = #"{"data":{"limit":20,"usage":5,"usage_daily":1}}"#
            case "/api/v1/activity":
                current = url.query == nil ? .history : .dated
                defaultBody = otherActivityBody
            default:
                throw URLError(.unsupportedURL)
            }
            let key = current.isActivity ? "fixture-management-key" : "fixture-key"
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)" else {
                throw URLError(.userAuthenticationRequired)
            }
            let body: String
            let status: Int
            switch current == endpoint ? result : .response(200, defaultBody) {
            case let .response(code, payload):
                status = code
                body = payload
            case .timeout: throw URLError(.timedOut)
            case .offline: throw URLError(.notConnectedToInternet)
            case .misleadingTransportError:
                throw NSError(domain: "SyntheticTransport", code: 17, userInfo: [
                    NSLocalizedDescriptionKey:
                        "invalid parse: private transport detail fixture-key fixture-management-key",
                ])
            }
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            return (Data(body.utf8), response)
        }
        return try await BundledPluginTestSupport.runtime("openrouter", engine: engine, transport: transport)
            .fetchUsage(secrets: [
                OpenRouterSettingsReader.envKey: "fixture-key",
                OpenRouterSettingsReader.managementAPIKeyEnvironmentKey: "fixture-management-key",
            ], now: OpenRouterReasoningTestSupport.now)
    }
}
