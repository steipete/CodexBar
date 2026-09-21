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

    @Test
    func `terminal errors use the resolver while routing retains each original error`() async {
        let routed = LockIsolated<[TerminalFixtureFailure]>([])
        let resolutions = LockIsolated(0)
        let strategies = [
            TerminalFixtureStrategy(id: "first", error: .first, allowsFallback: true, routed: routed),
            TerminalFixtureStrategy(id: "terminal", error: .terminal, routed: routed),
        ]
        let pipeline = ProviderFetchPipeline(
            resolveStrategies: { _ in strategies },
            resolveFallbackError: { previous, _ in
                resolutions.setValue(resolutions.value + 1)
                return previous ?? TerminalFixtureFailure.resolved
            })
        let outcome = await pipeline.fetch(context: Self.context(), provider: .neuralwatt)
        do {
            _ = try outcome.result.get()
            Issue.record("Expected resolved terminal failure")
        } catch {
            #expect(error as? TerminalFixtureFailure == .resolved)
        }
        #expect(routed.value == [.first, .terminal])
        #expect(resolutions.value == 2)
        #expect(outcome.attempts.last?.errorDescription == TerminalFixtureFailure.terminal.localizedDescription)
    }

    @Test
    func `default resolver keeps the terminal source error`() async {
        let pipeline = ProviderFetchPipeline(resolveStrategies: { _ in
            [
                TerminalFixtureStrategy(id: "first", error: .first, allowsFallback: true),
                TerminalFixtureStrategy(id: "terminal", error: .terminal),
            ]
        })
        let outcome = await pipeline.fetch(context: Self.context(), provider: .neuralwatt)
        do {
            _ = try outcome.result.get()
            Issue.record("Expected terminal failure")
        } catch {
            #expect(error as? TerminalFixtureFailure == .terminal)
        }
    }

    @Test(arguments: [false, true])
    func `cancellation wins over a resolved earlier error`(_ cancelTask: Bool) async {
        let outcome = await Task {
            let pipeline = ProviderFetchPipeline(
                resolveStrategies: { _ in
                    [
                        TerminalFixtureStrategy(id: "first", error: .first, allowsFallback: true),
                        TerminalFixtureStrategy(
                            id: "cancel",
                            error: .terminal,
                            allowsFallback: true,
                            cancelTask: cancelTask,
                            throwCancellation: !cancelTask),
                        TerminalFixtureStrategy(id: "unused", error: nil),
                    ]
                },
                resolveFallbackError: { previous, error in previous ?? error })
            return await pipeline.fetch(context: Self.context(), provider: .neuralwatt)
        }.value
        do {
            _ = try outcome.result.get()
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(outcome.attempts.map(\.strategyID) == ["first", "cancel"])
    }

    @Test(arguments: [false, true])
    func `terminal and exhausted failures emit one safe diagnostic`(allowsFallback: Bool) async throws {
        let logs = LockIsolated<[[String: String]]>([])
        let logger = CodexBarLogger(minimumLevel: .debug) { level, message, metadata in
            #expect(level == .debug)
            #expect(message == "Provider fetch failed")
            logs.setValue(logs.value + [metadata ?? [:]])
        }
        let pipeline = ProviderFetchPipeline(
            resolveStrategies: { _ in
                [TerminalFixtureStrategy(id: "fixture.api", error: .terminal, allowsFallback: allowsFallback)]
            },
            logger: logger)
        let outcome = await pipeline.fetch(context: Self.context(), provider: .neuralwatt)
        #expect(outcome.attempts.count == 1)
        let record = try #require(logs.value.first)
        #expect(logs.value.count == 1)
        #expect(record["provider"] == "neuralwatt")
        #expect(record["errorCategory"] == "api")
        #expect(record["sources"] == "fixture.api (api): failed: api")
        #expect(!record.values.joined().contains("sensitive-payload"))
    }

    @Test(arguments: [false, true])
    func `success and cancellation do not emit failure diagnostics`(cancel: Bool) async throws {
        let logs = LockIsolated(0)
        let pipeline = ProviderFetchPipeline(
            resolveStrategies: { _ in
                [TerminalFixtureStrategy(id: "fixture.api", error: nil, throwCancellation: cancel)]
            },
            logger: CodexBarLogger(minimumLevel: .debug) { _, _, _ in
                logs.setValue(logs.value + 1)
            })
        let outcome = await pipeline.fetch(context: Self.context(), provider: .neuralwatt)
        if cancel {
            #expect(throws: CancellationError.self) { try outcome.result.get() }
        } else {
            _ = try outcome.result.get()
        }
        #expect(logs.value == 0)
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

private enum TerminalFixtureFailure: LocalizedError {
    case first, terminal, resolved

    var errorDescription: String? {
        "HTTP \(self) failure: sensitive-payload"
    }
}

private struct TerminalFixtureStrategy: ProviderFetchStrategy {
    let id: String
    let error: TerminalFixtureFailure?
    var allowsFallback = false
    var cancelTask = false
    var throwCancellation = false
    var routed: LockIsolated<[TerminalFixtureFailure]>?
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_: ProviderFetchContext) async -> Bool { true }

    func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
        if self.cancelTask { withUnsafeCurrentTask { $0?.cancel() } }
        if self.throwCancellation { throw CancellationError() }
        if let error { throw error }
        return self.makeResult(
            usage: UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()),
            sourceLabel: self.id)
    }

    func shouldFallback(on error: Error, context _: ProviderFetchContext) -> Bool {
        if let routed, let failure = error as? TerminalFixtureFailure {
            routed.setValue(routed.value + [failure])
        }
        return self.allowsFallback
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
