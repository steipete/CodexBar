import Foundation
import Testing

/// Regression test for the `URLProtocol` test-stub `handler` data race fixed by backing each
/// stub's handler with a `LockIsolated` box. The stubs store their per-test handler in a static
/// that URLSession reads on a background thread while the test assigns it from another — a data
/// race under ThreadSanitizer. This hammers the real representative stub from
/// `ProviderHTTPClientTests` so the test covers the production declaration rather than a copy.
///
/// Opt-in: it hammers a static thousands of times, so it is gated behind `CODEXBAR_TSAN_STRESS` and
/// run in isolation via `CODEXBAR_TSAN_STRESS=1 swift test --sanitize=thread --filter
/// StubURLProtocolHandlerConcurrencyTests`, never in the normal parallel suite.
@Suite(.serialized)
struct StubURLProtocolHandlerConcurrencyTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEXBAR_TSAN_STRESS"] == "1"))
    func `concurrent stub handler writes and reads are race-free`() {
        let iterations = 5000
        let lanes = 4
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stub-handler.concurrency", attributes: .concurrent)
        for lane in 0..<lanes {
            group.enter()
            queue.async {
                for i in 0..<iterations {
                    if (lane + i) % 2 == 0 {
                        StubURLProtocol.handler = { _ in throw URLError(.badServerResponse) }
                    } else {
                        _ = StubURLProtocol.handler
                    }
                }
                group.leave()
            }
        }
        group.wait()
        StubURLProtocol.handler = nil
    }
}
