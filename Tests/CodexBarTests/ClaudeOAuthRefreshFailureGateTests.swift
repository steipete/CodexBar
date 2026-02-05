import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthRefreshFailureGateTests {
    private let legacyBlockedUntilKey = "claudeOAuthRefreshBackoffBlockedUntilV1"
    private let legacyFailureCountKey = "claudeOAuthRefreshBackoffFailureCountV1"
    private let legacyFingerprintKey = "claudeOAuthRefreshBackoffFingerprintV2"
    private let terminalBlockedKey = "claudeOAuthRefreshTerminalBlockedV1"

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
    func migratesLegacyFailureToTerminalBlock_andPersistsTerminalKey() throws {
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

        UserDefaults.standard.set(2, forKey: self.legacyFailureCountKey)
        UserDefaults.standard.removeObject(forKey: self.terminalBlockedKey)
        let data = try JSONEncoder().encode(fingerprint)
        UserDefaults.standard.set(data, forKey: self.legacyFingerprintKey)

        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: now) == false)
        #expect(UserDefaults.standard.bool(forKey: self.terminalBlockedKey) == true)
    }

    @Test
    func unblocksWhenFingerprintBecomesAvailable_afterBeingUnknownAtFailure() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var fingerprint: ClaudeOAuthRefreshFailureGate.AuthFingerprint?
        ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting { fingerprint }
        defer { ClaudeOAuthRefreshFailureGate.setFingerprintProviderOverrideForTesting(nil) }

        let start = Date(timeIntervalSince1970: 25000)
        ClaudeOAuthRefreshFailureGate.recordAuthFailure(now: start)

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
        ClaudeOAuthRefreshFailureGate.recordAuthFailure(now: start)
        #expect(calls == 1)

        // First blocked check re-reads fingerprint to compare.
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(1)) == false)
        #expect(calls == 2)

        // Subsequent checks within the throttle window should not re-read.
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(2)) == false)
        #expect(calls == 2)

        // After the throttle window, it should re-read again.
        #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(20)) == false)
        #expect(calls == 3)
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
