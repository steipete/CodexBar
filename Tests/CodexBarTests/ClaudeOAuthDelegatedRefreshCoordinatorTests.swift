import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthDelegatedRefreshCoordinatorTests {
    private enum StubError: Error, LocalizedError {
        case failed

        var errorDescription: String? {
            switch self {
            case .failed:
                "failed"
            }
        }
    }

    private func makeCredentialsData(accessToken: String, expiresAt: Date) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]
          }
        }
        """
        return Data(json.utf8)
    }

    @Test
    func cooldownPreventsRepeatedAttempts() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }

        final class FingerprintBox: @unchecked Sendable {
            var fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?
            init(_ fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?) {
                self.fingerprint = fingerprint
            }
        }
        let box = FingerprintBox(ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 1,
            createdAt: 1,
            persistentRefHash: "ref1"))
        ClaudeOAuthDelegatedRefreshCoordinator.setKeychainFingerprintOverrideForTesting { box.fingerprint }

        ClaudeOAuthDelegatedRefreshCoordinator.setCLIAvailableOverrideForTesting(true)
        ClaudeOAuthDelegatedRefreshCoordinator.setTouchAuthPathOverrideForTesting { _ in
            box.fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 2,
                persistentRefHash: "ref2")
        }

        let start = Date(timeIntervalSince1970: 10000)
        let first = await ClaudeOAuthDelegatedRefreshCoordinator.attempt(now: start, timeout: 0.1)
        let second = await ClaudeOAuthDelegatedRefreshCoordinator
            .attempt(now: start.addingTimeInterval(30), timeout: 0.1)

        #expect(first == .attemptedSucceeded)
        #expect(second == .skippedByCooldown)
    }

    @Test
    func cliUnavailableReturnsCliUnavailable() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }

        ClaudeOAuthDelegatedRefreshCoordinator.setCLIAvailableOverrideForTesting(false)

        let outcome = await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
            now: Date(timeIntervalSince1970: 20000),
            timeout: 0.1)

        #expect(outcome == .cliUnavailable)
    }

    @Test
    func successfulAuthTouchReportsAttemptedSucceeded() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }

        final class FingerprintBox: @unchecked Sendable {
            var fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?
            init(_ fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?) {
                self.fingerprint = fingerprint
            }
        }
        let box = FingerprintBox(ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 10,
            createdAt: 10,
            persistentRefHash: "refA"))
        ClaudeOAuthDelegatedRefreshCoordinator.setKeychainFingerprintOverrideForTesting { box.fingerprint }

        ClaudeOAuthDelegatedRefreshCoordinator.setCLIAvailableOverrideForTesting(true)
        ClaudeOAuthDelegatedRefreshCoordinator.setTouchAuthPathOverrideForTesting { _ in
            box.fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 11,
                createdAt: 11,
                persistentRefHash: "refB")
        }

        let outcome = await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
            now: Date(timeIntervalSince1970: 30000),
            timeout: 0.1)

        #expect(outcome == .attemptedSucceeded)
    }

    @Test
    func failedAuthTouchReportsAttemptedFailed() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }

        ClaudeOAuthDelegatedRefreshCoordinator.setKeychainFingerprintOverrideForTesting {
            ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 20,
                createdAt: 20,
                persistentRefHash: "refX")
        }

        ClaudeOAuthDelegatedRefreshCoordinator.setCLIAvailableOverrideForTesting(true)
        ClaudeOAuthDelegatedRefreshCoordinator.setTouchAuthPathOverrideForTesting { _ in
            throw StubError.failed
        }

        let outcome = await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
            now: Date(timeIntervalSince1970: 40000),
            timeout: 0.1)

        guard case let .attemptedFailed(message) = outcome else {
            Issue.record("Expected .attemptedFailed outcome")
            return
        }
        #expect(message.contains("failed"))
    }

    @Test
    func concurrentAttemptsJoinInFlight() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }

        actor Gate {
            private var startedContinuations: [CheckedContinuation<Void, Never>] = []
            private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
            private var hasStarted = false
            private var isReleased = false

            func markStarted() {
                self.hasStarted = true
                let continuations = self.startedContinuations
                self.startedContinuations.removeAll()
                continuations.forEach { $0.resume() }
            }

            func waitStarted() async {
                if self.hasStarted { return }
                await withCheckedContinuation { cont in
                    self.startedContinuations.append(cont)
                }
            }

            func release() {
                self.isReleased = true
                let continuations = self.releaseContinuations
                self.releaseContinuations.removeAll()
                continuations.forEach { $0.resume() }
            }

            func waitRelease() async {
                if self.isReleased { return }
                await withCheckedContinuation { cont in
                    self.releaseContinuations.append(cont)
                }
            }
        }

        final class FingerprintBox: @unchecked Sendable {
            var fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?
            init(_ fingerprint: ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?) {
                self.fingerprint = fingerprint
            }
        }

        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count: Int = 0
            func increment() {
                self.lock.lock()
                self.count += 1
                self.lock.unlock()
            }
        }

        let counter = CounterBox()
        let gate = Gate()
        let box = FingerprintBox(ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 1,
            createdAt: 1,
            persistentRefHash: "ref1"))
        ClaudeOAuthDelegatedRefreshCoordinator.setKeychainFingerprintOverrideForTesting { box.fingerprint }

        ClaudeOAuthDelegatedRefreshCoordinator.setCLIAvailableOverrideForTesting(true)
        ClaudeOAuthDelegatedRefreshCoordinator.setTouchAuthPathOverrideForTesting { _ in
            counter.increment()
            await gate.markStarted()
            await gate.waitRelease()
            box.fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 2,
                persistentRefHash: "ref2")
        }

        let now = Date(timeIntervalSince1970: 50000)
        async let first = ClaudeOAuthDelegatedRefreshCoordinator.attempt(now: now, timeout: 2)
        await gate.waitStarted()
        async let second = ClaudeOAuthDelegatedRefreshCoordinator.attempt(now: now.addingTimeInterval(30), timeout: 2)

        await gate.release()
        let outcomes = await [first, second]

        #expect(outcomes.allSatisfy { $0 == .attemptedSucceeded })
        #expect(counter.count == 1)
    }

    @Test
    func experimentalStrategy_doesNotUseSecurityFrameworkFingerprintObservation() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
        await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental)
        {
            final class CounterBox: @unchecked Sendable {
                private let lock = NSLock()
                private(set) var count: Int = 0
                func increment() {
                    self.lock.lock()
                    self.count += 1
                    self.lock.unlock()
                }
            }
            let fingerprintCounter = CounterBox()
            ClaudeOAuthDelegatedRefreshCoordinator.setKeychainFingerprintOverrideForTesting {
                fingerprintCounter.increment()
                return ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                    modifiedAt: 1,
                    createdAt: 1,
                    persistentRefHash: "framework-fingerprint")
            }
            ClaudeOAuthDelegatedRefreshCoordinator.setCLIAvailableOverrideForTesting(true)
            ClaudeOAuthDelegatedRefreshCoordinator.setTouchAuthPathOverrideForTesting { _ in }

            let securityData = self.makeCredentialsData(
                accessToken: "security-token-a",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            ClaudeOAuthCredentialsStore.setSecurityCLIReadOverrideForTesting(.data(securityData))
            defer { ClaudeOAuthCredentialsStore.setSecurityCLIReadOverrideForTesting(nil) }
            let outcome = await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                now: Date(timeIntervalSince1970: 60000),
                timeout: 0.1)

            guard case .attemptedFailed = outcome else {
                Issue.record("Expected .attemptedFailed outcome")
                return
            }
            #expect(fingerprintCounter.count < 1)
        }
    }

    @Test
    func experimentalStrategy_observesSecurityCLIChangeAfterTouch() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
        await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental)
        {
            final class DataBox: @unchecked Sendable {
                private let lock = NSLock()
                private var _data: Data?
                init(data: Data?) {
                    self._data = data
                }

                func load() -> Data? {
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    return self._data
                }

                func store(_ data: Data?) {
                    self.lock.lock()
                    self._data = data
                    self.lock.unlock()
                }
            }
            final class CounterBox: @unchecked Sendable {
                private let lock = NSLock()
                private(set) var count: Int = 0
                func increment() {
                    self.lock.lock()
                    self.count += 1
                    self.lock.unlock()
                }
            }
            let fingerprintCounter = CounterBox()
            ClaudeOAuthDelegatedRefreshCoordinator.setKeychainFingerprintOverrideForTesting {
                fingerprintCounter.increment()
                return ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                    modifiedAt: 11,
                    createdAt: 11,
                    persistentRefHash: "framework-fingerprint")
            }

            let beforeData = self.makeCredentialsData(
                accessToken: "security-token-before",
                expiresAt: Date(timeIntervalSinceNow: -60))
            let afterData = self.makeCredentialsData(
                accessToken: "security-token-after",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            let dataBox = DataBox(data: beforeData)

            ClaudeOAuthDelegatedRefreshCoordinator.setCLIAvailableOverrideForTesting(true)
            ClaudeOAuthDelegatedRefreshCoordinator.setTouchAuthPathOverrideForTesting { _ in
                dataBox.store(afterData)
            }
            ClaudeOAuthCredentialsStore.setSecurityCLIReadOverrideForTesting(.dynamic { _ in dataBox.load() })
            defer { ClaudeOAuthCredentialsStore.setSecurityCLIReadOverrideForTesting(nil) }

            let outcome = await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                now: Date(timeIntervalSince1970: 61000),
                timeout: 0.1)

            #expect(outcome == .attemptedSucceeded)
            #expect(fingerprintCounter.count < 1)
        }
    }

    @Test
    func experimentalStrategy_missingBaselineDoesNotAutoSucceedWhenLaterReadSucceeds() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
        await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental)
        {
            final class DataBox: @unchecked Sendable {
                private let lock = NSLock()
                private var _data: Data?
                init(data: Data?) {
                    self._data = data
                }

                func load() -> Data? {
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    return self._data
                }

                func store(_ data: Data?) {
                    self.lock.lock()
                    self._data = data
                    self.lock.unlock()
                }
            }
            final class CounterBox: @unchecked Sendable {
                private let lock = NSLock()
                private(set) var count: Int = 0
                func increment() {
                    self.lock.lock()
                    self.count += 1
                    self.lock.unlock()
                }
            }
            let fingerprintCounter = CounterBox()
            ClaudeOAuthDelegatedRefreshCoordinator.setKeychainFingerprintOverrideForTesting {
                fingerprintCounter.increment()
                return ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                    modifiedAt: 21,
                    createdAt: 21,
                    persistentRefHash: "framework-fingerprint")
            }

            let afterData = self.makeCredentialsData(
                accessToken: "security-token-after-baseline-miss",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            let dataBox = DataBox(data: nil)

            ClaudeOAuthDelegatedRefreshCoordinator.setCLIAvailableOverrideForTesting(true)
            ClaudeOAuthDelegatedRefreshCoordinator.setTouchAuthPathOverrideForTesting { _ in
                dataBox.store(afterData)
            }
            ClaudeOAuthCredentialsStore.setSecurityCLIReadOverrideForTesting(.dynamic { _ in dataBox.load() })
            defer { ClaudeOAuthCredentialsStore.setSecurityCLIReadOverrideForTesting(nil) }

            let outcome = await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                now: Date(timeIntervalSince1970: 61500),
                timeout: 0.1)

            guard case .attemptedFailed = outcome else {
                Issue.record("Expected .attemptedFailed outcome when baseline is unavailable")
                return
            }
            #expect(fingerprintCounter.count < 1)
        }
    }

    @Test
    func experimentalStrategy_observationSkipsSecurityCLIWhenGlobalKeychainDisabled() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
        await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityCLIExperimental)
        {
            final class CounterBox: @unchecked Sendable {
                private let lock = NSLock()
                private(set) var count: Int = 0
                func increment() {
                    self.lock.lock()
                    self.count += 1
                    self.lock.unlock()
                }
            }

            let securityReadCounter = CounterBox()
            let securityData = self.makeCredentialsData(
                accessToken: "security-should-not-be-read",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            ClaudeOAuthDelegatedRefreshCoordinator.setCLIAvailableOverrideForTesting(true)
            ClaudeOAuthDelegatedRefreshCoordinator.setTouchAuthPathOverrideForTesting { _ in }
            ClaudeOAuthCredentialsStore.setSecurityCLIReadOverrideForTesting(.dynamic { _ in
                securityReadCounter.increment()
                return securityData
            })
            defer { ClaudeOAuthCredentialsStore.setSecurityCLIReadOverrideForTesting(nil) }
            let outcome = await KeychainAccessGate.withTaskOverrideForTesting(true) {
                await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                    now: Date(timeIntervalSince1970: 62000),
                    timeout: 0.1)
            }

            guard case .attemptedFailed = outcome else {
                Issue.record("Expected .attemptedFailed outcome")
                return
            }
            #expect(securityReadCounter.count < 1)
        }
    }
}
