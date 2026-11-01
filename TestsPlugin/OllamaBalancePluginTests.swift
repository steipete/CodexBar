import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct OllamaBalancePluginTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `legacy remaining percentages become used windows`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(
            #"""
            {"included":{
              "session":{"remaining_percent":75,"resets_at":"2026-10-01T07:00:00Z"},
              "weekly":{"remaining_percent":40,"resets_at":"2026-10-05T00:00:00Z"}},
             "purchased":{"balance_usd":25}}
            """#,
            engine: engine)
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 60)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-10-01T07:00:00Z"))
        #expect(usage.detailRow(label: "Credit balance")?.value == "$25.00")
        #expect(usage.detailRow(label: "Monthly credits used") == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `monthly remaining balance maps usage and zero allowance has no percent`(
        engine: ProviderPluginEngineKind) async throws
    {
        let monthly = try await Self.fetch(
            #"""
            {"included":{"balance_usd":"75","allowance_usd":100,"period":{"until":"2026-12-01T00:00:00Z"}},
             "purchased":{"balance_usd":"12.50"}}
            """#,
            engine: engine)
        #expect(monthly.primary?.usedPercent == 25)
        #expect(monthly.primary?.windowMinutes == 43200)
        #expect(monthly.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        #expect(monthly.detailRow(label: "Credit balance")?.value == "$12.50")
        let zero = try await Self.fetch(#"{"included":{"balance_usd":0,"allowance_usd":0}}"#, engine: engine)
        #expect(zero.primary == nil)
        #expect(zero.detailRow(label: "Monthly credits used")?.value == "$0.00")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `invalid legacy percentages fail safely`(engine: ProviderPluginEngineKind) async throws {
        for value in ["-1", "101", "true", "null", "\"NaN\""] {
            do {
                _ = try await Self.fetch(
                    "{\"included\":{\"session\":{\"remaining_percent\":\(value)}}}",
                    engine: engine)
                Issue.record("Expected parse failure")
            } catch let error as ProviderFetchClassifiedError {
                #expect(error.kind == .parseFailure)
            }
        }
    }

    @Test
    func `cooldown caches success rate limits and unavailable reporting by credential`() async throws {
        for status in [200, 429, 503] {
            let base = BalanceFixtureTransport(status: status)
            let transport = OllamaBalanceTransport(base: base)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var request = try URLRequest(url: #require(URL(string: "https://ollama.com/api/balance")))
            request.httpMethod = "GET"
            request.setValue("Bearer synthetic-a", forHTTPHeaderField: "Authorization")
            _ = try await transport.data(for: request, now: now)
            _ = try await transport.data(for: request, now: now.addingTimeInterval(59))
            #expect(await base.count == 1)
            _ = try await transport.data(for: request, now: now.addingTimeInterval(61))
            #expect(await base.count == (status == 429 ? 1 : 2))
            request.setValue("Bearer synthetic-b", forHTTPHeaderField: "Authorization")
            _ = try await transport.data(for: request, now: now.addingTimeInterval(62))
            #expect(await base.count == (status == 429 ? 2 : 3))
            request.setValue("Bearer synthetic-a", forHTTPHeaderField: "Authorization")
            _ = try await transport.data(for: request, now: now.addingTimeInterval(122))
            #expect(await base.count == (status == 429 ? 3 : 4))
        }
    }

    @Test
    func `API first auto mode permits web fallback for reporting failures only when enabled`() async throws {
        let browser = BrowserDetection(cacheTTL: 0)
        func context(_ mode: ProviderSourceMode, cookies: ProviderCookieSource = .auto) -> ProviderFetchContext {
            ProviderFetchContext(
                runtime: .cli,
                sourceMode: mode,
                includeCredits: false,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: ["OLLAMA_API_KEY": "fixture-key"],
                settings: ProviderSettingsSnapshot.make(ollama: .init(
                    cookieSource: cookies,
                    manualCookieHeader: nil)),
                fetcher: UsageFetcher(environment: [:]),
                claudeFetcher: ClaudeUsageFetcher(browserDetection: browser, environment: [:]),
                browserDetection: browser)
        }
        let manual = await OllamaProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context(
            .auto,
            cookies: .manual))
        #expect(manual.map(\.id) == ["ollama.web"])
        let auto = context(.auto)
        let strategies = await OllamaProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(auto)
        #expect(strategies.map(\.id) == ["ollama.api", "ollama.web"])
        let api = try #require(strategies.first)
        for kind: ProviderFetchClassifiedError.Kind in [.rateLimited, .providerUnavailable, .parseFailure] {
            let error = ProviderFetchClassifiedError(kind: kind, message: "synthetic")
            #expect(api.shouldFallback(on: error, context: auto))
            #expect(!api.shouldFallback(on: error, context: context(.api)))
            #expect(!api.shouldFallback(on: error, context: context(.auto, cookies: .off)))
        }
        #expect(!api.shouldFallback(on: CancellationError(), context: auto))
        for status in [429, 503] {
            let transport = OllamaBalanceTransport(base: BalanceFixtureTransport(status: status))
            let pipeline = ProviderFetchPipeline(resolveStrategies: { _ in
                [OllamaProviderDescriptor.apiStrategy(transport: transport), BalanceFixtureWebStrategy()]
            })
            let outcome = await pipeline.fetch(context: auto, provider: .ollama)
            let result = try outcome.result.get()
            #expect(result.sourceLabel == "web")
            #expect(result.usage.primary?.usedPercent == 12)
            #expect(outcome.attempts.map(\.strategyID) == ["ollama.api", "fixture.web"])
        }
    }

    @Test
    func `retry after begins when the response arrives`() async throws {
        let clock = BalanceFixtureClock()
        let base = ProviderHTTPTransportHandler { request in
            clock.advance(15)
            return (Data("{}".utf8), HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "120"])!)
        }
        let transport = OllamaBalanceTransport(base: base, clock: { clock.now })
        var request = try URLRequest(url: #require(URL(string: "https://ollama.com/api/balance")))
        request.httpMethod = "GET"
        request.setValue("Bearer synthetic-delayed", forHTTPHeaderField: "Authorization")
        let now = clock.now
        _ = try await transport.data(for: request, now: now)
        _ = try await transport.data(for: request, now: now.addingTimeInterval(122))
        #expect(clock.now == now.addingTimeInterval(15))
        _ = try await transport.data(for: request, now: now.addingTimeInterval(136))
        #expect(clock.now == now.addingTimeInterval(30))
    }

    static func fetch(_ body: String, engine: ProviderPluginEngineKind) async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime(
            "ollama-api",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(body.utf8), response)
            })
        return try await runtime.fetchUsage(secrets: ["OLLAMA_API_KEY": "fixture-key"])
    }
}

private actor BalanceFixtureTransport: ProviderHTTPTransport {
    let status: Int
    private(set) var count = 0

    init(status: Int) { self.status = status }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.count += 1
        return (Data("{}".utf8), HTTPURLResponse(
            url: request.url!,
            statusCode: self.status,
            httpVersion: nil,
            headerFields: ["Retry-After": "120"])!)
    }
}

private final class BalanceFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date {
        self.lock.withLock { self.value }
    }

    func advance(_ seconds: TimeInterval) { self.lock.withLock { self.value.addTimeInterval(seconds) } }
}

private struct BalanceFixtureWebStrategy: ProviderFetchStrategy {
    let id = "fixture.web"
    let kind: ProviderFetchKind = .web
    func isAvailable(_: ProviderFetchContext) async -> Bool { true }
    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        let snapshot = try OllamaUsageParser.parse(html: "<span>Session usage</span><span>12% used</span>")
        return self.makeResult(usage: snapshot.toUsageSnapshot(), sourceLabel: "web")
    }
}
