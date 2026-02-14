import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthKeychainAccessGateTests {
    @Test
    func blocksUntilCooldownExpires() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            let store = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
            ClaudeOAuthKeychainAccessGate.withDeniedUntilStoreOverrideForTesting(store) {
                let now = Date(timeIntervalSince1970: 1000)
                #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now))

                ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
                #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now) == false)
                #expect(
                    ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now.addingTimeInterval(60 * 60 * 6 - 1))
                        == false)
                #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now.addingTimeInterval(60 * 60 * 6 + 1)))
            }
        }
    }

    @Test
    func persistsDeniedUntil() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthKeychainAccessGate.resetForTesting()
            defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }

            let now = Date(timeIntervalSince1970: 2000)
            ClaudeOAuthKeychainAccessGate.recordDenied(now: now)

            ClaudeOAuthKeychainAccessGate.resetInMemoryForTesting()

            #expect(
                ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now.addingTimeInterval(60 * 60 * 6 - 1)) == false)
        }
    }

    @Test
    func respectsDebugDisableKeychainAccess() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            ClaudeOAuthKeychainAccessGate.resetForTesting()
            defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }
            #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: Date()) == false)
        }
    }

    @Test
    func clearDeniedAllowsImmediateRetry() {
        KeychainAccessGate.withTaskOverrideForTesting(false) {
            ClaudeOAuthKeychainAccessGate.resetForTesting()
            defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }

            let store = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
            ClaudeOAuthKeychainAccessGate.withDeniedUntilStoreOverrideForTesting(store) {
                let now = Date(timeIntervalSince1970: 3000)
                ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
                #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now) == false)

                #expect(ClaudeOAuthKeychainAccessGate.clearDenied(now: now))
                #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now))
                #expect(ClaudeOAuthKeychainAccessGate.clearDenied(now: now) == false)
            }
        }
    }
}
