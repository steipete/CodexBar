import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct OpenRouterActivityUsageTests {
    @Test
    func `activity rows become thirty day daily and model cost history`() throws {
        let activity = try OpenRouterActivityUsageSnapshot(
            data: Data(Self.activityFixture.utf8),
            now: Self.now,
            historyDays: 30)

        let snapshot = activity.toCostUsageTokenSnapshot()

        #expect(snapshot.historyDays == 30)
        #expect(snapshot.currencyCode == "USD")
        #expect(snapshot.last30DaysTokens == 325)
        #expect(abs((snapshot.last30DaysCostUSD ?? -1) - 0.05) < 0.000_000_001)
        #expect(snapshot.last30DaysRequests == 10)
        #expect(snapshot.daily.map(\.date) == ["2026-08-05", "2026-08-06"])

        let firstDay = try #require(snapshot.daily.first)
        #expect(firstDay.inputTokens == 60)
        #expect(firstDay.outputTokens == 145)
        // OpenRouter documents reasoning_tokens as a subset of completion_tokens.
        // Counting it again would overstate this day by 30 tokens.
        #expect(firstDay.totalTokens == 205)
        #expect(firstDay.requestCount == 7)
        #expect(abs((firstDay.costUSD ?? -1) - 0.02) < 0.000_000_001)
        #expect(firstDay.modelsUsed == ["anthropic/claude-sonnet-4-6"])

        let model = try #require(firstDay.modelBreakdowns?.only)
        #expect(model.modelName == "anthropic/claude-sonnet-4-6")
        #expect(model.totalTokens == 205)
        #expect(model.requestCount == 7)
        #expect(abs((model.costUSD ?? -1) - 0.02) < 0.000_000_001)
    }

    @Test
    func `duplicate routed models aggregate without adding estimated BYOK spend`() throws {
        let activity = try OpenRouterActivityUsageSnapshot(
            data: Data(Self.activityFixture.utf8),
            now: Self.now)

        let snapshot = activity.toCostUsageTokenSnapshot()
        let firstDay = try #require(snapshot.daily.first)
        let claudeRows = try #require(firstDay.modelBreakdowns?.filter {
            $0.modelName == "anthropic/claude-sonnet-4-6"
        })

        #expect(claudeRows.count == 1)
        #expect(claudeRows.only?.totalTokens == 205)
        #expect(claudeRows.only?.requestCount == 7)
        #expect(abs((claudeRows.only?.costUSD ?? -1) - 0.02) < 0.000_000_001)
        // The fixture also carries $1.25 of byok_usage_inference. `usage` is the
        // OpenRouter spend field; combining the two would fabricate $1.27.
        #expect(abs((firstDay.costUSD ?? -1) - 0.02) < 0.000_000_001)
    }

    @Test @MainActor
    func `transient activity failure preserves only current credential history`() throws {
        let activity = try OpenRouterActivityUsageSnapshot(
            data: Data(Self.activityFixture.utf8),
            now: Self.now)
        let previous = UsageSnapshot(
            primary: nil,
            secondary: nil,
            openRouterActivityUsage: activity,
            updatedAt: Self.now)
        let current = UsageSnapshot(primary: nil, secondary: nil, updatedAt: Self.now)
        let settings = testSettingsStore(
            suiteName: "OpenRouterActivityUsageTests-\(UUID().uuidString)",
            tokenAccountStore: InMemoryTokenAccountStore())
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.publishTokenSnapshot(activity.toCostUsageTokenSnapshot(), for: .openrouter)

        let preserved = store.preservingOpenRouterActivityIfCurrent(current, previous: previous)
        #expect(preserved.openRouterActivityUsage == activity)

        settings[providerConfig: .openrouter, field: .apiKey] = "changed-scope-fixture"
        let rejected = store.preservingOpenRouterActivityIfCurrent(current, previous: previous)
        #expect(rejected.openRouterActivityUsage == nil)
    }

    @Test
    func `bundled plugin projects activity into provider snapshot`() async throws {
        let requests = OpenRouterActivityRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await requests.append(request)
            switch request.url?.lastPathComponent {
            case "activity":
                return try Self.response(request, body: Self.activityFixture)
            case "key":
                return try Self.response(request, body: #"{"data":{}}"#)
            default:
                return try Self.response(request, body: #"{"data":{"total_credits":100,"total_usage":40}}"#)
            }
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport)

        let usage = try await runtime.fetchUsage(
            settings: [
                OpenRouterSettingsReader.apiURLEnvironmentKey: "https://openrouter.test/api/v1",
            ],
            secrets: [OpenRouterSettingsReader.envKey: "fixture-management-key"],
            now: Self.now)

        let paths = await requests.requests.compactMap(\.url?.path)
        #expect(paths.contains("/api/v1/activity"))
        let activity = try #require(usage.openRouterActivityUsage)
        #expect(activity.toCostUsageTokenSnapshot().last30DaysTokens == 325)
        #expect(abs((activity.toCostUsageTokenSnapshot().last30DaysCostUSD ?? -1) - 0.05) < 0.000_000_001)
    }

    @Test
    func `bundled plugin treats activity forbidden as optional`() async throws {
        let requests = OpenRouterActivityRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await requests.append(request)
            switch request.url?.lastPathComponent {
            case "activity":
                return try Self.response(
                    request,
                    body: #"{"error":{"message":"management key required"}}"#,
                    statusCode: 403)
            case "key":
                return try Self.response(request, body: #"{"data":{}}"#)
            default:
                return try Self.response(request, body: #"{"data":{"total_credits":100,"total_usage":40}}"#)
            }
        }
        let runtime = try ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport)

        let usage = try await runtime.fetchUsage(
            settings: [
                OpenRouterSettingsReader.apiURLEnvironmentKey: "https://openrouter.test/api/v1",
            ],
            secrets: [OpenRouterSettingsReader.envKey: "ordinary-api-key"])

        let paths = await requests.requests.compactMap(\.url?.path)
        #expect(paths.contains("/api/v1/activity"))
        #expect(usage.openRouterActivityUsage == nil)
        #expect(usage.detailRow(label: "Remaining")?.value == "$60.00")
    }

    private static let now = Date(timeIntervalSince1970: 1_785_974_400) // 2026-08-07 00:00:00 UTC

    private static let activityFixture = #"""
    {
      "data": [
        {
          "byok_usage_inference": 1.0,
          "completion_tokens": 125,
          "date": "2026-08-05",
          "endpoint_id": "endpoint-claude-a",
          "model": "anthropic/claude-sonnet-4-6",
          "model_permaslug": "anthropic/claude-sonnet-4-6-20260219",
          "prompt_tokens": 50,
          "provider_name": "Anthropic",
          "reasoning_tokens": 25,
          "requests": 5,
          "usage": 0.015
        },
        {
          "byok_usage_inference": 0.25,
          "completion_tokens": 20,
          "date": "2026-08-05",
          "endpoint_id": "endpoint-claude-b",
          "model": "anthropic/claude-sonnet-4-6",
          "model_permaslug": "anthropic/claude-sonnet-4-6-20260219",
          "prompt_tokens": 10,
          "provider_name": "Anthropic",
          "reasoning_tokens": 5,
          "requests": 2,
          "usage": 0.005
        },
        {
          "byok_usage_inference": 0,
          "completion_tokens": 80,
          "date": "2026-08-06",
          "endpoint_id": "endpoint-gpt",
          "model": "openai/gpt-5.4-mini",
          "model_permaslug": "openai/gpt-5.4-mini-20260801",
          "prompt_tokens": 40,
          "provider_name": "OpenAI",
          "reasoning_tokens": 20,
          "requests": 3,
          "usage": 0.03
        }
      ]
    }
    """#

    private static func response(
        _ request: URLRequest,
        body: String,
        statusCode: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(try HTTPURLResponse(
            url: #require(request.url),
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }
}

private actor OpenRouterActivityRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}

extension Array {
    fileprivate var only: Element? {
        self.count == 1 ? self[0] : nil
    }
}
