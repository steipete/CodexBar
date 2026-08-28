import Foundation
import Testing
@testable import CodexBar

struct UsageStoreTimeoutTests {
    private final class ProbeGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func wait() async {
            await withCheckedContinuation { continuation in
                let shouldResume = self.lock.withLock {
                    guard !self.released else { return true }
                    self.continuation = continuation
                    return false
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }

        func release() {
            let continuation = self.lock.withLock {
                self.released = true
                let continuation = self.continuation
                self.continuation = nil
                return continuation
            }
            continuation?.resume()
        }

        var isReleased: Bool {
            self.lock.withLock { self.released }
        }
    }

    @Test
    func `timeout does not wait for a cancellation ignoring probe`() async {
        let gate = ProbeGate()
        defer { gate.release() }

        let result = await UsageStore.runWithTimeout(seconds: 0.03) {
            await gate.wait()
            return "late result"
        }

        #expect(result == "Probe timed out after 0s")
        #expect(!gate.isReleased)
    }

    @Test
    func `completed probe wins timeout race`() async {
        let result = await UsageStore.runWithTimeout(seconds: 10) {
            "probe result"
        }

        #expect(result == "probe result")
    }
}
