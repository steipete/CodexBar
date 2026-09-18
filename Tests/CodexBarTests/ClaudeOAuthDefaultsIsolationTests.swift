import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, ClaudeOAuthDefaultsFixtures())
struct ClaudeOAuthDefaultsIsolationTests {
    @Test(arguments: [true, false])
    func `reset and success clear only the current cooldown store`(reset: Bool) {
        let first = ClaudeOAuthDefaultsFixtures.defaults
        let second = InMemoryUserDefaults()
        let token = "fixture-shared-token"
        let now = Date(timeIntervalSince1970: 1000)
        let expiry = now.addingTimeInterval(600)
        let key = ClaudeOAuthUsageRateLimitGate.storageKeyForTesting(accessToken: token)
        ClaudeOAuthUsageRateLimitGate.recordRateLimit(accessToken: token, retryAfter: expiry, now: now)
        ClaudeOAuthKeychainPromptPreference.withApplicationUserDefaultsOverrideForTesting(second) {
            ClaudeOAuthUsageRateLimitGate.recordRateLimit(accessToken: token, retryAfter: expiry, now: now)
            if reset {
                ClaudeOAuthUsageRateLimitGate.resetForTesting()
            } else {
                ClaudeOAuthUsageRateLimitGate.recordSuccess(accessToken: token, now: now)
            }
            #expect(second.object(forKey: key) == nil)
        }
        #expect(first.double(forKey: key) == expiry.timeIntervalSince1970)
        #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: token, now: now) == expiry)
    }

    @Test
    func `expiration purges only the current cooldown store`() {
        let first = ClaudeOAuthDefaultsFixtures.defaults
        let second = InMemoryUserDefaults()
        let token = "fixture-expired-token"
        let key = ClaudeOAuthUsageRateLimitGate.storageKeyForTesting(accessToken: token)
        let now = Date(timeIntervalSince1970: 1000)
        first.set(500.0, forKey: key)
        second.set(500.0, forKey: key)
        ClaudeOAuthKeychainPromptPreference.withApplicationUserDefaultsOverrideForTesting(second) {
            #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: token, now: now) == nil)
            #expect(second.object(forKey: key) == nil)
        }
        #expect(first.double(forKey: key) == 500)
    }

    @Test
    func `child tasks inherit the cooldown store and preserve longest deadlines`() async {
        let now = Date(timeIntervalSince1970: 1000)
        await withTaskGroup(of: Void.self) { group in
            for index in 1...8 {
                group.addTask {
                    ClaudeOAuthUsageRateLimitGate.recordRateLimit(
                        accessToken: "fixture-\(index % 2)",
                        retryAfter: now.addingTimeInterval(Double(index * 60)),
                        now: now)
                }
            }
        }
        for index in [7, 8] {
            let token = "fixture-\(index % 2)"
            let expected = now.addingTimeInterval(Double(index * 60))
            #expect(ClaudeOAuthUsageRateLimitGate.currentBlockedUntil(accessToken: token, now: now) == expected)
            let key = ClaudeOAuthUsageRateLimitGate.storageKeyForTesting(accessToken: token)
            #expect(ClaudeOAuthDefaultsFixtures.defaults.double(forKey: key) == expected.timeIntervalSince1970)
        }
    }

    @Test
    func `refresh gate reset and reload preserve another fixture's terminal state`() {
        let first = ClaudeOAuthDefaultsFixtures.defaults
        let second = InMemoryUserDefaults()
        let now = Date(timeIntervalSince1970: 1000)
        let environment = ["HOME": "/synthetic/claude-profile"]
        let fingerprint = ClaudeOAuthRefreshFailureGate.AuthFingerprint(keychain: nil, credentialsFile: "fixture")
        ClaudeOAuthRefreshFailureGate.resetInMemoryStateForTesting()
        defer { ClaudeOAuthRefreshFailureGate.resetInMemoryStateForTesting() }
        ClaudeOAuthRefreshFailureGate.withFingerprintProviderOverrideForTesting {
            fingerprint
        } operation: {
            ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(environment: environment, now: now)
            let persisted = first.dictionaryRepresentation()
            #expect(!persisted.isEmpty)
            #expect(!ClaudeOAuthRefreshFailureGate.shouldAttempt(environment: environment, now: now))
            ClaudeOAuthKeychainPromptPreference.withApplicationUserDefaultsOverrideForTesting(second) {
                ClaudeOAuthRefreshFailureGate.recordTerminalAuthFailure(environment: environment, now: now)
                #expect(!second.dictionaryRepresentation().isEmpty)
                ClaudeOAuthRefreshFailureGate.resetForTesting()
                #expect(second.dictionaryRepresentation().isEmpty)
            }
            #expect(NSDictionary(dictionary: first.dictionaryRepresentation()).isEqual(to: persisted))
            #expect(!ClaudeOAuthRefreshFailureGate.shouldAttempt(environment: environment, now: now))
        }
    }
}
