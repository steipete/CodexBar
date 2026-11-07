import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The fixture server's async accept loop polls synchronously until stopped.
/// Its tasks and connection handlers must not occupy the cooperative pool.
@available(macOS 15.0, *)
final class CancellationFixtureExecutor: TaskExecutor {
    static let shared = CancellationFixtureExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        Thread.detachNewThread {
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}

final class CancellationTestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var waiters: [String: [AsyncStream<Void>.Continuation]] = [:]

    func mark(_ flag: String) {
        let waiters = self.lock.withLock {
            self.counts[flag, default: 0] += 1
            return self.waiters.removeValue(forKey: flag) ?? []
        }
        for waiter in waiters {
            waiter.yield(())
            waiter.finish()
        }
    }

    func count(_ flag: String) -> Int { self.lock.withLock { self.counts[flag, default: 0] } }
    func contains(_ flag: String) -> Bool { self.count(flag) > 0 }

    func waitFor(_ flag: String) async -> Bool {
        let (events, event) = AsyncStream<Void>.makeStream()
        defer { event.finish() }
        let ready = self.lock.withLock {
            if self.counts[flag, default: 0] > 0 { return true }
            self.waiters[flag, default: []].append(event)
            return false
        }
        if ready { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in events {
                    return true
                }
                return false
            }
            // A hang guard, not the mechanism that orders fixture events.
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let observed = await group.next() ?? false
            group.cancelAll()
            return observed
        }
    }
}

/// Blocking cancellation fixtures share one lane even when the full suite runs in parallel.
@Suite(.serialized)
struct BoundedTaskJoinTests {
    @Test func `timeout is delivered while source cancellation is blocked`() async {
        let state = CancellationTestProgress()
        let (deadlines, deadline) = AsyncStream<Void>.makeStream()
        let (pending, finished) = AsyncStream<Void>.makeStream()
        let operation = Task { for await _ in pending {} }
        let release = DispatchSemaphore(value: 0)
        defer {
            deadline.finish()
            release.signal()
            finished.finish()
        }
        let source = Task<Int, Error> {
            try await withTaskCancellationHandler {
                state.mark("started")
                await operation.value
                try Task.checkCancellation()
                return 1
            } onCancel: {
                state.mark("cancelling")
                _ = release.wait(timeout: .now() + 30)
            }
        }
        defer {
            release.signal()
            source.cancel()
        }
        guard await state.waitFor("started") else {
            Issue.record("Source did not start")
            return
        }
        let waiter = Task {
            await BoundedTaskJoinTiming.$sleep.withValue({ _ in
                state.mark("registered")
                for await _ in deadlines {}
                try Task.checkCancellation()
            }) {
                let outcome = await BoundedTaskJoin(sourceTask: source).value(joinGrace: .seconds(30))
                if case .timedOut = outcome { state.mark("timedOut") }
            }
        }
        #expect(await state.waitFor("registered"))
        deadline.finish()
        #expect(await state.waitFor("cancelling"))
        #expect(await state.waitFor("timedOut"))
        release.signal()
        finished.finish()
        await waiter.value
        _ = await source.result
    }

    @Test func `pre-cancelled caller observes cancellation while source cancellation is blocked`() async {
        let state = CancellationTestProgress()
        let release = DispatchSemaphore(value: 0)
        let (pending, finished) = AsyncStream<Void>.makeStream()
        let operation = Task { for await _ in pending {} }
        let (starts, start) = AsyncStream<Void>.makeStream()
        let begin = Task { for await _ in starts {} }
        defer {
            start.finish()
            release.signal()
            finished.finish()
        }
        let source = Task<Int, Error> {
            try await withTaskCancellationHandler {
                state.mark("started")
                await operation.value
                try Task.checkCancellation()
                return 1
            } onCancel: {
                state.mark("cancelling")
                _ = release.wait(timeout: .now() + 30)
            }
        }
        defer {
            release.signal()
            source.cancel()
        }
        guard await state.waitFor("started") else {
            Issue.record("Source did not start")
            return
        }
        let caller = Task {
            await begin.value
            let outcome = await BoundedTaskJoin(sourceTask: source).value(joinGrace: nil)
            if case let .failure(error) = outcome, error is CancellationError { state.mark("cancelled") }
        }
        caller.cancel()
        start.finish()
        #expect(await state.waitFor("cancelling"))
        #expect(await state.waitFor("cancelled"))
        release.signal()
        finished.finish()
        await caller.value
        _ = await source.result
    }

    @Test func `registered caller cancellation returns while source cancellation is blocked`() async {
        let state = CancellationTestProgress()
        let release = DispatchSemaphore(value: 0)
        let (pending, finished) = AsyncStream<Void>.makeStream()
        let operation = Task { for await _ in pending {} }
        let source = Task<Int, Error> {
            try await withTaskCancellationHandler {
                state.mark("started")
                await operation.value
                try Task.checkCancellation()
                return 1
            } onCancel: {
                state.mark("cancelling")
                _ = release.wait(timeout: .now() + 30)
            }
        }
        defer {
            release.signal()
            finished.finish()
            source.cancel()
        }
        guard await state.waitFor("started") else {
            Issue.record("Source did not start")
            return
        }
        let waiter = Task {
            await BoundedTaskJoinTiming.$sleep.withValue({ duration in
                state.mark("registered")
                try await Task.sleep(for: duration)
            }) {
                let outcome = await BoundedTaskJoin(sourceTask: source).value(joinGrace: .seconds(30))
                if case let .failure(error) = outcome, error is CancellationError { state.mark("cancelled") }
            }
        }
        guard await state.waitFor("registered") else {
            Issue.record("Join did not register")
            return
        }
        Thread.detachNewThread {
            waiter.cancel()
            state.mark("cancelReturned")
        }
        #expect(await state.waitFor("cancelling"))
        #expect(await state.waitFor("cancelled"))
        #expect(await state.waitFor("cancelReturned"))
        release.signal()
        finished.finish()
        await waiter.value
        _ = await source.result
    }

    @Test func `successful and failed source outcomes are preserved`() async {
        enum TestError: Error { case expected }
        let success = Task<Int, Error> { 42 }
        if case let .value(value) = await BoundedTaskJoin(sourceTask: success).value(joinGrace: .seconds(3)) {
            #expect(value == 42)
        } else {
            Issue.record("Expected source value")
        }
        let failure = Task<Int, Error> { throw TestError.expected }
        if case let .failure(error) = await BoundedTaskJoin(sourceTask: failure).value(joinGrace: .seconds(3)) {
            #expect(error is TestError)
        } else {
            Issue.record("Expected source failure")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `fetch cancellation returns while transport cancellation is blocked`() async throws {
        let progress = CancellationTestProgress()
        let release = DispatchSemaphore(value: 0)
        let (pending, finished) = AsyncStream<Void>.makeStream()
        let operation = Task { for await _ in pending {} }
        defer { finished.finish() }
        let manifest = try ProviderPluginRuntime(
            source: """
            defineProvider({
              id: 'blocking-cancellation-fixture', name: 'Cancellation fixture',
              endpoints: ['https://example.test'], settings: [],
              async fetchUsage() { return {empty: true}; }
            });
            """,
            resourceBundle: CodexBarCoreResources.bundle,
            transport: ProviderHTTPTransportHandler { _ in throw CancellationError() },
            allowsDynamicID: true,
            engine: .quickJS).manifest
        let request = try ProviderPluginHTTPResponse.Request(
            rawURL: "https://example.test/primary",
            options: [:],
            method: "GET",
            settings: [:],
            secrets: [:],
            manifest: manifest,
            enforcesUserResponsePolicy: true)
        let fetch = Task {
            do {
                try await BoundedTaskJoinTiming.$sleep.withValue({ duration in
                    progress.mark("registered")
                    try await Task.sleep(for: duration)
                }) {
                    _ = try await ProviderPluginHTTPResponse.fetch(
                        request,
                        transport: ProviderHTTPTransportHandler { _ in
                            try await withTaskCancellationHandler {
                                progress.mark("started")
                                await operation.value
                                try Task.checkCancellation()
                                throw CancellationError()
                            } onCancel: {
                                progress.mark("cancelling")
                                _ = release.wait(timeout: .now() + 30)
                            }
                        },
                        wantsJSON: false,
                        responseSizeLimit: 1024,
                        enforcesUserResponsePolicy: true,
                        rejectsNonSuccessResponses: false)
                }
                progress.mark("unexpectedSuccess")
            } catch {
                if error is CancellationError { progress.mark("cancelled") }
                progress.mark("finished")
            }
        }
        defer {
            release.signal()
            finished.finish()
            fetch.cancel()
        }
        guard await progress.waitFor("started"), await progress.waitFor("registered") else {
            Issue.record("Transport or request join did not start")
            return
        }
        Thread.detachNewThread {
            fetch.cancel()
            progress.mark("cancelReturned")
        }
        #expect(await progress.waitFor("cancelling"))
        #expect(await progress.waitFor("cancelReturned"))
        #expect(await progress.waitFor("finished"))
        #expect(progress.contains("cancelled"))
        #expect(!progress.contains("unexpectedSuccess"))
        release.signal()
        finished.finish()
        await fetch.value
    }
}
