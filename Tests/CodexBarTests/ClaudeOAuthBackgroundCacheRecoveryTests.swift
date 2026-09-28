#if os(macOS)
import Foundation
import Security
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthBackgroundCacheRecoveryTests {
    enum CacheScenario: CaseIterable {
        case available, writeRejected, writeRejectedWithoutExpiry, temporarilyUnavailable, memoryOlderThanThirtyMinutes
        case expiredFile, expiredMemory, invalidated, neverPrompt, pendingInvalidation, profileChanged

        var rejectsWrite: Bool {
            self == .writeRejected || self == .writeRejectedWithoutExpiry
        }

        var expectsRecovery: Bool {
            switch self {
            case .available, .writeRejected, .temporarilyUnavailable,
                 .memoryOlderThanThirtyMinutes, .expiredFile: true
            default: false
            }
        }
    }

    @Test(arguments: CacheScenario.allCases)
    func `automatic refresh retains valid manual credentials while honoring invalidation`(
        scenario: CacheScenario) async throws
    {
        let memory = ClaudeOAuthCredentialsStore.MemoryCacheStore()
        let denied = ClaudeOAuthKeychainAccessGate.DeniedUntilStore()
        let pending = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()
        let service = "com.steipete.codexbar.cache.background-tests.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path, "CLAUDE_CONFIG_DIR": root.path]
        let data = self.credentialsData(expiresIn: scenario == .writeRejectedWithoutExpiry ? nil : 7200)

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }
            try await KeychainAccessGate.withTaskOverrideForTesting(false) {
                try await ClaudeOAuthDirectKeychainReadConsent.withTaskOverrideForTesting(true) {
                    try await ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        try await ClaudeOAuthKeychainReadStrategyPreference
                            .withTaskOverrideForTesting(.securityFramework) {
                                try await ClaudeOAuthKeychainAccessGate.withDeniedUntilStoreOverrideForTesting(denied) {
                                    try await ClaudeOAuthCredentialsStore
                                        .withPendingCacheClearStoreOverrideForTesting(pending) {
                                            try await ClaudeOAuthCredentialsStore
                                                .withIsolatedCredentialsFileTrackingForTesting {
                                                    try await ClaudeOAuthCredentialsStore
                                                        .withCredentialsURLOverrideForTesting(
                                                            root.appendingPathComponent(".credentials.json"))
                                                        {
                                                            try await ClaudeOAuthCredentialsStore
                                                                .$taskMemoryCacheStoreOverride
                                                                .withValue(memory) {
                                                                    try await self.verifyRecovery(
                                                                        scenario: scenario,
                                                                        environment: environment,
                                                                        data: data,
                                                                        memory: memory,
                                                                        pending: pending)
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

    private func verifyRecovery(
        scenario: CacheScenario,
        environment: [String: String],
        data: Data,
        memory: ClaudeOAuthCredentialsStore.MemoryCacheStore,
        pending: ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore) async throws
    {
        if scenario == .expiredFile {
            try self.credentialsData(expiresIn: -3600)
                .write(to: ClaudeOAuthCredentialsStore.resolvedCredentialsURLForTesting)
            #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(environment: environment))
        }
        let loadFailure: OSStatus? = scenario == .available || scenario.rejectsWrite
            ? nil : errSecInteractionNotAllowed
        let interactiveRead: @Sendable () throws -> Data = { data }
        try await KeychainCacheStore.withLoadFailureStatusOverrideForTesting(loadFailure) {
            try await ClaudeOAuthCredentialsStore.withInteractiveClaudeKeychainReadOverridesForTesting(
                read: interactiveRead)
            {
                try KeychainCacheStore.withStoreFailureStatusOverrideForTesting(
                    scenario.rejectsWrite ? errSecInteractionNotAllowed : nil)
                {
                    let manual = try ProviderInteractionContext.$current.withValue(.userInitiated) {
                        try ClaudeOAuthCredentialsStore.loadRecord(
                            environment: environment,
                            allowKeychainPrompt: true,
                            respectKeychainPromptCooldown: false,
                            allowClaudeKeychainRepairWithoutPrompt: false)
                    }
                    #expect(manual.credentials.accessToken == "synthetic-manual-token")
                    #expect(manual.source == .claudeKeychain)
                    #expect(memory.record?.credentials.accessToken == "synthetic-manual-token")
                }
            }
            if scenario != .available, scenario != .temporarilyUnavailable, !scenario.rejectsWrite {
                memory.timestamp = Date(timeIntervalSinceNow: -1860)
            }
            if scenario == .expiredMemory {
                memory.record = try ClaudeOAuthCredentialRecord(
                    credentials: ClaudeOAuthCredentials.parse(data: self.credentialsData(expiresIn: -60)),
                    owner: .claudeCLI,
                    source: .memoryCache)
            }
            if scenario == .invalidated {
                ClaudeOAuthCredentialsStore.invalidateCache(environment: environment)
            }
            if scenario == .profileChanged {
                memory.profileIdentifier = "different-synthetic-profile"
            }
            if scenario == .pendingInvalidation {
                pending.markPending()
            }
            try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                Issue.record("Recovery must not probe the foreign Keychain item")
                return .interactionRequired
            } operation: {
                try KeychainCacheStore.withClearFailureStatusOverrideForTesting(
                    scenario == .pendingInvalidation ? errSecInteractionNotAllowed : nil)
                {
                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                        scenario == .neverPrompt ? .never : .onlyOnUserAction)
                    {
                        try ProviderInteractionContext.$current.withValue(.background) {
                            let load = {
                                try ClaudeOAuthCredentialsStore.loadRecord(
                                    environment: environment,
                                    allowKeychainPrompt: false,
                                    respectKeychainPromptCooldown: true,
                                    allowClaudeKeychainRepairWithoutPrompt: false)
                            }
                            if scenario.expectsRecovery {
                                let automatic = try load()
                                #expect(automatic.credentials.accessToken == "synthetic-manual-token")
                                #expect(automatic.source == .memoryCache)
                                if scenario.rejectsWrite {
                                    let profile = try #require(memory.profileIdentifier)
                                    let key = ClaudeOAuthCredentialsStore.cacheKeyForTesting(profileIdentifier: profile)
                                    guard case let .found(entry) = KeychainCacheStore.load(
                                        key: key, as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                                    else {
                                        Issue.record("Recovered credentials must be persisted for subsequent refreshes")
                                        return
                                    }
                                    let persisted = try ClaudeOAuthCredentials.parse(data: entry.data)
                                    #expect(persisted.accessToken == automatic.credentials.accessToken)
                                    #expect(persisted.expiresAt == automatic.credentials.expiresAt)
                                    #expect(entry.owner == .claudeCLI)
                                }
                            } else {
                                // Pending invalidation must be cleared before a retained credential can be reused.
                                #expect(throws: ClaudeOAuthCredentialsError.self, performing: load)
                            }
                        }
                    }
                }
            }
        }
    }

    private func credentialsData(expiresIn: TimeInterval? = 7200) -> Data {
        let expiry = expiresIn.map { Int(Date(timeIntervalSinceNow: $0).timeIntervalSince1970 * 1000) }
        let expiryField = expiry.map { "\"expiresAt\":\($0)," } ?? ""
        return Data("""
        {"claudeAiOauth":{"accessToken":"synthetic-manual-token",
        \(expiryField)
        "scopes":["user:profile"]}}
        """.utf8)
    }
}
#endif
