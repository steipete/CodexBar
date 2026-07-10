import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct CostUsageFetcherUnknownModelPricingTests {
    @Test
    func `fetcher reprices an unknown model after an on demand catalog refresh`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 4, day: 12)
        let oldCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-old": { "id": "gpt-old", "cost": { "input": 1, "output": 4 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-old": { "id": "claude-old", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8))
        try ModelsDevCache.save(catalog: oldCatalog, fetchedAt: day, cacheRoot: env.cacheRoot)

        let refreshedCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-new": { "id": "gpt-new", "cost": { "input": 2, "output": 8 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-new": { "id": "claude-new", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8)
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": env.isoString(for: day),
            "payload": ["model": "gpt-new"],
        ]
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": env.isoString(for: day.addingTimeInterval(1)),
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "unknown-model.jsonl",
            contents: env.jsonl([turnContext, tokenCount]))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            refreshPricingInBackground: false,
            scannerOptions: options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: refreshedCatalog)))

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-new")
        #expect(abs((breakdown.costUSD ?? 0) - 0.00028) < 0.0000001)
    }
}

private struct CostUsageFetcherModelsDevTransport: ModelsDevHTTPTransport {
    let data: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (self.data, response)
    }
}
