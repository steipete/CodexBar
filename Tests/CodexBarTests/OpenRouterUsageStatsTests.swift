#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBarCore

struct OpenRouterPluginGoldenTests {
    @Test
    func `production strategy resolves configured management key`() throws {
        let config = ProviderConfig(
            id: .openrouter,
            pluginSecrets: [
                OpenRouterSettingsReader.managementAPIKeyEnvironmentKey: "configured-management-key",
            ])
        let contribution = try #require(OpenRouterProviderDescriptor.descriptor.settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(config: config, account: nil)))
        let settings = ProviderSettingsSnapshot(contributions: [contribution])
        let values = try #require(OpenRouterProviderDescriptor.scriptValues(
            environment: [
                OpenRouterSettingsReader.envKey: "standard-key",
                OpenRouterSettingsReader.apiURLEnvironmentKey: "https://proxy.example/api/v1",
            ],
            settings: settings))

        #expect(values.secrets[OpenRouterSettingsReader.envKey] == "standard-key")
        #expect(values.secrets[OpenRouterSettingsReader.managementAPIKeyEnvironmentKey] == "configured-management-key")
        #expect(values.settings[OpenRouterSettingsReader.apiURLEnvironmentKey] == "https://proxy.example/api/v1")
    }

    @Test
    func `key quota fixture matches the production golden`() async throws {
        let snapshot = try await Self.fetch(keyBody: #"{"data":{"limit":20,"usage":5}}"#)

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.primary?.resetDescription == nil)
        #expect(snapshot.detailRow(label: "API key budget")?.value == "$20.00")
        #expect(snapshot.detailRow(label: "API key remaining")?.value == "$15.00")
    }

    @Test
    func `missing key limit omits primary and marks no limit`() async throws {
        let snapshot = try await Self.fetch(keyBody: #"{"data":{}}"#)

        #expect(snapshot.primary == nil)
        #expect(snapshot.detailRow(label: "API key budget")?.value == "No limit configured")
    }

    @Test
    func `unavailable key enrichment omits primary and marks unavailable`() async throws {
        let snapshot = try await Self.fetch(keyBody: "{}", keyStatus: 500)

        #expect(snapshot.primary == nil)
        #expect(snapshot.detailRow(label: "API key budget")?.value == "Unavailable right now")
        #expect(snapshot.detailRow(label: "API key budget")?.secondaryValue == "Request returned HTTP 500")
    }

    @Test
    func `credits error is classified without response body details`() async throws {
        let body = #"""
        {"error":"bad token sk-or-v1-abc123","token":"secret-token","authorization":"Bearer sk-or-v1-xyz789"}
        """#

        do {
            _ = try await Self.fetch(creditsBody: body, creditsStatus: 401)
            Issue.record("Expected API failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .apiFailure)
            #expect(error.message == "OpenRouter API error: HTTP 401")
            #expect(!error.localizedDescription.contains("secret-token"))
            #expect(!error.localizedDescription.contains("sk-or-v1-abc123"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `requests preserve credits headers and one second enrichment deadline`() async throws {
        let requests = OpenRouterRequestRecorder()
        let transport = Self.transport(requests: requests, keyBody: #"""
        {"data":{
          "limit":20,
          "usage":0.5,
          "usage_daily":0.12,
          "usage_weekly":0.74,
          "usage_monthly":4.56,
          "rate_limit":{"requests":120,"interval":"10s"}
        }}
        """#)
        let runtime = try ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport)

        let usage = try await runtime.fetchUsage(
            settings: [
                OpenRouterSettingsReader.apiURLEnvironmentKey: "https://openrouter.test/api/v1",
                OpenRouterSettingsReader.httpRefererEnvironmentKey: "https://codexbar.example",
                OpenRouterSettingsReader.clientTitleEnvironmentKey: "CodexBar QA",
            ],
            secrets: [OpenRouterSettingsReader.envKey: "sk-or-v1-test"])

        let recorded = await requests.requests
        #expect(recorded.count == 2)
        #expect(recorded[0].timeoutInterval == 15)
        #expect(recorded[0].value(forHTTPHeaderField: "HTTP-Referer") == "https://codexbar.example")
        #expect(recorded[0].value(forHTTPHeaderField: "X-Title") == "CodexBar QA")
        #expect(recorded[1].timeoutInterval == 1)
        #expect(recorded[1].value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(recorded[1].value(forHTTPHeaderField: "X-Title") == nil)
        #expect(usage.detailRow(label: "Last 30 days")?.value == "Unavailable right now")
        #expect(usage.detailRow(label: "Last 30 days")?.secondaryValue == "Management API key not configured")
        #expect(usage.detailRow(label: "Today")?.value == "$0.12")
        #expect(usage.detailRow(label: "This week")?.value == "$0.74")
        #expect(usage.detailRow(label: "This month")?.value == "$4.56")
        #expect(usage.detailRow(label: "Rate limit")?.value == "120 requests / 10s")
    }

    @Test
    func `management key activity stays on official origin when API base is overridden`() async throws {
        let requests = OpenRouterRequestRecorder()
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "openrouter",
            transport: ProviderHTTPTransportHandler { request in
                await requests.append(request)
                let path = request.url?.path ?? ""
                if path.hasSuffix("/activity") {
                    return try Self.response(request, body: #"{"data":[]}"#)
                }
                if path.hasSuffix("/key") {
                    return try Self.response(request, body: #"{"data":{"limit":20,"usage":5}}"#)
                }
                return try Self.response(request, body: Self.defaultCreditsBody)
            })

        _ = try await runtime.fetchUsage(
            settings: [
                OpenRouterSettingsReader.apiURLEnvironmentKey: "https://proxy.example/api/v1",
            ],
            secrets: [
                OpenRouterSettingsReader.envKey: "standard-key",
                OpenRouterSettingsReader.managementAPIKeyEnvironmentKey: "management-key",
            ])
        let recorded = await requests.requests
        let activity = recorded.filter { $0.url?.path.hasSuffix("/activity") == true }
        let ordinary = recorded.filter { $0.url?.path.hasSuffix("/activity") != true }

        #expect(activity.count == 2)
        #expect(activity.allSatisfy { $0.url?.host == "openrouter.ai" })
        #expect(activity.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer management-key" })
        #expect(ordinary.count == 2)
        #expect(ordinary.allSatisfy { $0.url?.host == "proxy.example" })
        #expect(ordinary.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer standard-key" })
    }

    @Test
    func `activity requests the latest completed UTC day`() async throws {
        let requests = OpenRouterRequestRecorder()
        let activityBody = #"""
        {"data":[
          {
            "date":"2026-08-17",
            "model":"openai/gpt-5.6",
            "prompt_tokens":10,
            "completion_tokens":5,
            "reasoning_tokens":2,
            "requests":1,
            "usage":1
          },
          {
            "date":"2026-07-19",
            "model":"x-ai/grok-4",
            "prompt_tokens":4,
            "completion_tokens":1,
            "reasoning_tokens":0,
            "requests":1,
            "usage":1
          }
        ]}
        """#
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "openrouter",
            transport: ProviderHTTPTransportHandler { request in
                await requests.append(request)
                let path = request.url?.path ?? ""
                if path.hasSuffix("/activity") {
                    let date = request.url
                        .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                        .queryItems?
                        .first { $0.name == "date" }?
                        .value
                    if date == "2026-08-18" {
                        return try Self.response(
                            request,
                            body: #"{"error":{"message":"Date must be within the last 30 (completed) UTC days"}}"#,
                            statusCode: 400)
                    }
                    return try Self.response(request, body: activityBody)
                }
                if path.hasSuffix("/key") {
                    return try Self.response(request, body: #"{"data":{"limit":20,"usage":5}}"#)
                }
                return try Self.response(request, body: Self.defaultCreditsBody)
            })
        let now = Date(timeIntervalSince1970: 1_787_079_600) // 2026-08-18T12:00:00Z; stable injected clock.

        let usage = try await runtime.fetchUsage(
            secrets: [
                OpenRouterSettingsReader.envKey: "fixture-key",
                OpenRouterSettingsReader.managementAPIKeyEnvironmentKey: "fixture-management-key",
            ],
            now: now)
        let recorded = await requests.requests
        let datedRequest = try #require(recorded.first { $0.url?.query != nil })
        let date = datedRequest.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first { $0.name == "date" }?
            .value

        #expect(date == "2026-08-17")
        #expect(usage.costUsage?.last30DaysCostUSD == 2)
    }

    @Test
    func `activity accepts space separated timestamp dates`() async throws {
        let activityBody = #"""
        {"data":[{
          "date":"2026-08-17 00:00:00",
          "model_permaslug":"openai/gpt-5.6",
          "prompt_tokens":10,
          "completion_tokens":5,
          "reasoning_tokens":2,
          "requests":1,
          "usage":1
        }]}
        """#

        let usage = try await Self.fetch(activityBody: activityBody)
        let cost = try #require(usage.costUsage)

        #expect(cost.last30DaysCostUSD == 1)
        #expect(cost.daily.map(\.date) == ["2026-08-17"])
    }

    @Test
    func `activity deduplicates bare and timestamp dates`() async throws {
        let activityBody = #"""
        {"data":[
          {
            "date":"2026-08-17", "model":"openai/gpt-5.6", "endpoint_id":"same",
            "prompt_tokens":10, "completion_tokens":5, "reasoning_tokens":2,
            "requests":1, "usage":1
          },
          {
            "date":"2026-08-17 00:00:00", "model":"openai/gpt-5.6", "endpoint_id":"same",
            "prompt_tokens":10, "completion_tokens":5, "reasoning_tokens":2,
            "requests":1, "usage":1
          }
        ]}
        """#

        let usage = try await Self.fetch(activityBody: activityBody)
        let cost = try #require(usage.costUsage)

        #expect(cost.last30DaysCostUSD == 1)
        #expect(cost.daily.map(\.date) == ["2026-08-17"])
        #expect(cost.daily.first?.requestCount == 1)
    }

    @Test
    func `server remaining drives monthly quota golden`() async throws {
        let usage = try await Self.fetch(keyBody: #"""
        {"data":{
          "limit":500,
          "limit_remaining":454.542594979,
          "limit_reset":"monthly",
          "usage":433.286754736,
          "usage_daily":3.404645509,
          "usage_weekly":3.404645509,
          "usage_monthly":45.457405021
        }}
        """#)

        #expect(abs((usage.primary?.usedPercent ?? -1) - 9.0914810042) < 1e-9)
        #expect(usage.detailRow(label: "API key remaining")?.value == "$454.54")
        #expect(usage.detailRow(label: "Reset window")?.value == "monthly")
    }

    @Test
    func `missing remaining falls back to reset window usage`() async throws {
        let usage = try await Self.fetch(keyBody: #"""
        {"data":{
          "limit":500,
          "limit_reset":"monthly",
          "usage":433.286754736,
          "usage_monthly":45.457405021
        }}
        """#)

        #expect(abs((usage.primary?.usedPercent ?? -1) - 9.0914810042) < 1e-9)
        #expect(usage.detailRow(label: "API key remaining")?.value == "$454.54")
    }

    @Test
    func `reset window works without cumulative usage`() async throws {
        let usage = try await Self.fetch(keyBody: #"""
        {"data":{
          "limit":500,
          "limit_reset":"monthly",
          "usage_monthly":45.457405021
        }}
        """#)

        #expect(abs((usage.primary?.usedPercent ?? -1) - 9.0914810042) < 1e-9)
        #expect(usage.detailRow(label: "API key remaining")?.value == "$454.54")
    }

    @Test
    func `negative server remaining is exhausted quota`() async throws {
        let usage = try await Self.fetch(keyBody: #"""
        {"data":{
          "limit":500,
          "limit_remaining":-5,
          "limit_reset":"monthly",
          "usage":433.286754736,
          "usage_monthly":45.457405021
        }}
        """#)

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.detailRow(label: "API key remaining")?.value == "$0.00")
    }

    @Test
    func `malformed key enrichment degrades to unavailable`() async throws {
        let usage = try await Self.fetch(keyBody: #"{"data":{"limit":"twenty"}}"#)

        #expect(usage.primary == nil)
        #expect(usage.detailRow(label: "API key budget")?.value == "Unavailable right now")
        #expect(usage.detailRow(label: "API key budget")?.secondaryValue == "Response was invalid")
    }

    @Test
    func `credits parse failure is classified`() async throws {
        do {
            _ = try await Self.fetch(creditsBody: #"{"data":{"total_credits":"many","total_usage":40}}"#)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(error.message.contains("total_credits"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `invalid credits JSON is classified as parse failure`() async throws {
        do {
            _ = try await Self.fetch(creditsBody: "not-json")
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(error.message == "Failed to parse OpenRouter response: response was not valid JSON")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `key enrichment deadline does not block credits result`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            if request.url?.path.hasSuffix("/key") == true {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                        continuation.resume()
                    }
                }
            }
            return try Self.response(
                request,
                body: request.url?.path.hasSuffix("/key") == true
                    ? #"{"data":{"limit":20,"usage":5}}"#
                    : Self.defaultCreditsBody)
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport)
        let startedAt = ContinuousClock.now

        let usage = try await runtime.fetchUsage(secrets: [OpenRouterSettingsReader.envKey: "fixture-key"])

        #expect(ContinuousClock.now - startedAt < .seconds(1.4))
        #expect(usage.primary == nil)
        #expect(usage.detailRow(label: "API key budget")?.value == "Unavailable right now")
        #expect(usage.detailRow(label: "API key budget")?.secondaryValue == "Request timed out")
        try await Task.sleep(for: .milliseconds(600))
    }

    @Test
    func `activity rows aggregate by UTC day and model into exact thirty day spend`() async throws {
        let activityBody = #"""
        {"data":[
          {
            "date":"2026-08-17",
            "model":"openai/gpt-5.6",
            "endpoint_id":"endpoint-a",
            "provider_name":"OpenAI",
            "prompt_tokens":100,
            "completion_tokens":50,
            "reasoning_tokens":10,
            "requests":2,
            "usage":12.345
          },
          {
            "date":"2026-08-17",
            "model":"x-ai/grok-4",
            "endpoint_id":"endpoint-b",
            "provider_name":"OpenAI",
            "prompt_tokens":2,
            "completion_tokens":3,
            "reasoning_tokens":1,
            "requests":1,
            "usage":0.005
          },
          {
            "date":"2026-08-16",
            "model":"anthropic/claude-opus-4.1",
            "endpoint_id":"endpoint-c",
            "provider_name":"Anthropic",
            "prompt_tokens":300,
            "completion_tokens":100,
            "reasoning_tokens":0,
            "requests":4,
            "usage":27.44
          }
        ]}
        """#
        let now = Date(timeIntervalSince1970: 1_787_079_600) // 2026-08-18T12:00:00Z; stable injected clock.
        let usage = try await Self.fetch(activityBody: activityBody, now: now)
        let cost = try #require(usage.costUsage)

        #expect(cost.historyDays == 30)
        #expect(cost.historyCoverageIsEstablished)
        #expect(cost.currencyCode == "USD")
        #expect(cost.costProvenance == .vendorMetered)
        #expect(cost.last30DaysTokens == 555)
        #expect(cost.last30DaysRequests == 7)
        #expect(abs((cost.last30DaysCostUSD ?? -1) - 39.79) < 1e-9)
        #expect(cost.last30DaysCostUSD?.isFinite == true)
        #expect(cost.daily.count == 2)

        let august17 = try #require(cost.daily.first { $0.date == "2026-08-17" })
        #expect(august17.inputTokens == 102)
        #expect(august17.outputTokens == 53)
        #expect(august17.reasoningTokens == 11)
        #expect(august17.totalTokens == 155)
        #expect(august17.requestCount == 3)
        #expect(abs((august17.costUSD ?? -1) - 12.35) < 1e-9)
        #expect(august17.costUSD?.isFinite == true)
        #expect(august17.modelsUsed == ["openai/gpt-5.6", "x-ai/grok-4"])
        #expect(august17.modelBreakdowns?.count == 2)

        let model = try #require(august17.modelBreakdowns?.first)
        #expect(model.modelName == "openai/gpt-5.6")
        #expect(model.inputTokens == 100)
        #expect(model.outputTokens == 50)
        #expect(model.reasoningTokens == 10)
        #expect(model.totalTokens == 150)
        #expect(model.requestCount == 2)
        #expect(abs((model.costUSD ?? -1) - 12.345) < 1e-9)
    }

    @Test
    func `activity spend includes BYOK estimate without double counting reasoning tokens`() async throws {
        let activityBody = #"""
        {"data":[{
          "date":"2026-08-17",
          "model":"openai/gpt-5.6",
          "endpoint_id":"endpoint-a",
          "prompt_tokens":100,
          "completion_tokens":50,
          "reasoning_tokens":20,
          "requests":2,
          "usage":1.25,
          "byok_usage_inference":0.75
        }]}
        """#
        let usage = try await Self.fetch(activityBody: activityBody)
        let cost = try #require(usage.costUsage)

        #expect(cost.last30DaysCostUSD == 2.0)
        #expect(cost.meteredCostUSD == 1.25)
        #expect(cost.last30DaysTokens == 150)
        #expect(cost.costProvenance == .mixed)
        #expect(cost.daily.first?.estimatedRequestCount == 2)
    }

    @Test
    func `BYOK only activity is labeled as estimated spend`() async throws {
        let activityBody = #"""
        {"data":[{
          "date":"2026-08-17",
          "model_permaslug":"openai/gpt-5.6",
          "endpoint_id":"endpoint-a",
          "prompt_tokens":10,
          "completion_tokens":5,
          "reasoning_tokens":2,
          "requests":1,
          "usage":0,
          "byok_usage_inference":0.75
        }]}
        """#
        let usage = try await Self.fetch(activityBody: activityBody)
        let cost = try #require(usage.costUsage)

        #expect(cost.last30DaysCostUSD == 0.75)
        #expect(cost.meteredCostUSD == nil)
        #expect(cost.costProvenance == .listPriceEstimate)
    }

    @Test
    func `activity permission failure preserves credits and quota`() async throws {
        let requests = OpenRouterRequestRecorder()
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "openrouter",
            transport: ProviderHTTPTransportHandler { request in
                await requests.append(request)
                let path = request.url?.path ?? ""
                if path.hasSuffix("/activity") {
                    return try Self.response(request, body: #"{"error":"forbidden"}"#, statusCode: 403)
                }
                if path.hasSuffix("/key") {
                    return try Self.response(request, body: #"{"data":{"limit":20,"usage":5}}"#)
                }
                return try Self.response(request, body: Self.defaultCreditsBody)
            })

        let usage = try await runtime.fetchUsage(secrets: [
            OpenRouterSettingsReader.envKey: "fixture-key",
            "OPENROUTER_MANAGEMENT_API_KEY": "fixture-management-key",
        ])
        let recorded = await requests.requests

        #expect(usage.costUsage == nil)
        #expect(usage.detailRow(label: "Remaining")?.value == "$60.00")
        #expect(usage.detailRow(label: "Last 30 days")?.secondaryValue == "Management API key required")
        #expect(recorded.count == 4)
    }

    @Test(arguments: [
        #"""
        {"data":[{
          "date":"2026-08-17", "model":"openai/gpt-5.6",
          "prompt_tokens":1e400, "completion_tokens":1, "reasoning_tokens":0,
          "requests":1, "usage":1
        }]}
        """#,
        #"""
        {"data":[
          {
            "date":"2026-08-17", "model":"openai/gpt-5.6",
            "prompt_tokens":5000000000000000000, "completion_tokens":0, "reasoning_tokens":0,
            "requests":1, "usage":1
          },
          {
            "date":"2026-08-17", "model":"openai/gpt-5.6",
            "prompt_tokens":5000000000000000000, "completion_tokens":0, "reasoning_tokens":0,
            "requests":1, "usage":1
          }
        ]}
        """#,
        #"""
        {"data":[
          {
            "date":"2026-08-17", "model":"openai/gpt-5.6", "endpoint_id":"same",
            "prompt_tokens":1, "completion_tokens":1, "reasoning_tokens":0,
            "requests":1, "usage":1
          },
          {
            "date":"2026-08-17", "model":"openai/gpt-5.6", "endpoint_id":"same",
            "prompt_tokens":2, "completion_tokens":1, "reasoning_tokens":0,
            "requests":1, "usage":1
          }
        ]}
        """#,
        #"""
        {"data":[{
          "date":"2026-02-31", "model":"openai/gpt-5.6",
          "prompt_tokens":1, "completion_tokens":1, "reasoning_tokens":0,
          "requests":1, "usage":1
        }]}
        """#,
        #"""
        {"data":[{
          "date":"2026-02-31 00:00:00", "model":"openai/gpt-5.6",
          "prompt_tokens":1, "completion_tokens":1, "reasoning_tokens":0,
          "requests":1, "usage":1
        }]}
        """#,
        #"""
        {"data":[{
          "date":"2026-08-17 24:00:00", "model":"openai/gpt-5.6",
          "prompt_tokens":1, "completion_tokens":1, "reasoning_tokens":0,
          "requests":1, "usage":1
        }]}
        """#,
    ])
    func `nonfinite or overflowing activity never publishes a cost snapshot`(activityBody: String) async throws {
        let usage = try await Self.fetch(activityBody: activityBody)

        #expect(usage.costUsage == nil)
        #expect(usage.detailRow(label: "Remaining")?.value == "$60.00")
        #expect(usage.detailRow(label: "Last 30 days")?.value == "Unavailable right now")
        #expect(usage.detailRow(label: "Last 30 days")?.secondaryValue == "Response was invalid")
    }

    private static let defaultCreditsBody = #"{"data":{"total_credits":100,"total_usage":40}}"#

    private static func fetch(
        creditsBody: String = Self.defaultCreditsBody,
        creditsStatus: Int = 200,
        keyBody: String = #"{"data":{"limit":20,"usage":5}}"#,
        keyStatus: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "openrouter",
            transport: Self.transport(
                creditsBody: creditsBody,
                creditsStatus: creditsStatus,
                keyBody: keyBody,
                keyStatus: keyStatus))
        return try await runtime.fetchUsage(secrets: [OpenRouterSettingsReader.envKey: "fixture-key"])
    }

    private static func fetch(
        activityBody: String,
        now: Date = Date(timeIntervalSince1970: 1_787_079_600)) async throws -> UsageSnapshot
    {
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "openrouter",
            transport: ProviderHTTPTransportHandler { request in
                let body = switch request.url?.path {
                case let path? where path.hasSuffix("/activity"):
                    activityBody
                case let path? where path.hasSuffix("/key"):
                    #"{"data":{"limit":20,"usage":5}}"#
                default:
                    Self.defaultCreditsBody
                }
                return try Self.response(request, body: body)
            })
        return try await runtime.fetchUsage(
            secrets: [
                OpenRouterSettingsReader.envKey: "fixture-key",
                "OPENROUTER_MANAGEMENT_API_KEY": "fixture-management-key",
            ],
            now: now)
    }

    private static func transport(
        requests: OpenRouterRequestRecorder? = nil,
        creditsBody: String = Self.defaultCreditsBody,
        creditsStatus: Int = 200,
        keyBody: String,
        keyStatus: Int = 200) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            if let requests {
                await requests.append(request)
            }
            let isKey = request.url?.path.hasSuffix("/key") == true
            return try Self.response(
                request,
                body: isKey ? keyBody : creditsBody,
                statusCode: isKey ? keyStatus : creditsStatus)
        }
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        statusCode: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}

private actor OpenRouterRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}
#endif
