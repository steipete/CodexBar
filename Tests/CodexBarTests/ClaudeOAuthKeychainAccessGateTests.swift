import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthKeychainAccessGateTests {
    @Test
    func blocksUntilCooldownExpires() {
        ClaudeOAuthKeychainAccessGate.resetForTesting()
        defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }

        let previousGate = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = false
        defer { KeychainAccessGate.isDisabled = previousGate }

        let now = Date(timeIntervalSince1970: 1000)
        #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now))

        ClaudeOAuthKeychainAccessGate.recordDenied(now: now)
        #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now) == false)
        #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now.addingTimeInterval(60 * 60 * 6 - 1)) == false)
        #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now.addingTimeInterval(60 * 60 * 6 + 1)))
    }

    @Test
    func persistsDeniedUntil() {
        ClaudeOAuthKeychainAccessGate.resetForTesting()
        defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }

        let previousGate = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = false
        defer { KeychainAccessGate.isDisabled = previousGate }

        let now = Date(timeIntervalSince1970: 2000)
        ClaudeOAuthKeychainAccessGate.recordDenied(now: now)

        ClaudeOAuthKeychainAccessGate.resetInMemoryForTesting()

        #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: now.addingTimeInterval(60 * 60 * 6 - 1)) == false)
    }

    @Test
    func respectsDebugDisableKeychainAccess() {
        ClaudeOAuthKeychainAccessGate.resetForTesting()
        defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }

        let previous = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = true
        defer { KeychainAccessGate.isDisabled = previous }

        #expect(ClaudeOAuthKeychainAccessGate.shouldAllowPrompt(now: Date()) == false)
    }
}
