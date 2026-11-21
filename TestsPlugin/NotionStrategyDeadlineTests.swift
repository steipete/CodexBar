import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct NotionStrategyDeadlineTests {
    enum Scenario: String, CaseIterable, Sendable {
        case quick, lateSuccess, lateTimeout
    }

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines, Scenario.allCases)
    func `optional lookup cannot consume the successful required request budget`(
        engine: ProviderPluginEngineKind, scenario: Scenario) async throws
    {
        let clock = DeadlineClock()
        let trace = Trace()
        let (starts, started) = AsyncStream<Void>.makeStream()
        let (responses, respond) = AsyncStream<Void>.makeStream()
        let strategy = try Self.strategy(engine: engine, clock: clock) { request in
            let endpoint = try #require(request.url?.lastPathComponent)
            trace.append(endpoint)
            if endpoint == "getAIUsageEligibilityV2" {
                #expect(request.timeoutInterval == 3)
                started.yield(())
                var iterator = responses.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
                if scenario == .lateTimeout { throw URLError(.timedOut) }
                return try Self.response(request, body: #"{"premiumCredits":{"totalCreditBalance":0}}"#)
            }
            #expect(request.timeoutInterval == 15)
            let budget = await clock.budget(for: 1)
            #expect(budget == 35)
            _ = await clock.advance(by: scenario == .quick ? 0.1 : 14.9)
            return try Self.response(
                request,
                body: endpoint == "getSpaces"
                    ? NotionPluginTests.spaces : NotionPluginTests.allowances)
        }
        let fetch = Task { try await strategy.fetch(Self.context()) }
        var iterator = starts.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        // Both required responses have been delivered. Hold the optional response while logical
        // time crosses the old 30-second cutoff, without sleeping for real request deadlines.
        let expired = await clock.advance(by: scenario == .quick ? 0.1 : 2.9)
        let result: Result<ProviderFetchResult, any Error>
        if expired {
            result = await fetch.result
            respond.yield(())
        } else {
            respond.yield(())
            result = await fetch.result
        }
        respond.finish()
        started.finish()
        await clock.finish()
        let snapshot = try result.get().usage
        #expect(snapshot.primary?.usedPercent == 42)
        #expect(snapshot.secondary?.usedPercent == 18)
        #expect(snapshot.detailRow(label: "Remaining credits")?.value == (scenario == .lateTimeout ? nil : "0"))
        #expect(trace.values == ["getSpaces", "getCreditRateLimitStatus", "getAIUsageEligibilityV2"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: BundledPluginTestSupport.engines)
    func `optional cancellation discards the worker and the same strategy refreshes without stale credits`(
        engine: ProviderPluginEngineKind) async throws
    {
        let clock = DeadlineClock()
        let trace = Trace()
        let (starts, started) = AsyncStream<Void>.makeStream()
        let (responses, respond) = AsyncStream<Void>.makeStream()
        let (cancellations, cancelled) = AsyncStream<Void>.makeStream()
        let strategy = try Self.strategy(engine: engine, clock: clock) { request in
            let endpoint = try #require(request.url?.lastPathComponent)
            trace.append(endpoint)
            if endpoint == "getAIUsageEligibilityV2" {
                started.yield(())
                var iterator = responses.makeAsyncIterator()
                _ = await iterator.next()
                cancelled.yield(())
                throw CancellationError()
            }
            return try Self.response(
                request,
                body: endpoint == "getSpaces"
                    ? NotionPluginTests.spaces : NotionPluginTests.allowances)
        }
        let fetch = Task { try await strategy.fetch(Self.context()) }
        var iterator = starts.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        fetch.cancel()
        await #expect(throws: CancellationError.self) { try await fetch.value }
        var cancellationIterator = cancellations.makeAsyncIterator()
        #expect(await cancellationIterator.next() != nil)
        let snapshot = try await strategy.fetch(Self.context(optional: false)).usage
        #expect(snapshot.primary?.usedPercent == 42)
        #expect(snapshot.secondary?.usedPercent == 18)
        #expect(snapshot.details.isEmpty)
        #expect(trace.values.filter { $0 == "getAIUsageEligibilityV2" }.count == 1)
        #expect(trace.values.filter { $0 == "getCreditRateLimitStatus" }.count == 2)
        respond.finish()
        started.finish()
        cancelled.finish()
        await clock.finish()
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `required failure never requests optional credits and longer configured budgets retain headroom`(
        engine: ProviderPluginEngineKind) async throws
    {
        let clock = DeadlineClock()
        let trace = Trace()
        let strategy = try Self.strategy(engine: engine, clock: clock, timeout: 60) { request in
            let endpoint = try #require(request.url?.lastPathComponent)
            trace.append(endpoint)
            #expect(await clock.budget(for: 1) == 125)
            return try Self.response(
                request,
                body: NotionPluginTests.spaces,
                status: endpoint == "getSpaces" ? 200 : 503)
        }
        await #expect(throws: (any Error).self) { try await strategy.fetch(Self.context()) }
        #expect(trace.values == ["getSpaces", "getCreditRateLimitStatus"])
        await clock.finish()
    }

    private static func strategy(
        engine: ProviderPluginEngineKind, clock: DeadlineClock, timeout: TimeInterval = 15,
        handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) throws -> ScriptFetchStrategy
    {
        var options = ProviderPluginContextOptions.production
        options.waitForFetchDeadline = { await clock.sleep(seconds: $0) }
        let strategy = NotionProviderDescriptor.webStrategy(
            timeout: timeout, transport: ProviderHTTPTransportHandler(handler))
        try strategy.prepareRuntime(contextOptions: options, engine: engine)
        return strategy
    }

    private static func context(optional: Bool = true) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app, sourceMode: .web, includeCredits: false, includeOptionalUsage: optional,
            webTimeout: 15, webDebugDumpHTML: false, verbose: false, env: [:],
            settings: .make(notion: .init(
                cookieSource: .manual, manualCookieHeader: "token_v2=synthetic", workspaceID: nil)),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection()),
            browserDetection: BrowserDetection())
    }

    private static func response(_ request: URLRequest, body: String, status: Int = 200) throws
        -> (Data, HTTPURLResponse)
    {
        let url = try #require(request.url)
        return try (Data(body.utf8), #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: nil)))
    }

    private final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var values: [String] {
            self.lock.withLock { self.storage }
        }

        func append(_ value: String) { self.lock.withLock { self.storage.append(value) } }
    }

    private actor DeadlineClock {
        private var closed = false
        private var now: TimeInterval = 0
        private var budgets: [TimeInterval] = []
        private var sleepers: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
        private var observers: [(Int, CheckedContinuation<TimeInterval, Never>)] = []

        func sleep(seconds: TimeInterval) async {
            guard !self.closed else { return }
            self.budgets.append(seconds)
            await withCheckedContinuation { continuation in
                self.sleepers.append((self.now + seconds, continuation))
                let ready = self.observers.filter { $0.0 <= self.budgets.count }
                self.observers.removeAll { $0.0 <= self.budgets.count }
                for (index, observer) in ready {
                    observer.resume(returning: self.budgets[index - 1])
                }
            }
        }

        func budget(for index: Int) async -> TimeInterval {
            if self.budgets.count >= index { return self.budgets[index - 1] }
            return await withCheckedContinuation { self.observers.append((index, $0)) }
        }

        func advance(by seconds: TimeInterval) -> Bool {
            self.now += seconds
            let ready = self.sleepers.filter { $0.0 <= self.now }
            self.sleepers.removeAll { $0.0 <= self.now }
            for (_, sleeper) in ready {
                sleeper.resume()
            }
            return !ready.isEmpty
        }

        func finish() {
            self.closed = true
            for (_, sleeper) in self.sleepers {
                sleeper.resume()
            }
            self.sleepers.removeAll()
        }
    }
}
