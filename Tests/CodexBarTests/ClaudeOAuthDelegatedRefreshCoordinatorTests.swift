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

    private func withCoordinatorOverrides<T>(
        isolateState: Bool = true,
        cliAvailable: Bool? = nil,
        touchAuthPath: (@Sendable (TimeInterval, [String: String]) async throws -> Void)? = nil,
        keychainFingerprint: (@Sendable () -> ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint?)? = nil,
        operation: () async throws -> T) async rethrows -> T
    {
        if isolateState {
            return try await ClaudeOAuthDelegatedRefreshCoordinator.withIsolatedStateForTesting {
                ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
                defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
                return try await ClaudeOAuthDelegatedRefreshCoordinator.withKeychainFingerprintOverrideForTesting(
                    keychainFingerprint)
                {
                    try await ClaudeOAuthDelegatedRefreshCoordinator.withCLIAvailableOverrideForTesting(
                        cliAvailable)
                    {
                        try await ClaudeOAuthDelegatedRefreshCoordinator.withTouchAuthPathOverrideForTesting(
                            touchAuthPath)
                        {
                            try await operation()
                        }
                    }
                }
            }
        }
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
        return try await ClaudeOAuthDelegatedRefreshCoordinator.withKeychainFingerprintOverrideForTesting(
            keychainFingerprint)
        {
            try await ClaudeOAuthDelegatedRefreshCoordinator.withCLIAvailableOverrideForTesting(cliAvailable) {
                try await ClaudeOAuthDelegatedRefreshCoordinator.withTouchAuthPathOverrideForTesting(
                    touchAuthPath)
                {
                    try await operation()
                }
            }
        }
    }

    @Test
    func `cooldown prevents repeated attempts`() async {
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
        let start = Date(timeIntervalSince1970: 10000)
        let (first, second) = await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityFramework)
        {
            await self.withCoordinatorOverrides(
                cliAvailable: true,
                touchAuthPath: { _, _ in
                    box.fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                        modifiedAt: 2,
                        createdAt: 2,
                        persistentRefHash: "ref2")
                },
                keychainFingerprint: { box.fingerprint },
                operation: {
                    let first = await ClaudeOAuthDelegatedRefreshCoordinator.attempt(now: start, timeout: 0.1)
                    let second = await ClaudeOAuthDelegatedRefreshCoordinator
                        .attempt(now: start.addingTimeInterval(30), timeout: 0.1)
                    return (first, second)
                })
        }

        #expect(first == .attemptedSucceeded)
        #expect(second == .skippedByCooldown)
    }

    @Test
    func `cli unavailable returns cli unavailable`() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }

        let outcome = await self.withCoordinatorOverrides(cliAvailable: false, operation: {
            await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                now: Date(timeIntervalSince1970: 20000),
                timeout: 0.1)
        })

        #expect(outcome == .cliUnavailable)
    }

    @Test
    func `successful auth touch reports attempted succeeded`() async {
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
        let outcome = await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
            .securityFramework)
        {
            await self.withCoordinatorOverrides(
                cliAvailable: true,
                touchAuthPath: { _, _ in
                    box.fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                        modifiedAt: 11,
                        createdAt: 11,
                        persistentRefHash: "refB")
                },
                keychainFingerprint: { box.fingerprint },
                operation: {
                    await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                        now: Date(timeIntervalSince1970: 30000),
                        timeout: 0.1)
                })
        }

        #expect(outcome == .attemptedSucceeded)
    }

    @Test
    func `failed auth touch reports attempted failed`() async throws {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }

        let outcome = try await self.withCoordinatorOverrides(
            cliAvailable: true,
            touchAuthPath: { _, _ in
                throw StubError.failed
            },
            keychainFingerprint: {
                ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                    modifiedAt: 20,
                    createdAt: 20,
                    persistentRefHash: "refX")
            },
            operation: {
                await KeychainAccessGate.withTaskOverrideForTesting(false) {
                    await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                        await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                            now: Date(timeIntervalSince1970: 40000),
                            timeout: 0.1)
                    }
                }
            })

        guard case let .attemptedFailed(message) = outcome else {
            Issue.record("Expected .attemptedFailed outcome")
            return
        }
        #expect(message.contains("failed"))
    }

    @Test
    func `environment CLI override avoids CLI unavailable`() async throws {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }

        let stubCLI = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let script = "#!/bin/sh\nexit 0\n"
        try script.write(to: stubCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubCLI.path)

        let outcome = try await self.withCoordinatorOverrides(
            touchAuthPath: { _, environment in
                #expect(environment["CLAUDE_CLI_PATH"] == stubCLI.path)
                throw StubError.failed
            },
            keychainFingerprint: {
                ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                    modifiedAt: 20,
                    createdAt: 20,
                    persistentRefHash: "ref-env")
            },
            operation: {
                await KeychainAccessGate.withTaskOverrideForTesting(false) {
                    await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                        await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                            now: Date(timeIntervalSince1970: 45000),
                            timeout: 0.1,
                            environment: ["CLAUDE_CLI_PATH": stubCLI.path])
                    }
                }
            })

        guard case let .attemptedFailed(message) = outcome else {
            Issue.record("Expected env-provided CLI override to reach touch attempt")
            return
        }
        #expect(message.contains("failed"))
    }

    @Test
    func `concurrent attempts join in flight`() async {
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
        let now = Date(timeIntervalSince1970: 50000)
        let outcomes = await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                await self.withCoordinatorOverrides(
                    isolateState: false,
                    cliAvailable: true,
                    touchAuthPath: { _, _ in
                        counter.increment()
                        await gate.markStarted()
                        await gate.waitRelease()
                        box.fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                            modifiedAt: 2,
                            createdAt: 2,
                            persistentRefHash: "ref2")
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    },
                    keychainFingerprint: { box.fingerprint },
                    operation: {
                        let first = Task {
                            await ClaudeOAuthDelegatedRefreshCoordinator.attempt(now: now, timeout: 2)
                        }
                        await gate.waitStarted()
                        let second = Task {
                            await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                                now: now.addingTimeInterval(30),
                                timeout: 2)
                        }

                        await gate.release()
                        return await [first.value, second.value]
                    })
            }
        }

        #expect(outcomes.allSatisfy { $0 == .attemptedSucceeded })
        #expect(counter.count == 1)
    }

    @Test
    func `user action retries after joining failed background attempt`() async throws {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }

        actor Gate {
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var startedContinuation: CheckedContinuation<Void, Never>?
            private var joinedContinuation: CheckedContinuation<Void, Never>?
            private var hasStarted = false
            private var isReleased = false
            private var hasJoined = false

            func markStarted() {
                self.hasStarted = true
                self.startedContinuation?.resume()
                self.startedContinuation = nil
            }

            func waitStarted() async {
                if self.hasStarted { return }
                await withCheckedContinuation { self.startedContinuation = $0 }
            }

            func release() {
                self.isReleased = true
                self.releaseContinuation?.resume()
                self.releaseContinuation = nil
            }

            func waitRelease() async {
                if self.isReleased { return }
                await withCheckedContinuation { self.releaseContinuation = $0 }
            }

            func markJoined() {
                self.hasJoined = true
                self.joinedContinuation?.resume()
                self.joinedContinuation = nil
            }

            func waitJoined() async {
                if self.hasJoined { return }
                await withCheckedContinuation { self.joinedContinuation = $0 }
            }
        }

        final class StateBox: @unchecked Sendable {
            private let lock = NSLock()
            private var touchCount = 0
            private var fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "before")

            func beginTouch() -> Int {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.touchCount += 1
                return self.touchCount
            }

            func markChanged() {
                self.lock.lock()
                self.fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                    modifiedAt: 2,
                    createdAt: 2,
                    persistentRefHash: "after")
                self.lock.unlock()
            }

            func snapshot() -> (Int, ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint) {
                self.lock.lock()
                defer { self.lock.unlock() }
                return (self.touchCount, self.fingerprint)
            }
        }

        let gate = Gate()
        let state = StateBox()
        let outcomes = try await KeychainAccessGate.withTaskOverrideForTesting(false) {
            try await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(.securityFramework) {
                try await self.withCoordinatorOverrides(
                    isolateState: false,
                    cliAvailable: true,
                    touchAuthPath: { _, _ in
                        if state.beginTouch() == 1 {
                            await gate.markStarted()
                            await gate.waitRelease()
                            throw StubError.failed
                        }
                        state.markChanged()
                    },
                    keychainFingerprint: { state.snapshot().1 },
                    operation: {
                        await ClaudeOAuthDelegatedRefreshCoordinator
                            .withUserInitiatedBackgroundJoinObserverForTesting {
                                Task { await gate.markJoined() }
                            } operation: {
                                let background = Task {
                                    await ProviderInteractionContext.$current.withValue(.background) {
                                        await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                                            now: Date(timeIntervalSince1970: 51000),
                                            timeout: 2)
                                    }
                                }
                                await gate.waitStarted()
                                let userInitiated = Task {
                                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                        await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                                            now: Date(timeIntervalSince1970: 51001),
                                            timeout: 2)
                                    }
                                }
                                await gate.waitJoined()
                                await gate.release()
                                return await (background.value, userInitiated.value)
                            }
                    })
            }
        }

        guard case .attemptedFailed = outcomes.0 else {
            Issue.record("Expected the background attempt to fail")
            return
        }
        #expect(outcomes.1 == .attemptedSucceeded)
        #expect(state.snapshot().0 == 2)
    }

    @Test
    func `experimental strategy does not use security framework fingerprint observation`() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
        await KeychainAccessGate.withTaskOverrideForTesting(false) {
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
                let securityData = self.makeCredentialsData(
                    accessToken: "security-token-a",
                    expiresAt: Date(timeIntervalSinceNow: 3600))
                let outcome = await self.withCoordinatorOverrides(
                    cliAvailable: true,
                    touchAuthPath: { _, _ in },
                    keychainFingerprint: {
                        fingerprintCounter.increment()
                        return ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                            modifiedAt: 1,
                            createdAt: 1,
                            persistentRefHash: "framework-fingerprint")
                    },
                    operation: {
                        await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(securityData)) {
                            await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                                now: Date(timeIntervalSince1970: 60000),
                                timeout: 0.1)
                        }
                    })

                guard case .attemptedFailed = outcome else {
                    Issue.record("Expected .attemptedFailed outcome")
                    return
                }
                #expect(fingerprintCounter.count < 1)
            }
        }
    }

    @Test
    func `experimental strategy observes security CLI change after touch`() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
        await KeychainAccessGate.withTaskOverrideForTesting(false) {
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
                let beforeData = self.makeCredentialsData(
                    accessToken: "security-token-before",
                    expiresAt: Date(timeIntervalSinceNow: -60))
                let afterData = self.makeCredentialsData(
                    accessToken: "security-token-after",
                    expiresAt: Date(timeIntervalSinceNow: 3600))
                let dataBox = DataBox(data: beforeData)
                let outcome = await self.withCoordinatorOverrides(
                    cliAvailable: true,
                    touchAuthPath: { _, _ in
                        dataBox.store(afterData)
                    },
                    keychainFingerprint: {
                        fingerprintCounter.increment()
                        return ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                            modifiedAt: 11,
                            createdAt: 11,
                            persistentRefHash: "framework-fingerprint")
                    },
                    operation: {
                        await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                            .dynamic { _ in dataBox.load() })
                        {
                            await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                                now: Date(timeIntervalSince1970: 61000),
                                timeout: 0.1)
                        }
                    })

                #expect(outcome == .attemptedSucceeded)
                #expect(fingerprintCounter.count < 1)
            }
        }
    }

    @Test
    func `experimental strategy missing baseline does not auto succeed when later read succeeds`() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
        await KeychainAccessGate.withTaskOverrideForTesting(false) {
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
                let afterData = self.makeCredentialsData(
                    accessToken: "security-token-after-baseline-miss",
                    expiresAt: Date(timeIntervalSinceNow: 3600))
                let dataBox = DataBox(data: nil)
                let outcome = await self.withCoordinatorOverrides(
                    cliAvailable: true,
                    touchAuthPath: { _, _ in
                        dataBox.store(afterData)
                    },
                    keychainFingerprint: {
                        fingerprintCounter.increment()
                        return ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                            modifiedAt: 21,
                            createdAt: 21,
                            persistentRefHash: "framework-fingerprint")
                    },
                    operation: {
                        await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                            .dynamic { _ in dataBox.load() })
                        {
                            await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                                now: Date(timeIntervalSince1970: 61500),
                                timeout: 0.1)
                        }
                    })

                guard case .attemptedFailed = outcome else {
                    Issue.record("Expected .attemptedFailed outcome when baseline is unavailable")
                    return
                }
                #expect(fingerprintCounter.count < 1)
            }
        }
    }

    @Test
    func `experimental strategy observation skips security CLI when global keychain disabled`() async {
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
            let outcome = await self.withCoordinatorOverrides(
                cliAvailable: true,
                touchAuthPath: { _, _ in },
                operation: {
                    await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.dynamic { _ in
                        securityReadCounter.increment()
                        return securityData
                    }) {
                        await KeychainAccessGate.withTaskOverrideForTesting(true) {
                            await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                                now: Date(timeIntervalSince1970: 62000),
                                timeout: 0.1)
                        }
                    }
                })

            guard case .attemptedFailed = outcome else {
                Issue.record("Expected .attemptedFailed outcome")
                return
            }
            #expect(securityReadCounter.count < 1)
        }
    }

    @Test
    func `experimental strategy blocks background mcp O auth but lets user action retry`() async {
        ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting()
        defer { ClaudeOAuthDelegatedRefreshCoordinator.resetForTesting() }
        await KeychainAccessGate.withTaskOverrideForTesting(false) {
            await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                .securityCLIExperimental)
            {
                final class StateBox: @unchecked Sendable {
                    private let lock = NSLock()
                    private var touchCount = 0

                    func touch() {
                        self.lock.lock()
                        self.touchCount += 1
                        self.lock.unlock()
                    }

                    func count() -> Int {
                        self.lock.lock()
                        defer { self.lock.unlock() }
                        return self.touchCount
                    }
                }

                let state = StateBox()
                let mcpOAuthOnly = Data("""
                {
                  "mcpOAuth": {
                    "plugin:slack:slack": { "accessToken": "" }
                  }
                }
                """.utf8)
                let refreshedCredentials = self.makeCredentialsData(
                    accessToken: "refreshed-after-user-action",
                    expiresAt: Date(timeIntervalSinceNow: 3600))
                let outcomes = await self.withCoordinatorOverrides(
                    cliAvailable: true,
                    touchAuthPath: { _, _ in state.touch() },
                    operation: {
                        await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.dynamic { _ in
                            state.count() > 0 ? refreshedCredentials : mcpOAuthOnly
                        }) {
                            let background = await ProviderInteractionContext.$current.withValue(.background) {
                                await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                                    now: Date(timeIntervalSince1970: 63000),
                                    timeout: 0.1)
                            }
                            let backgroundTouchCount = state.count()
                            let userInitiated = await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                await ClaudeOAuthDelegatedRefreshCoordinator.attempt(
                                    now: Date(timeIntervalSince1970: 63001),
                                    timeout: 0.1)
                            }
                            return (background, backgroundTouchCount, userInitiated)
                        }
                    })

                guard case let .attemptedFailed(message) = outcomes.0 else {
                    Issue.record("Expected background .attemptedFailed outcome")
                    return
                }
                #expect(message.contains("MCP OAuth"))
                #expect(outcomes.1 == 0)
                #expect(outcomes.2 == .attemptedSucceeded)
                #expect(state.count() == 1)
            }
        }
    }
}
