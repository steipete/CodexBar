#if canImport(JavaScriptCore)
import Foundation
import Testing
@testable import CodexBarCore

struct OpenRouterPluginGoldenTests {
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
    func `requests preserve credits headers and bounded enrichment deadline`() async throws {
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
        #expect(recorded.count == 3)
        #expect(recorded[0].timeoutInterval == 15)
        #expect(recorded[0].value(forHTTPHeaderField: "HTTP-Referer") == "https://codexbar.example")
        #expect(recorded[0].value(forHTTPHeaderField: "X-Title") == "CodexBar QA")
        #expect(recorded[1].timeoutInterval == 1)
        #expect(recorded[1].value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(recorded[1].value(forHTTPHeaderField: "X-Title") == nil)
        #expect(recorded[2].url?.path.hasSuffix("/activity") == true)
        #expect(recorded[2].timeoutInterval == 1)
        #expect(recorded[2].value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(recorded[2].value(forHTTPHeaderField: "X-Title") == nil)
        #expect(usage.detailRow(label: "Today")?.value == "$0.12")
        #expect(usage.detailRow(label: "This week")?.value == "$0.74")
        #expect(usage.detailRow(label: "This month")?.value == "$4.56")
        #expect(usage.detailRow(label: "Rate limit")?.value == "120 requests / 10s")
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
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
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

        #expect(ContinuousClock.now - startedAt < .seconds(2.4))
        #expect(usage.primary == nil)
        #expect(usage.detailRow(label: "API key budget")?.value == "Unavailable right now")
        #expect(usage.detailRow(label: "API key budget")?.secondaryValue == "Request timed out")
        try await Task.sleep(for: .milliseconds(600))
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
