import Foundation
import Testing
@testable import CodexBarCore

struct ProviderFetchErrorTests {
    @Test
    func `missing kiro strategy explains cli requirement`() {
        let message = ProviderFetchError.noAvailableStrategy(.kiro).localizedDescription

        #expect(message.contains("Kiro CLI"))
        #expect(message.contains("kiro-cli login"))
    }

    @Test
    func `pipeline honors one exact classified retry delay`() async throws {
        let state = DelayedRetryStrategyState()
        let strategy = DelayedRetryStrategy(state: state)
        let delays = RetryDelayRecorder()
        let pipeline = ProviderFetchPipeline(
            resolveStrategies: { _ in [strategy] },
            retrySleeper: { seconds in await delays.record(seconds) })

        let outcome = await pipeline.fetch(context: Self.context(), provider: .neuralwatt)

        _ = try outcome.result.get()
        #expect(await state.fetchCount == 2)
        #expect(await delays.values == [3])
        #expect(outcome.attempts.count == 1)
        #expect(outcome.attempts.first?.errorDescription == nil)
    }

    private static func context() -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}

private actor DelayedRetryStrategyState {
    private(set) var fetchCount = 0

    func nextFetchShouldFail() -> Bool {
        self.fetchCount += 1
        return self.fetchCount == 1
    }
}

private struct DelayedRetryStrategy: ProviderFetchStrategy {
    let state: DelayedRetryStrategyState
    let id = "delayed-retry-test"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool {
        true
    }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        if await self.state.nextFetchShouldFail() {
            throw ProviderFetchClassifiedError(
                kind: .rateLimited,
                message: "retry fixture",
                retryAfterSeconds: 3)
        }
        return self.makeResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            sourceLabel: "test")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}

private actor RetryDelayRecorder {
    private(set) var values: [TimeInterval] = []

    func record(_ value: TimeInterval) {
        self.values.append(value)
    }
}
