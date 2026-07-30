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

    private func profileKey(
        _ base: String,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String
    {
        let profileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        return base + ".profile." + profileIdentifier
    }

    @Test
    func `blocks indefinitely when fingerprint unchanged`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
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
    }

    @Test
    func `global Keychain changes cannot unblock a selected profile`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "profile-a-global-ref"),
            credentialsFile: "profile-a-file")
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
            let start = Date(timeIntervalSince1970: 1500)
            ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: start)

            fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
                keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                    modifiedAt: 2,
                    createdAt: 2,
                    persistentRefHash: "profile-b-global-ref"),
                credentialsFile: "profile-a-file")

            #expect(!ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(20)))
        }
    }

    @Test
    func `migrates legacy blocked until in past does not block and clears key`() {
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
    func `migrates legacy backoff to transient backoff does not set terminal block`() throws {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let now = Date(timeIntervalSince1970: 20000)

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        try ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
            let legacyBlockedUntil = now.addingTimeInterval(60 * 10)
            UserDefaults.standard.set(2, forKey: self.legacyFailureCountKey)
            UserDefaults.standard.removeObject(forKey: self.terminalBlockedKey)
            UserDefaults.standard.set(legacyBlockedUntil.timeIntervalSince1970, forKey: self.legacyBlockedUntilKey)
            let data = try JSONEncoder().encode(fingerprint)
            UserDefaults.standard.set(data, forKey: self.legacyFingerprintKey)

            #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: now) == false)
            #expect(UserDefaults.standard.bool(forKey: self.terminalBlockedKey) == false)
            #expect(UserDefaults.standard.object(forKey: self.legacyBlockedUntilKey) == nil)
            #expect(UserDefaults.standard.object(forKey: self.profileKey(self.transientBlockedUntilKey)) != nil)
            #expect(UserDefaults.standard.integer(forKey: self.profileKey(self.transientFailureCountKey)) == 2)
        }
    }

    @Test
    func `unblocks when fingerprint becomes available after being unknown at failure`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var fingerprint: ClaudeOAuthRefreshFailureGate.AuthFingerprint?
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
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
    }

    @Test
    func `unblocks immediately when fingerprint changes`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
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
    }

    @Test
    func `throttles fingerprint recheck while terminal blocked`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var calls = 0
        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            calls += 1
            return fingerprint
        } operation: {
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
    }

    @Test
    func `terminal block is monotonic when transient failure is recorded`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
            let start = Date(timeIntervalSince1970: 35000)
            ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: start)
            ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: start.addingTimeInterval(1))

            #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(20)) == false)
            #expect(UserDefaults.standard.bool(forKey: self.profileKey(self.terminalBlockedKey)) == true)
            #expect(UserDefaults.standard.object(forKey: self.profileKey(self.transientBlockedUntilKey)) == nil)
        }
    }

    @Test
    func `failure state and recovery fingerprints are isolated by credentials profile`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let environmentA = ["CLAUDE_CONFIG_DIR": "/tmp/codexbar-refresh-gate-profile-a"]
        let environmentB = ["CLAUDE_CONFIG_DIR": "/tmp/codexbar-refresh-gate-profile-b"]
        let fingerprintB = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: nil,
            credentialsFile: "profile-b-file-1")
        var fingerprintA = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: nil,
            credentialsFile: "profile-a-file-1")

        ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
            ClaudeOAuthRefreshFailureGate.withEnvironmentFingerprintProviderOverrideForTesting { environment in
                environment["CLAUDE_CONFIG_DIR"] == environmentA["CLAUDE_CONFIG_DIR"]
                    ? fingerprintA
                    : fingerprintB
            } operation: {
                let start = Date(timeIntervalSince1970: 40000)
                ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(environment: environmentA, now: start)

                #expect(!ClaudeOAuthRefreshFailureGate.shouldAttempt(
                    environment: environmentA,
                    now: start.addingTimeInterval(20)))
                #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(
                    environment: environmentB,
                    now: start.addingTimeInterval(20)))

                ClaudeOAuthRefreshFailureGate.recordTransientFailure(environment: environmentB, now: start)
                ClaudeOAuthRefreshFailureGate.resetInMemoryStateForTesting()
                #expect(!ClaudeOAuthRefreshFailureGate.shouldAttempt(
                    environment: environmentB,
                    now: start.addingTimeInterval(20)))

                ClaudeOAuthRefreshFailureGate.recordSuccess(environment: environmentB)
                #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(
                    environment: environmentB,
                    now: start.addingTimeInterval(20)))
                #expect(!ClaudeOAuthRefreshFailureGate.shouldAttempt(
                    environment: environmentA,
                    now: start.addingTimeInterval(40)))

                fingerprintA = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
                    keychain: nil,
                    credentialsFile: "profile-a-file-2")
                #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(
                    environment: environmentA,
                    now: start.addingTimeInterval(60)))
            }
        }
    }

    @Test
    func `record success clears terminal block`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
            let start = Date(timeIntervalSince1970: 5000)
            ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(now: start)
            #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == false)

            ClaudeOAuthRefreshFailureGate.recordSuccess()
            #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60)) == true)
        }
    }

    @Test
    func `transient backoff blocks until expiry then unblocks`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
            let start = Date(timeIntervalSince1970: 60000)
            ClaudeOAuthRefreshFailureGate.recordTransientFailure(now: start)

            #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(1)) == false)
            #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 5 - 1)) == false)
            #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 5 + 1)) == true)
        }
    }

    @Test
    func `transient backoff is exponential and capped`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
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

            #expect(ClaudeOAuthRefreshFailureGate
                .shouldAttempt(now: start.addingTimeInterval(60 * 60 * 6 - 1)) == false)
            #expect(ClaudeOAuthRefreshFailureGate.shouldAttempt(now: start.addingTimeInterval(60 * 60 * 6 + 1)) == true)
        }
    }

    @Test
    func `transient backoff unblocks early when fingerprint changes`() {
        ClaudeOAuthRefreshFailureGate.resetForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetForTesting() }

        var fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(
            keychain: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"),
            credentialsFile: "file1")
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
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
}
#endif
