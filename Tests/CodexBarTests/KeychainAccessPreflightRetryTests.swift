import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
import SweetCookieKit

@Suite(.serialized)
struct KeychainAccessPreflightRetryTests {
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private let outcomes: [KeychainAccessPreflight.Outcome]
        private var attempts = 0
        private var delays = 0

        init(_ outcomes: [KeychainAccessPreflight.Outcome]) {
            self.outcomes = outcomes
        }

        func check(_: String, _: String?) -> KeychainAccessPreflight.Outcome {
            self.lock.withLock {
                let outcome = self.outcomes[min(self.attempts, self.outcomes.count - 1)]
                self.attempts += 1
                return outcome
            }
        }

        func delay() {
            self.lock.withLock { self.delays += 1 }
        }

        var counts: (attempts: Int, delays: Int) {
            self.lock.withLock { (self.attempts, self.delays) }
        }
    }

    private func withScript<T>(_ script: Script, operation: () -> T) -> T {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting(
                script.check,
                retryDelay: script.delay,
                operation: operation)
        }
    }

    @Test
    func `temporarily unavailable outcome is retried and recovers to allowed`() {
        let script = Script([.temporarilyUnavailable, .temporarilyUnavailable, .allowed])
        let outcome = self.withScript(script) {
            KeychainAccessPreflight.checkGenericPassword(service: "test-service", account: nil)
        }

        #expect(outcome == .allowed)
        #expect(script.counts.attempts == 3)
        #expect(script.counts.delays == 2)
    }

    @Test
    func `persistently temporarily unavailable outcome gives up after a bounded number of attempts`() {
        let script = Script([.temporarilyUnavailable])
        let outcome = self.withScript(script) {
            KeychainAccessPreflight.checkGenericPassword(service: "test-service", account: nil)
        }

        #expect(outcome == .temporarilyUnavailable)
        #expect(script.counts.attempts == 3)
        #expect(script.counts.delays == 2)
    }

    @Test(arguments: [
        KeychainAccessPreflight.Outcome.allowed,
        .interactionRequired,
        .notFound,
        .failure(-25293),
    ], [false, true])
    func `stable outcomes stop retries immediately`(_ stable: KeychainAccessPreflight.Outcome, _ afterTransient: Bool) {
        let script = Script(afterTransient ? [.temporarilyUnavailable, stable] : [stable])
        let outcome = self.withScript(script) {
            KeychainAccessPreflight.checkGenericPassword(service: "test-service", account: nil)
        }

        #expect(outcome == stable)
        #expect(script.counts.attempts == (afterTransient ? 2 : 1))
        #expect(script.counts.delays == (afterTransient ? 1 : 0))
    }

    @Test(arguments: [KeychainAccessPreflight.Outcome.allowed, .temporarilyUnavailable])
    func `memo caches the final retry outcome only within its operation`(_ final: KeychainAccessPreflight.Outcome) {
        let script = Script([.temporarilyUnavailable, .temporarilyUnavailable, final])
        self.withScript(script) {
            KeychainAccessPreflight.withMemoizedGenericPasswordChecks {
                for _ in 0..<2 {
                    #expect(KeychainAccessPreflight
                        .checkGenericPassword(service: "test-service", account: nil) == final)
                }
            }
            #expect(script.counts.attempts == 3)
            #expect(script.counts.delays == 2)

            KeychainAccessPreflight.withMemoizedGenericPasswordChecks {
                #expect(KeychainAccessPreflight.checkGenericPassword(service: "test-service", account: nil) == final)
            }
        }

        #expect(script.counts.attempts == (final == .allowed ? 4 : 6))
        #expect(script.counts.delays == (final == .allowed ? 2 : 4))
    }

    @Test(arguments: [
        KeychainAccessPreflight.Outcome.allowed,
        .temporarilyUnavailable,
        .interactionRequired,
    ])
    func `background browser gate recovers only after explicit access is allowed`(_ final: KeychainAccessPreflight
        .Outcome)
    {
        BrowserCookieAccessGate.resetForTesting()
        defer { BrowserCookieAccessGate.resetForTesting() }
        let script = Script([.temporarilyUnavailable, final])

        let shouldRead = self.withScript(script) {
            ProviderInteractionContext.$current.withValue(.background) {
                BrowserCookieAccessGate.shouldAttempt(.chrome)
            }
        }

        #expect(shouldRead == (final == .allowed))
        #expect(script.counts.attempts == (final == .temporarilyUnavailable ? 3 : 2))
        #expect(script.counts.delays == (final == .temporarilyUnavailable ? 2 : 1))
        let disallowsInteraction = ProviderInteractionContext.$current.withValue(.background) {
            BrowserCookieAccessGate.withRecordReadInteractionPolicy {
                BrowserCookieKeychainAccessGate.isUserInteractionDisallowed
            }
        }
        #expect(disallowsInteraction)
    }
}
#endif
