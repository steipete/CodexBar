import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthDelegatedRefreshProfileIsolationTests {
    @Test
    func `legacy cooldown migrates only to the default credentials profile`() {
        ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
            let defaults = UserDefaults.standard
            let legacyTimestampKey = "claudeOAuthDelegatedRefreshLastAttemptAtV1"
            let legacyIntervalKey = "claudeOAuthDelegatedRefreshCooldownIntervalSecondsV1"
            let now = Date(timeIntervalSince1970: 68000)
            let defaultEnvironment = ProcessInfo.processInfo.environment
            let otherEnvironment = ["CLAUDE_CONFIG_DIR": "/tmp/codexbar-profile-migration-other"]
            let defaultProfileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
                environment: defaultEnvironment)
            let scopedTimestampKey = legacyTimestampKey + ".profile." + defaultProfileIdentifier
            let scopedIntervalKey = legacyIntervalKey + ".profile." + defaultProfileIdentifier

            ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
            defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
            defaults.set(now.timeIntervalSince1970, forKey: legacyTimestampKey)
            defaults.set(300.0, forKey: legacyIntervalKey)

            #expect(ClaudeOAuthDelegatedRefreshCoordinator.isInCooldown(
                now: now.addingTimeInterval(1),
                environment: defaultEnvironment))
            #expect(!ClaudeOAuthDelegatedRefreshCoordinator.isInCooldown(
                now: now.addingTimeInterval(1),
                environment: otherEnvironment))
            #expect(defaults.object(forKey: scopedTimestampKey) as? Double == now.timeIntervalSince1970)
            #expect(defaults.object(forKey: scopedIntervalKey) as? Double == 300.0)
            #expect(defaults.object(forKey: legacyTimestampKey) == nil)
            #expect(defaults.object(forKey: legacyIntervalKey) == nil)
        }
    }

    @Test
    func `overlapping background profiles refresh independently of each other's cooldown`() async throws {
        actor Gate {
            private var startedContinuation: CheckedContinuation<Void, Never>?
            private var joinedContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var started = false
            private var joined = false
            private var released = false

            func markStarted() {
                self.started = true
                self.startedContinuation?.resume()
                self.startedContinuation = nil
            }

            func waitStarted() async {
                if self.started {
                    return
                }
                await withCheckedContinuation { self.startedContinuation = $0 }
            }

            func markJoined() {
                self.joined = true
                self.joinedContinuation?.resume()
                self.joinedContinuation = nil
            }

            func waitJoined() async {
                if self.joined {
                    return
                }
                await withCheckedContinuation { self.joinedContinuation = $0 }
            }

            func release() {
                self.released = true
                self.releaseContinuation?.resume()
                self.releaseContinuation = nil
            }

            func waitRelease() async {
                if self.released {
                    return
                }
                await withCheckedContinuation { self.releaseContinuation = $0 }
            }
        }

        final class State: @unchecked Sendable {
            private let lock = NSLock()
            private var environments: [[String: String]] = []
            private var fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "before")

            func record(_ environment: [String: String]) -> Int {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.environments.append(environment)
                return self.environments.count
            }

            func advanceFingerprint(for attempt: Int) {
                self.lock.lock()
                self.fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                    modifiedAt: attempt + 1,
                    createdAt: attempt + 1,
                    persistentRefHash: "after-\(attempt)")
                self.lock.unlock()
            }

            func snapshot() -> ([[String: String]], ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint) {
                self.lock.lock()
                defer { self.lock.unlock() }
                return (self.environments, self.fingerprint)
            }
        }

        let gate = Gate()
        let state = State()
        let profileA = ["CLAUDE_CONFIG_DIR": "/tmp/codexbar-profile-a"]
        let profileB = ["CLAUDE_CONFIG_DIR": "/tmp/codexbar-profile-b"]
        let touchAuthPath: @Sendable (TimeInterval, [String: String]) async throws -> Void = { _, environment in
            let attempt = state.record(environment)
            if attempt == 1 {
                await gate.markStarted()
                await gate.waitRelease()
            }
            state.advanceFingerprint(for: attempt)
        }

        let outcomes = try await ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                try await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                    try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                        try await ClaudeOAuthDelegatedRefreshCoordinator.withIsolatedStateForTesting {
                            try await ClaudeOAuthDelegatedRefreshCoordinator.withCLIAvailableOverrideForTesting(true) {
                                try await ClaudeOAuthDelegatedRefreshCoordinator
                                    .withKeychainFingerprintOverrideForTesting {
                                        state.snapshot().1
                                    } operation: {
                                        try await ClaudeOAuthDelegatedRefreshCoordinator
                                            .withTouchAuthPathOverrideForTesting(
                                                touchAuthPath)
                                            {
                                                await ClaudeOAuthDelegatedRefreshCoordinator
                                                    .withDifferentProfileJoinObserverForTesting {
                                                        Task { await gate.markJoined() }
                                                    } operation: {
                                                        let first = Task {
                                                            await ProviderInteractionContext.$current
                                                                .withValue(.background) {
                                                                    await ClaudeOAuthDelegatedRefreshCoordinator
                                                                        .attempt(
                                                                            now: Date(timeIntervalSince1970: 70000),
                                                                            timeout: 2,
                                                                            environment: profileA)
                                                                }
                                                        }
                                                        await gate.waitStarted()
                                                        let second = Task {
                                                            await ProviderInteractionContext.$current
                                                                .withValue(.background) {
                                                                    await ClaudeOAuthDelegatedRefreshCoordinator
                                                                        .attempt(
                                                                            now: Date(timeIntervalSince1970: 70001),
                                                                            timeout: 2,
                                                                            environment: profileB)
                                                                }
                                                        }
                                                        await gate.waitJoined()
                                                        await gate.release()
                                                        return await (first.value, second.value)
                                                    }
                                            }
                                    }
                            }
                        }
                    }
                }
            }
        }

        #expect(outcomes.0 == .attemptedSucceeded)
        #expect(outcomes.1 == .attemptedSucceeded)
        #expect(state.snapshot().0 == [profileA, profileB])
    }
}
