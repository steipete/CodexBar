import Foundation
import Testing
@testable import CodexBarCore

struct RPCRequestTimeoutTests {
    private enum Failure: Error, Equatable {
        case timeout
        case stdoutClosed
        case requestFailed
    }

    @Test
    func `timeout stays authoritative when teardown closes stdout`() async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let stopped = DispatchSemaphore(value: 0)
        do {
            let _: Int = try await RPCRequestTimeout.run(
                seconds: 0.01,
                timeoutError: Failure.timeout,
                onTimeout: {
                    continuation.finish()
                    // Force the competing EOF to arrive before timeout teardown returns.
                    #expect(stopped.wait(timeout: .now() + 1) == .success)
                }, operation: {
                    for await _ in stream {}
                    stopped.signal()
                    throw Failure.stdoutClosed
                })
            Issue.record("Expected timeout")
        } catch {
            #expect(error as? Failure == .timeout)
        }
    }

    @Test
    func `successful requests do not invoke timeout teardown`() async throws {
        let result = try await RPCRequestTimeout.run(
            seconds: 60,
            timeoutError: Failure.timeout,
            onTimeout: { Issue.record("Unexpected timeout teardown") },
            operation: {
                42
            })

        #expect(result == 42)
    }

    @Test
    func `request errors retain their original classification`() async {
        do {
            let _: Int = try await RPCRequestTimeout.run(
                seconds: 60,
                timeoutError: Failure.timeout,
                onTimeout: { Issue.record("Unexpected timeout teardown") },
                operation: {
                    throw Failure.requestFailed
                })
            Issue.record("Expected request error")
        } catch {
            #expect(error as? Failure == .requestFailed)
        }
    }

    @Test
    func `cancellation drains the request without timeout teardown`() async {
        let request = Task {
            try await RPCRequestTimeout.run(
                seconds: 60,
                timeoutError: Failure.timeout,
                onTimeout: { Issue.record("Unexpected timeout teardown") },
                operation: {
                    try await Task.sleep(for: .seconds(60))
                    return 42
                })
        }
        request.cancel()

        do {
            _ = try await request.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
