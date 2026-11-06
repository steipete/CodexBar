import Foundation
import Testing
@testable import CodexBarCore

struct PluginStrategyReuseTests {
    @Test
    func `API refreshes reuse their strategy while resolving current credentials`() async throws {
        let descriptor = LLMManProviderDescriptor.spec.makeDescriptor()
        let context = ProviderCutoverTestSupport.context(environment: [:])
        let first = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(context).first
            as? ScriptFetchStrategy)
        for _ in 0..<10 {
            let next = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(context).first
                as? ScriptFetchStrategy)
            #expect(first === next)
        }
        let authenticated = ProviderCutoverTestSupport.context(environment: ["LLMMAN_API_KEY": "fixture"])
        #expect(await first.isAvailable(authenticated))
        #expect(await first.isAvailable(context))
        let values = try #require(LLMManProviderDescriptor.spec.scriptValues(authenticated))
        #expect(values.secrets["LLMMAN_API_KEY"] == "fixture")
        #expect(LLMManProviderDescriptor.spec.scriptValues(context)?.secrets.isEmpty == true)
    }

    @Test
    func `timeout toggles select separate reusable strategies`() async throws {
        let descriptor = LiteLLMProviderDescriptor.spec.makeDescriptor()
        let ordinary = ProviderCutoverTestSupport.context(environment: [:])
        let expanded = ProviderCutoverTestSupport.context(environment: ["LITELLM_MODEL_USAGE_ENABLED": "true"])
        let first = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(ordinary).first
            as? ScriptFetchStrategy)
        let longer = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(expanded).first
            as? ScriptFetchStrategy)
        let restored = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(ordinary).first
            as? ScriptFetchStrategy)
        let longerAgain = try #require(await descriptor.fetchPlan.pipeline.resolveStrategies(expanded).first
            as? ScriptFetchStrategy)
        #expect(first !== longer)
        #expect(first === restored)
        #expect(longer === longerAgain)
    }
}

extension PluginStrategyReuseTests {
    @Test
    func `retained strategies fetch new endpoints credentials and usage`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let percent = request.value(forHTTPHeaderField: "Authorization") == "Bearer first" ? 25 : 50
            let body = request.url?.path == "/api/version" ? #"{"version":"fixture"}"# :
                "{\"memory\":100,\"loaded\":{\"Fixture\":\(percent)},\"stored\":{}}"
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
        let strategy = LLMManProviderDescriptor.spec.makeStrategy(transport: transport)
        for (host, key, expected) in [("first", "first", 25.0), ("second", "second", 50.0)] {
            let context = ProviderCutoverTestSupport.context(environment: [
                "LLMMAN_HOST": "https://\(host).example.test",
                "LLMMAN_API_KEY": key,
            ])
            let result = try await strategy.fetch(context)
            #expect(result.usage.primary?.usedPercent == expected)
        }
        let requests = await transport.requests()
        #expect(requests.map { $0.url?.host } == [
            "first.example.test", "first.example.test", "second.example.test", "second.example.test",
        ])
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == [
            "Bearer first", "Bearer first", "Bearer second", "Bearer second",
        ])
    }
}

extension PluginStrategyReuseTests {
    @Test
    func `overlapping fetches do not queue behind the retained runtime`() async throws {
        let (events, eventWriter) = AsyncStream<Int>.makeStream()
        let (release, releaseWriter) = AsyncStream<Void>.makeStream()
        defer { eventWriter.finish(); releaseWriter.finish() }
        let transport = ProviderHTTPTransportStub { request in
            let first = request.value(forHTTPHeaderField: "Authorization") == "Bearer first"
            if request.url?.path == "/llmman/node" {
                eventWriter.yield(first ? 1 : 2)
                if first {
                    for await _ in release {
                        break
                    }
                }
            }
            let body = request.url?.path == "/api/version" ? #"{"version":"fixture"}"# :
                #"{"memory":100,"loaded":{"Fixture":25},"stored":{}}"#
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }
        let strategy = LLMManProviderDescriptor.spec.makeStrategy(transport: transport, timeout: 5)
        let first = Task {
            defer { eventWriter.yield(-1) }
            return try await strategy
                .fetch(ProviderCutoverTestSupport.context(environment: ["LLMMAN_API_KEY": "first"]))
        }
        defer { first.cancel() }
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        let second = Task {
            defer { eventWriter.yield(-2) }
            return try await strategy
                .fetch(ProviderCutoverTestSupport.context(environment: ["LLMMAN_API_KEY": "second"]))
        }
        defer { second.cancel() }
        #expect(await iterator.next() == 2)
        releaseWriter.finish()
        #expect(try await first.value.usage.primary?.usedPercent == 25)
        #expect(try await second.value.usage.primary?.usedPercent == 25)
    }
}
