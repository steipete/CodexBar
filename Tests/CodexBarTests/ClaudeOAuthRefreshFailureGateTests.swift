import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthRefreshFailureGateTests {
    @Test
    func blocksIndefinitely_whenFingerprintUnchanged() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { fingerprint }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 1000)
        ClaudeOAuthRefreshFailureGate.recordAuthFailure(now: start)

        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == false)

        // Ensure we do not get unblocked unless fingerprint changes.
        fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 4)) == false)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 60 * 24)) == false)
    }

    @Test
    func unblocksImmediately_whenFingerprintChanges() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { fingerprint }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 2000)
        ClaudeOAuthRefreshFailureGate.recordAuthFailure(now: start)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == false)

        fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 2,
                persistentRefHash: "ref2"),
            credentialsFile: "file2")
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 2)) == true)
    }

    @Test
    func recordSuccess_clearsTerminalBlock() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let start = Date(timeIntervalSince1970: 5000)
        ClaudeOAuthRefreshFailureGate.recordAuthFailure(now: start)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == false)

        ClaudeOAuthRefreshFailureGate.recordSuccess()
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == true)
    }
}
