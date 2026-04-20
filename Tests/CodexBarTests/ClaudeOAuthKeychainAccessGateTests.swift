import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthKeychainAccessGateTests {
    @Test
    func `blocks until cooldown expires`() {
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
    func `persists denied until`() {
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
    func `respects debug disable keychain access`() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            ClaudeOAuthKeychainAccessGate.resetForTesting()
            defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }
            #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: Date()) == false)
        }
    }

    @Test
    func `process keeps keychain access disabled despite false global override`() {
        guard ProcessInfo.processInfo.environment["CODEXBAR_ALLOW_TEST_KEYCHAIN_ACCESS"] != "1" else { return }
        KeychainAccessGate.resetOverrideForTesting()
        defer { KeychainAccessGate.resetOverrideForTesting() }

        KeychainAccessGate.isDisabled = false

        #expect(KeychainAccessGate.isDisabled)
    }

    @Test
    func `clear denied allows immediate retry`() {
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
