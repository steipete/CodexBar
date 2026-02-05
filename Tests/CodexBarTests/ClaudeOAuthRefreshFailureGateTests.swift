import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
@Suite(.serialized)
struct ClaudeOAuthRefreshFailureGateTests {
    private let legacyBlockedUntilKey = "claudeOAuthRefreshBackoffBlockedUntilV1"
    private let legacyFailureCountKey = "claudeOAuthRefreshBackoffFailureCountV1"
    private let legacyFingerprintKey = "claudeOAuthRefreshBackoffFingerprintV2"
    private let terminalBlockedKey = "claudeOAuthRefreshTerminalBlockedV1"
    private let transientBlockedUntilKey = "claudeOAuthRefreshTransientBlockedUntilV1"
    private let transientFailureCountKey = "claudeOAuthRefreshTransientFailureCountV1"

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
        ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: start)

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
    func migratesLegacyBlockedUntilInPast_doesNotBlockAndClearsKey() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let now = Date(timeIntervalSince1970: 10000)
        UserDefaults.standard.set(now.addingTimeInterval(-60).timeIntervalSince1970, forKey: self.legacyBlockedUntilKey)
        UserDefaults.standard.set(0, forKey: self.legacyFailureCountKey)
        UserDefaults.standard.removeObject(forKey: self.terminalBlockedKey)

        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: now) == true)
        #expect(UserDefaults.standard.object(forKey: self.legacyBlockedUntilKey) == nil)
    }

    @Test
    func migratesLegacyBackoffToTransientBackoff_doesNotSetTerminalBlock() throws {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let now = Date(timeIntervalSince1970: 20000)

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { fingerprint }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let legacyBlockedUntil = now.addingTimeInterval(60 * 10)
        UserDefaults.standard.set(2, forKey: self.legacyFailureCountKey)
        UserDefaults.standard.removeObject(forKey: self.terminalBlockedKey)
        UserDefaults.standard.set(legacyBlockedUntil.timeIntervalSince1970, forKey: self.legacyBlockedUntilKey)
        let data = try JSONEncoder().encode(fingerprint)
        UserDefaults.standard.set(data, forKey: self.legacyFingerprintKey)

        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: now) == false)
        #expect(UserDefaults.standard.bool(forKey: self.terminalBlockedKey) == false)
        #expect(UserDefaults.standard.object(forKey: self.legacyBlockedUntilKey) == nil)
        #expect(UserDefaults.standard.object(forKey: self.transientBlockedUntilKey) != nil)
        #expect(UserDefaults.standard.integer(forKey: self.transientFailureCountKey) == 2)
    }

    @Test
    func unblocksWhenFingerprintBecomesAvailable_afterBeingUnknownAtFailure() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var fingerprint: ClaudeOAuthRefreshFailureGate.AuthFingerprint?
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { fingerprint }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 25000)
        ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: start)

        // Still blocked while fingerprint is unavailable.
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(20)) == false)

        // Once fingerprint becomes available, the sentinel differs and we unblock.
        fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(40)) == true)
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
        ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: start)
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
    func throttlesFingerprintRecheck_whileTerminalBlocked() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var calls = 0
        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting {
            calls += 1
            return fingerprint
        }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 30000)
        ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: start)
        #expect(calls == 1)

        // First blocked check is throttled (we already captured fingerprint at failure).
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(1)) == false)
        #expect(calls == 1)

        // After the throttle window, it should re-read.
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(20)) == false)
        #expect(calls == 2)

        // Subsequent checks within the throttle window should not re-read again.
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(21)) == false)
        #expect(calls == 2)
    }

    @Test
    func terminalBlockIsMonotonic_whenTransientFailureIsRecorded() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { fingerprint }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 35000)
        ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: start)
        ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: start.addingTimeInterval(1))

        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(20)) == false)
        #expect(UserDefaults.standard.bool(forKey: self.terminalBlockedKey) == true)
        #expect(UserDefaults.standard.object(forKey: self.transientBlockedUntilKey) == nil)
    }

    @Test
    func recordSuccess_clearsTerminalBlock() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { fingerprint }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 5000)
        ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: start)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == false)

        ClaudeOAuthRefreshFailureGate.recordSuccess()
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == true)
    }

    @Test
    func transientBackoff_blocksUntilExpiry_thenUnblocks() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { fingerprint }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 60000)
        ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: start)

        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(1)) == false)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 5 - 1)) == false)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 5 + 1)) == true)
    }

    @Test
    func transientBackoff_isExponentialAndCapped() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { fingerprint }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 70000)
        ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: start)
        // Second failure before the first window expires should double the backoff.
        let secondFailureAt = start.addingTimeInterval(1)
        ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: secondFailureAt)
        #expect(ClaudeOAuthRefreshFailureGate
            .shouldAttempt(now: secondFailureAt.addingTimeInterval(60 * 10 - 1)) == false)
        #expect(ClaudeOAuthRefreshFailureGate
            .shouldAttempt(now: secondFailureAt.addingTimeInterval(60 * 10 + 1)) == true)

        ClaudeOAuthRefreshFailureGate.resetInMemoryStateForTesting()
        for _ in 0..<20 {
            ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: start)
        }

        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 60 * 6 - 1)) == false)
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 60 * 6 + 1)) == true)
    }

    @Test
    func transientBackoff_unblocksEarly_whenFingerprintChanges() {
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

        let start = Date(timeIntervalSince1970: 80000)
        ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: start)

        // Still blocked while timer is active and fingerprint unchanged.
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(20)) == false)

        fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 2,
                persistentRefHash: "ref2"),
            credentialsFile: "file2")

        // Even though the 5-minute cooldown window hasn't elapsed, a fingerprint change should unblock.
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(40)) == true)
    }
}
#endif
