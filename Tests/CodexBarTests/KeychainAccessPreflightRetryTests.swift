import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
/// Covers `KeychainAccessPreflight`'s retry of a `.temporarilyUnavailable` outcome. Unlike
/// `.interactionRequired`/`.rejected`, `.temporarilyUnavailable` documents itself as possibly differing
/// on retry (a locked keychain, a busy keychain daemon, or a momentary ACL-inspection race), so a
/// background refresh must not give up on the first inconclusive read.
struct KeychainAccessPreflightRetryTests {
    private final class CallCounter: @unchecked Sendable {
        var calls = 0
    }

    private func evaluate(_ check: @escaping (String, String?) -> KeychainAccessPreflight.Outcome)
        -> KeychainAccessPreflight.Outcome
    {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(check) {
                KeychainAccessPreflight.checkGenericPassword(service: "test-service", account: nil)
            }
        }
    }

    @Test
    func `temporarily unavailable outcome is retried and recovers to allowed`() {
        let counter = CallCounter()

        let outcome = self.evaluate { _, _ in
            counter.calls += 1
            return counter.calls < 3 ? .temporarilyUnavailable : .allowed
        }

        #expect(outcome == .allowed)
        #expect(counter.calls == 3)
    }

    @Test
    func `persistently temporarily unavailable outcome gives up after a bounded number of attempts`() {
        let counter = CallCounter()

        let outcome = self.evaluate { _, _ in
            counter.calls += 1
            return .temporarilyUnavailable
        }

        #expect(outcome == .temporarilyUnavailable)
        #expect(counter.calls == 3)
    }

    @Test
    func `stable interaction required outcome is not retried`() {
        let counter = CallCounter()

        let outcome = self.evaluate { _, _ in
            counter.calls += 1
            return .interactionRequired
        }

        #expect(outcome == .interactionRequired)
        #expect(counter.calls == 1)
    }

    @Test
    func `allowed outcome on the first attempt is not retried`() {
        let counter = CallCounter()

        let outcome = self.evaluate { _, _ in
            counter.calls += 1
            return .allowed
        }

        #expect(outcome == .allowed)
        #expect(counter.calls == 1)
    }
}
#endif
