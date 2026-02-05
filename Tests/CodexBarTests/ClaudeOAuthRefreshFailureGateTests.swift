import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthRefreshFailureGateTests {
    @Test
    func blocksDuringCooldown_whenFingerprintUnchanged() {
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

        // Ensure we do not get unblocked unless either cooldown expires or fingerprint changes.
        fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 4)) == false)
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
    func exponentialBackoff_increasesAfterCooldownExpires() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { nil }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 3000)

        // Failure #1 => 5 minutes
        ClaudeOAuthRefreshFailureGate.recordAuthFailure(now: start)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 4)) == false)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 5 + 1)) == true)

        // Failure #2 => 10 minutes
        ClaudeOAuthRefreshFailureGate.recordAuthFailure(now: start.addingTimeInterval(60 * 5 + 2))
        #expect(ClaudeOAuthRefreshFailureGate
            .shouldAttempt(now: start.addingTimeInterval(60 * 5 + 2 + 60 * 9)) == false)
        #expect(ClaudeOAuthRefreshFailureGate
            .shouldAttempt(now: start.addingTimeInterval(60 * 5 + 2 + 60 * 10 + 1)) == true)
    }

    @Test
    func backoff_capsAtSixHours() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { nil }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 4000)
        var now = start

        // Increase failures enough to exceed the cap; we simulate "cooldown expires then fail again"
        // by advancing time past the current cooldown before recording the next failure.
        for failureIndex in 1...12 {
            ClaudeOAuthRefreshFailureGate.recordAuthFailure(now: now)

            let expectedCooldown = min(
                TimeInterval(60 * 5) * pow(2.0, Double(failureIndex - 1)),
                TimeInterval(60 * 60 * 6))
            #expect(ClaudeOAuthRefreshFailureGate
                .shouldAttempt(now: now.addingTimeInterval(expectedCooldown - 1)) == false)
            #expect(ClaudeOAuthRefreshFailureGate
                .shouldAttempt(now: now.addingTimeInterval(expectedCooldown + 1)) == true)

            // Then advance time to allow another attempt.
            now = now.addingTimeInterval(expectedCooldown + 2)
        }
    }

    @Test
    func recordSuccess_clearsBackoff() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let start = Date(timeIntervalSince1970: 5000)
        ClaudeOAuthRefreshFailureGate.recordAuthFailure(now: start)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == false)

        ClaudeOAuthRefreshFailureGate.recordSuccess()
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == true)
    }
}
