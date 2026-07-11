import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct CostUsageFetcherUnknownModelPricingTests {
    @Test
    func `fetcher reprices an unknown model after an on demand catalog refresh`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: fixture.day,
            refreshPricingInBackground: false,
            scannerOptions: fixture.options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: fixture.refreshedCatalog)))

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-new")
        #expect(abs((breakdown.costUSD ?? 0) - 0.00028) < 0.0000001)
    }

    @Test
    func `background pricing refresh returns unpriced usage before catalog download finishes`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        let gate = UnknownModelPricingTransportGate()
        let completion = UnknownModelPricingCompletionProbe()
        let task = Task {
            let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: fixture.day,
                refreshPricingInBackground: true,
                scannerOptions: fixture.options,
                modelsDevClient: ModelsDevClient(transport: CostUsageFetcherGatedModelsDevTransport(
                    data: fixture.refreshedCatalog,
                    gate: gate)))
            await completion.markCompleted()
            return snapshot
        }

        await gate.waitUntilStarted()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await !(completion.isCompleted), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let returnedBeforeRelease = await completion.isCompleted
        await gate.release()
        let snapshot = try await task.value

        #expect(returnedBeforeRelease)
        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-new")
        #expect(breakdown.totalTokens == 110)
        #expect(breakdown.costUSD == nil)

        let refreshDeadline = clock.now.advanced(by: .seconds(1))
        while ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-new",
            cacheRoot: fixture.environment.cacheRoot) == nil,
            clock.now < refreshDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-new",
            cacheRoot: fixture.environment.cacheRoot) != nil)
    }

    @Test
    func `unattributed codex usage does not request a pricing refresh`() async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 4, day: 12)
        let staleCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "known-test-model": { "id": "known-test-model", "cost": { "input": 1, "output": 4 } } }
          }
        }
        """.utf8))
        ModelsDevCache.save(
            catalog: staleCatalog,
            fetchedAt: day.addingTimeInterval(-901),
            cacheRoot: environment.cacheRoot)
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": environment.isoString(for: day),
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        _ = try environment.writeCodexSessionFile(
            day: day,
            filename: "unattributed-model.jsonl",
            contents: environment.jsonl([tokenCount]))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            claudeProjectsRoots: [environment.claudeProjectsRoot],
            cacheRoot: environment.cacheRoot)
        let counter = UnknownModelPricingRequestCounter()

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            refreshPricingInBackground: false,
            scannerOptions: options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherCountingModelsDevTransport(counter: counter)))

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        let requestCount = await counter.requestCount
        #expect(breakdown.modelName == CostUsagePricing.codexUnattributedModel)
        #expect(breakdown.totalTokens == 110)
        #expect(breakdown.costUSD == nil)
        #expect(requestCount == 0)
    }
}

private struct UnknownModelPricingFixture {
    let environment: CostUsageTestEnvironment
    let day: Date
    let options: CostUsageScanner.Options
    let refreshedCatalog: Data

    init() throws {
        let environment = try CostUsageTestEnvironment()
        self.environment = environment
        self.day = try environment.makeLocalNoon(year: 2026, month: 4, day: 12)
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
        ModelsDevCache.save(
            catalog: oldCatalog,
            fetchedAt: self.day.addingTimeInterval(-901),
            cacheRoot: environment.cacheRoot)

        self.refreshedCatalog = Data("""
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
            "timestamp": environment.isoString(for: self.day),
            "payload": ["model": "gpt-new"],
        ]
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": environment.isoString(for: self.day.addingTimeInterval(1)),
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
        _ = try environment.writeCodexSessionFile(
            day: self.day,
            filename: "unknown-model.jsonl",
            contents: environment.jsonl([turnContext, tokenCount]))
        self.options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            claudeProjectsRoots: [environment.claudeProjectsRoot],
            cacheRoot: environment.cacheRoot)
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

private struct CostUsageFetcherGatedModelsDevTransport: ModelsDevHTTPTransport {
    let data: Data
    let gate: UnknownModelPricingTransportGate

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await self.gate.markStartedAndWaitForRelease()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (self.data, response)
    }
}

private actor UnknownModelPricingTransportGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        self.started = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }
}

private actor UnknownModelPricingCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        self.isCompleted = true
    }
}

private actor UnknownModelPricingRequestCounter {
    private(set) var requestCount = 0

    func recordRequest() {
        self.requestCount += 1
    }
}

private struct CostUsageFetcherCountingModelsDevTransport: ModelsDevHTTPTransport {
    let counter: UnknownModelPricingRequestCounter

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await self.counter.recordRequest()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(#"{"openai":{"id":"openai","models":{}}}"#.utf8), response)
    }
}
