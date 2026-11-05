import Foundation
import Testing
@testable import CodexBarCore

private final class JoinTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var flags: Set<String> = []

    func mark(_ flag: String) {
        self.lock.withLock { _ = self.flags.insert(flag) }
    }

    func contains(_ flag: String) -> Bool {
        self.lock.withLock { self.flags.contains(flag) }
    }
}

private func waitForFlag(_ flag: String, in state: JoinTestState) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !state.contains(flag), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return state.contains(flag)
}

struct BoundedTaskJoinTests {
    @Test func `timeout is delivered while source cancellation is blocked`() async {
        let state = JoinTestState()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let source = Task<Int, Error> {
            try await withTaskCancellationHandler {
                state.mark("started")
                try await Task.sleep(for: .seconds(30))
                return 1
            } onCancel: {
                state.mark("cancelling")
                _ = release.wait(timeout: .now() + 10)
            }
        }
        defer {
            release.signal()
            source.cancel()
        }
        guard await waitForFlag("started", in: state) else {
            Issue.record("Source did not start")
            return
        }
        let waiter = Task {
            let outcome = await BoundedTaskJoin(sourceTask: source).value(joinGrace: .milliseconds(50))
            if case .timedOut = outcome { state.mark("timedOut") }
        }
        #expect(await waitForFlag("cancelling", in: state))
        #expect(await waitForFlag("timedOut", in: state))
        release.signal()
        await waiter.value
        _ = await source.result
    }

    @Test func `pre-cancelled caller observes cancellation while source cancellation is blocked`() async {
        let state = JoinTestState()
        let release = DispatchSemaphore(value: 0)
        let (starts, start) = AsyncStream<Void>.makeStream()
        let begin = Task { for await _ in starts {} }
        defer {
            start.finish()
            release.signal()
        }
        let source = Task<Int, Error> {
            try await withTaskCancellationHandler {
                state.mark("started")
                try await Task.sleep(for: .seconds(30))
                return 1
            } onCancel: {
                state.mark("cancelling")
                _ = release.wait(timeout: .now() + 10)
            }
        }
        defer {
            release.signal()
            source.cancel()
        }
        guard await waitForFlag("started", in: state) else {
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
        #expect(await waitForFlag("cancelling", in: state))
        #expect(await waitForFlag("cancelled", in: state))
        release.signal()
        await caller.value
        _ = await source.result
    }

    @Test func `registered caller cancellation returns while source cancellation is blocked`() async {
        let state = JoinTestState()
        let release = DispatchSemaphore(value: 0)
        let source = Task<Int, Error> {
            try await withTaskCancellationHandler {
                state.mark("started")
                try await Task.sleep(for: .seconds(30))
                return 1
            } onCancel: {
                state.mark("cancelling")
                _ = release.wait(timeout: .now() + 10)
            }
        }
        defer {
            release.signal()
            source.cancel()
        }
        guard await waitForFlag("started", in: state) else {
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
        guard await waitForFlag("registered", in: state) else {
            Issue.record("Join did not register")
            return
        }
        DispatchQueue.global().async {
            waiter.cancel()
            state.mark("cancelReturned")
        }
        #expect(await waitForFlag("cancelling", in: state))
        #expect(await waitForFlag("cancelled", in: state))
        #expect(await waitForFlag("cancelReturned", in: state))
        release.signal()
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
}
