#if os(macOS)
import Foundation
import Security
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthPromptCoalescingTests {
    private enum BarrierError: Error {
        case timedOut
    }

    private enum LoadOutcome: Equatable {
        case keychainError(Int)
        case notFound
        case unexpected(String)
    }

    private final class ConcurrentPromptReadState: @unchecked Sendable {
        private let condition = NSCondition()
        private var entrants = 0
        private var reads = 0

        func enterPromptPath() {
            self.condition.lock()
            self.entrants += 1
            self.condition.broadcast()
            self.condition.unlock()
        }

        func beginRead() throws {
            self.condition.lock()
            defer { self.condition.unlock() }
            self.reads += 1
            guard self.reads == 1 else { return }

            let deadline = Date(timeIntervalSinceNow: 5)
            while self.entrants < 2, self.condition.wait(until: deadline) {}
            guard self.entrants >= 2 else { throw BarrierError.timedOut }
        }

        var readCount: Int {
            self.condition.lock()
            defer { self.condition.unlock() }
            return self.reads
        }
    }

    @Test
    func `concurrent expired credential loads share one interactive keychain read`() async throws {
        try await self.verifySuccessfulFanout(expiresIn: -3600)
    }

    @Test
    func `concurrent valid credential loads replay the exact interactive result`() async throws {
        try await self.verifySuccessfulFanout(expiresIn: 3600)
    }

    @Test
    func `denial is replayed within one request and a new user request retries`() async throws {
        let state = ConcurrentPromptReadState()
        let deniedStore = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
        let status = Int(errSecUserCanceled)

        let outcomes = try await self.withPromptEnvironment(
            state: state,
            deniedStore: deniedStore,
            read: {
                try state.beginRead()
                ClaudeOAuthKeychainAccessGate.recordDenied()
                throw ClaudeOAuthCredentialsError.keychainError(status)
            },
            operation: { loadRecord in
                let sameRequest = await ProviderRefreshRequestContext.$id.withValue(UUID()) {
                    async let first = self.loadOutcome(using: loadRecord)
                    async let second = self.loadOutcome(using: loadRecord)
                    let concurrent = await (first, second)
                    let late = self.loadOutcome(using: loadRecord)
                    return (concurrent.0, concurrent.1, late)
                }
                #expect(state.readCount == 1)
                #expect(ClaudeOAuthKeychainAccessGate.clearDenied())
                let nextRequest = ProviderRefreshRequestContext.$id.withValue(UUID()) {
                    self.loadOutcome(using: loadRecord)
                }
                return (sameRequest.0, sameRequest.1, sameRequest.2, nextRequest)
            })

        let expected = LoadOutcome.keychainError(status)
        #expect(outcomes.0 == expected)
        #expect(outcomes.1 == expected)
        #expect(outcomes.2 == expected)
        #expect(outcomes.3 == expected)
        #expect(state.readCount == 2)
    }

    @Test
    func `prompt failure is not replayed after policy changes`() async throws {
        let state = ConcurrentPromptReadState()
        let deniedStore = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
        let status = Int(errSecUserCanceled)

        let outcomes = try await self.withPromptEnvironment(
            state: state,
            deniedStore: deniedStore,
            read: {
                try state.beginRead()
                ClaudeOAuthKeychainAccessGate.recordDenied()
                throw ClaudeOAuthCredentialsError.keychainError(status)
            },
            operation: { loadRecord in
                await ProviderRefreshRequestContext.$id.withValue(UUID()) {
                    async let first = self.loadOutcome(using: loadRecord)
                    async let second = self.loadOutcome(using: loadRecord)
                    let concurrent = await (first, second)
                    #expect(ClaudeOAuthKeychainAccessGate.clearDenied())
                    let afterPolicyChange = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                        self.loadOutcome(using: loadRecord)
                    }
                    return (concurrent.0, concurrent.1, afterPolicyChange)
                }
            })

        let expected = LoadOutcome.keychainError(status)
        #expect(outcomes.0 == expected)
        #expect(outcomes.1 == expected)
        #expect(outcomes.2 == .notFound)
        #expect(state.readCount == 1)
    }

    @Test
    func `credential invalidation starts a fresh prompt outcome generation`() async throws {
        let state = ConcurrentPromptReadState()
        let deniedStore = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
        let status = Int(errSecUserCanceled)
        let credentialsData = self.makeCredentialsData(expiresIn: 3600)

        let outcomes = try await self.withPromptEnvironment(
            state: state,
            deniedStore: deniedStore,
            read: {
                try state.beginRead()
                if state.readCount == 1 {
                    ClaudeOAuthKeychainAccessGate.recordDenied()
                    throw ClaudeOAuthCredentialsError.keychainError(status)
                }
                return credentialsData
            },
            operation: { loadRecord in
                try await ProviderRefreshRequestContext.$id.withValue(UUID()) {
                    async let first = self.loadOutcome(using: loadRecord)
                    async let second = self.loadOutcome(using: loadRecord)
                    let concurrent = await (first, second)
                    #expect(ClaudeOAuthKeychainAccessGate.clearDenied())
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    let afterInvalidation = try loadRecord()
                    return (concurrent.0, concurrent.1, afterInvalidation)
                }
            })

        let expected = LoadOutcome.keychainError(status)
        #expect(outcomes.0 == expected)
        #expect(outcomes.1 == expected)
        #expect(outcomes.2.credentials.accessToken == "shared-interactive-read")
        #expect(outcomes.2.source == .claudeKeychain)
        #expect(state.readCount == 2)
    }

    private func verifySuccessfulFanout(expiresIn: TimeInterval) async throws {
        let state = ConcurrentPromptReadState()
        let deniedStore = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
        let credentialsData = self.makeCredentialsData(expiresIn: expiresIn)

        let records = try await self.withPromptEnvironment(
            state: state,
            deniedStore: deniedStore,
            read: {
                try state.beginRead()
                return credentialsData
            },
            operation: { loadRecord in
                try await ProviderRefreshRequestContext.$id.withValue(UUID()) {
                    async let first = loadRecord()
                    async let second = loadRecord()
                    let concurrentRecords = try await (first, second)
                    let lateRecord = try loadRecord()
                    return (concurrentRecords.0, concurrentRecords.1, lateRecord)
                }
            })

        #expect(records.0.credentials.accessToken == "shared-interactive-read")
        #expect(records.1.credentials.accessToken == "shared-interactive-read")
        #expect(records.2.credentials.accessToken == "shared-interactive-read")
        #expect(records.0.source == .claudeKeychain)
        #expect(records.1.source == .claudeKeychain)
        #expect(records.2.source == .claudeKeychain)
        #expect(state.readCount == 1)
    }

    private func withPromptEnvironment<T>(
        state: ConcurrentPromptReadState,
        deniedStore: ClaudeOAuthKeychainAccessGate.DeniedUntilStore,
        read: @escaping @Sendable () throws -> Data,
        operation: (_ loadRecord: @Sendable () throws -> ClaudeOAuthCredentialRecord) async throws -> T) async throws
        -> T
    {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let missingCredentialsURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let beforePromptLock: @Sendable () -> Void = { state.enterPromptPath() }
        return try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }
                return try await ClaudeOAuthKeychainAccessGate.withDeniedUntilStoreOverrideForTesting(deniedStore) {
                    try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                        try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                            try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                                try await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                                    .securityFramework)
                                {
                                    try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                                        .onlyOnUserAction)
                                    {
                                        try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                            try await ClaudeOAuthCredentialsStore
                                                .withInteractiveClaudeKeychainReadOverridesForTesting(
                                                    beforePromptLock: beforePromptLock,
                                                    read: read)
                                                {
                                                    try await operation {
                                                        try ClaudeOAuthCredentialsStore.loadRecord(
                                                            environment: [:],
                                                            allowKeychainPrompt: true,
                                                            respectKeychainPromptCooldown: true,
                                                            allowClaudeKeychainRepairWithoutPrompt: false)
                                                    }
                                                }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func makeCredentialsData(expiresIn: TimeInterval) -> Data {
        let expiresAt = Int(Date(timeIntervalSinceNow: expiresIn).timeIntervalSince1970 * 1000)
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "shared-interactive-read",
            "expiresAt": \(expiresAt),
            "scopes": ["user:profile"],
            "refreshToken": "refresh"
          }
        }
        """.utf8)
    }

    private func loadOutcome(
        using loadRecord: @Sendable () throws -> ClaudeOAuthCredentialRecord) -> LoadOutcome
    {
        do {
            _ = try loadRecord()
            return .unexpected("record")
        } catch let error as ClaudeOAuthCredentialsError {
            if case let .keychainError(status) = error {
                return .keychainError(status)
            }
            if case .notFound = error {
                return .notFound
            }
            return .unexpected(String(describing: error))
        } catch {
            return .unexpected(String(reflecting: type(of: error)))
        }
    }
}
#endif
