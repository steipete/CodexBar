import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct CodexRemoteCostContextCacheTests {
    private actor Reader {
        private(set) var calls = 0
        private(set) var ranOnMainThread = false
        private var pending: [(CodexRemoteCostContextInput, CheckedContinuation<CodexRemoteCostContext, any Error>)] =
            []

        func read(_ input: CodexRemoteCostContextInput, onMainThread: Bool) async throws -> CodexRemoteCostContext {
            self.calls += 1
            self.ranOnMainThread = self.ranOnMainThread || onMainThread
            return try await withCheckedThrowingContinuation { self.pending.append((input, $0)) }
        }

        func finish(revision: String = "v1") {
            let work = self.pending
            self.pending.removeAll()
            for (input, continuation) in work {
                continuation.resume(returning: CodexRemoteCostContextCacheTests.context(input, revision: revision))
            }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_789_560_000)
        private var observed = false
        var now: Date {
            self.lock.withLock { self.date }
        }

        var didObserve: Bool {
            self.lock.withLock { self.observed }
        }

        func advance() { self.lock.withLock { self.date.addTimeInterval(6) } }
        func observe() { self.lock.withLock { self.observed = true } }
    }

    private func input(host: String = "Synthetic", days: Int = 7) -> CodexRemoteCostContextInput {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return CodexRemoteCostContextInput(
            source: .init(host: host),
            localCodexHome: URL(fileURLWithPath: "/synthetic/local"),
            localScope: "codex:ambient",
            historyDays: days,
            calendar: calendar,
            pricingCacheRoot: nil,
            localCostCacheRoot: nil,
            sshEnvironment: [:],
            now: Date(timeIntervalSince1970: 1_789_560_000))
    }

    private nonisolated static func context(
        _ input: CodexRemoteCostContextInput,
        revision: String) -> CodexRemoteCostContext
    {
        CodexRemoteCostContext(
            source: input.source,
            localCodexHome: input.localCodexHome,
            localScope: input.localScope,
            historyDays: input.historyDays,
            calendar: input.calendar,
            day: input.calendar.startOfDay(for: input.now),
            pricingRevision: revision,
            sshRevision: revision,
            pricingCacheRoot: input.pricingCacheRoot,
            localCostCacheRoot: input.localCostCacheRoot,
            now: input.now)
    }

    private func cache(_ reader: Reader, clock: Clock = Clock()) -> CodexRemoteCostContextCache {
        CodexRemoteCostContextCache(
            now: { clock.now },
            reader: { input in
                try await reader.read(input, onMainThread: Self.captureReaderThread())
            })
    }

    private nonisolated static func captureReaderThread() -> Bool {
        Thread.isMainThread
    }

    private func waitFor(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Controlled context operation did not reach the expected state")
    }

    @Test
    func `render lookups coalesce off actor IO and leave the main actor responsive`() async throws {
        let reader = Reader()
        let cache = self.cache(reader)
        let input = self.input()
        for _ in 0..<500 {
            #expect(cache.cached(for: input) == nil)
        }
        try await self.waitFor { await reader.calls == 1 }
        let heartbeat = Task { @MainActor in true }
        #expect(await heartbeat.value)
        #expect(await reader.calls == 1)
        #expect(await reader.ranOnMainThread == false)
        await reader.finish()
        try await self.waitFor { cache.value != nil }
        for _ in 0..<500 {
            #expect(cache.cached(for: input)?.source == input.source)
        }
        #expect(await reader.calls == 1)
    }

    @Test
    func `unchanged revalidation restores the retained result and notifies observers`() async throws {
        let reader = Reader()
        let clock = Clock()
        let cache = self.cache(reader, clock: clock)
        let input = self.input()
        #expect(cache.cached(for: input) == nil)
        try await self.waitFor { await reader.calls == 1 }
        await reader.finish()
        try await self.waitFor { cache.value != nil }
        let original = cache.value
        withObservationTracking { _ = cache.revision } onChange: { clock.observe() }
        clock.advance()
        #expect(cache.cached(for: input) == nil)
        #expect(cache.value == original)
        try await self.waitFor { await reader.calls == 2 }
        await reader.finish()
        try await self.waitFor { clock.didObserve }
        #expect(cache.cached(for: input) == original)
        #expect(await reader.calls == 2)
    }

    @Test
    func `a changed input rejects late work and verifies the latest input once`() async throws {
        let reader = Reader()
        let cache = self.cache(reader)
        #expect(cache.cached(for: self.input()) == nil)
        try await self.waitFor { await reader.calls == 1 }
        let changed = self.input(host: "Other", days: 30)
        #expect(cache.select(changed))
        for _ in 0..<50 {
            #expect(cache.cached(for: changed) == nil)
        }
        await reader.finish()
        try await self.waitFor { await reader.calls == 2 }
        #expect(cache.value == nil)
        await reader.finish(revision: "v2")
        try await self.waitFor { cache.value != nil }
        #expect(cache.cached(for: changed)?.source.host == "Other")
        #expect(cache.cached(for: changed)?.historyDays == 30)
        #expect(cache.cached(for: changed)?.sshRevision == "v2")
    }

    @Test(arguments: [false, true])
    func `manual publication waits for a fresh post scan revision`(changed: Bool) async throws {
        let reader = Reader()
        let cache = self.cache(reader)
        let input = self.input()
        let store = CodexRemoteCostStore(
            defaults: InMemoryUserDefaults(),
            loader: { request, _ in
                CodexCombinedCostResult(
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: 550,
                        sessionCostUSD: 1.83,
                        last30DaysTokens: 715,
                        last30DaysCostUSD: 2.379,
                        daily: [],
                        updatedAt: request.now),
                    source: request.source,
                    capturedFrom: request.now,
                    capturedTo: request.now,
                    notices: [])
            },
            cleanup: {})
        store.enabled = true
        store.host = input.source.host
        store.grantConsent()
        store.refresh(
            contextProvider: { try await cache.fresh(for: input) },
            currentContext: { try await cache.fresh(for: input) })
        try await self.waitFor { await reader.calls == 1 }
        #expect(store.isCheckingConfiguration)
        #expect(store.result == nil)
        await reader.finish()
        try await self.waitFor { await reader.calls == 2 }
        #expect(store.isRunning)
        #expect(store.isCheckingConfiguration)
        #expect(store.result == nil)
        await reader.finish(revision: changed ? "v2" : "v1")
        try await self.waitFor { !store.isRunning }
        if changed {
            #expect(store.result == nil)
            #expect(store.needsRefresh)
        } else {
            #expect(store.result?.snapshot.last30DaysTokens == 715)
            #expect(store.result?.snapshot.last30DaysCostUSD == 2.379)
        }
    }

    @Test
    func `cancellation drains pending context work before finishing without starting SSH`() async throws {
        let reader = Reader()
        let cache = self.cache(reader)
        let input = self.input()
        let store = CodexRemoteCostStore(
            defaults: InMemoryUserDefaults(),
            loader: { _, _ in
                Issue.record("Cancelled preflight must not call the SSH loader")
                throw CancellationError()
            },
            cleanup: {})
        store.enabled = true
        store.grantConsent()
        store.refresh(
            contextProvider: { try await cache.fresh(for: input) },
            currentContext: { try await cache.fresh(for: input) })
        try await self.waitFor { await reader.calls == 1 }
        let cancellation = Task { await store.cancel() }
        await Task.yield()
        #expect(store.isRunning)
        await reader.finish()
        await cancellation.value
        #expect(!store.isRunning)
        #expect(store.result == nil)
        #expect(await reader.calls == 1)
    }
}
