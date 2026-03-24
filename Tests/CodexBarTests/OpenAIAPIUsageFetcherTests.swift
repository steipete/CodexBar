import CodexBarCore
import Foundation
import Testing

struct OpenAIAPIUsageFetcherTests {
    @Test
    func `organization usage endpoints build token and cost snapshot`() async {
        let now = Self.date("2026-03-23T12:00:00Z")
        let result = await OpenAIAPIUsageFetcher.loadSnapshot(
            apiKey: "sk-test",
            now: now,
            dataLoader: GeminiAPITestHelpers.dataLoader { request in
                guard let url = request.url else { throw URLError(.badURL) }
                switch url.path {
                case "/v1/organization/costs":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.jsonData([
                            "data": [
                                [
                                    "start_time": Self.unix("2026-03-22T00:00:00Z"),
                                    "end_time": Self.unix("2026-03-23T00:00:00Z"),
                                    "results": [
                                        [
                                            "amount": [
                                                "value": 1.25,
                                                "currency": "usd",
                                            ],
                                            "line_item": "completions",
                                        ],
                                    ],
                                ],
                                [
                                    "start_time": Self.unix("2026-03-23T00:00:00Z"),
                                    "end_time": Self.unix("2026-03-24T00:00:00Z"),
                                    "results": [
                                        [
                                            "amount": [
                                                "value": 4.5,
                                                "currency": "usd",
                                            ],
                                            "line_item": "completions",
                                        ],
                                    ],
                                ],
                            ],
                        ]))
                case "/v1/organization/usage/completions":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.jsonData([
                            "data": [
                                [
                                    "start_time": Self.unix("2026-03-22T00:00:00Z"),
                                    "end_time": Self.unix("2026-03-23T00:00:00Z"),
                                    "results": [
                                        [
                                            "input_tokens": 100,
                                            "output_tokens": 50,
                                            "input_cached_tokens": 20,
                                            "model": "gpt-5",
                                        ],
                                    ],
                                ],
                                [
                                    "start_time": Self.unix("2026-03-23T00:00:00Z"),
                                    "end_time": Self.unix("2026-03-24T00:00:00Z"),
                                    "results": [
                                        [
                                            "input_tokens": 200,
                                            "output_tokens": 300,
                                            "input_cached_tokens": 40,
                                            "model": "gpt-5",
                                        ],
                                    ],
                                ],
                            ],
                        ]))
                case "/v1/usage":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.jsonData([
                            "object": "list",
                            "data": [],
                        ]))
                default:
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 404,
                        body: Self.jsonData(["error": "unexpected path \(url.path)"]))
                }
            })

        #expect(result.errorMessage == nil)
        #expect(result.snapshot.daily.count == 2)
        #expect(result.snapshot.sessionCostUSD == 4.5)
        #expect(result.snapshot.sessionTokens == 500)
        #expect(result.snapshot.last30DaysCostUSD == 5.75)
        #expect(result.snapshot.last30DaysTokens == 650)
    }

    @Test
    func `falls back to legacy today usage when org usage scope is missing`() async throws {
        let now = Self.date("2026-03-23T12:00:00Z")
        let scopeError = "You have insufficient permissions for this operation. Missing scopes: api.usage.read."
        let result = await OpenAIAPIUsageFetcher.loadSnapshot(
            apiKey: "sk-test",
            now: now,
            dataLoader: GeminiAPITestHelpers.dataLoader { request in
                guard let url = request.url else { throw URLError(.badURL) }
                switch url.path {
                case "/v1/organization/costs", "/v1/organization/usage/completions":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 403,
                        body: Self.jsonData(["error": scopeError]))
                case "/v1/usage":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.jsonData([
                            "object": "list",
                            "data": [
                                [
                                    "n_context_tokens_total": 120,
                                    "n_generated_tokens_total": 30,
                                ],
                            ],
                        ]))
                default:
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 404,
                        body: Self.jsonData(["error": "unexpected path \(url.path)"]))
                }
            })

        #expect(result.snapshot.daily.count == 1)
        #expect(result.snapshot.sessionCostUSD == nil)
        #expect(result.snapshot.last30DaysCostUSD == nil)
        #expect(result.snapshot.sessionTokens == 150)
        #expect(result.snapshot.last30DaysTokens == 150)
        let error = try #require(result.errorMessage)
        #expect(error.contains("OpenAI blocked spend data for this key"))
        #expect(error.contains("Token usage is shown, but cost is unavailable"))
        #expect(error.contains("api.usage.read"))
    }

    @Test
    func `surfaces permission error when no usage data is accessible`() async throws {
        let now = Self.date("2026-03-23T12:00:00Z")
        let scopeError = "You have insufficient permissions for this operation. Missing scopes: api.usage.read."
        let result = await OpenAIAPIUsageFetcher.loadSnapshot(
            apiKey: "sk-test",
            now: now,
            dataLoader: GeminiAPITestHelpers.dataLoader { request in
                guard let url = request.url else { throw URLError(.badURL) }
                switch url.path {
                case "/v1/organization/costs", "/v1/organization/usage/completions":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 403,
                        body: Self.jsonData(["error": scopeError]))
                case "/v1/usage":
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: Self.jsonData([
                            "object": "list",
                            "data": [],
                        ]))
                default:
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 404,
                        body: Self.jsonData(["error": "unexpected path \(url.path)"]))
                }
            })

        #expect(result.snapshot.daily.isEmpty)
        let error = try #require(result.errorMessage)
        #expect(error.contains("OpenAI blocked spend data for this key"))
        #expect(error.contains("api.usage.read"))
    }

    private static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    private static func unix(_ value: String) -> Int {
        Int(self.date(value).timeIntervalSince1970)
    }

    private static func jsonData(_ payload: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}
