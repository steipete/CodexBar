#if os(macOS)
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import CodexBarCore

struct KeychainCacheRecoveryTests {
    private func withMutations<T>(
        _ mutation: @escaping @Sendable (KeychainSecurity.Mutation, [String: Any]) -> OSStatus,
        operation: () throws -> T) rethrows -> T
    {
        try KeychainSecurity.$mutationOverrideForTesting.withValue(mutation, operation: operation)
    }

    @Test(arguments: [false, true], [errSecSuccess, errSecDuplicateItem])
    func `fresh credentials replace a rejected cache ACL without reading its secret`(
        readFirst: Bool, addStatus: OSStatus)
    {
        let service = "cache-recovery-\(UUID().uuidString)"
        let key = KeychainCacheStore.Key(category: "oauth", identifier: "claude")
        let preflights = LockIsolated(0)
        let mutations = LockIsolated<[KeychainSecurity.Mutation]>([])
        let overlappingWrite = LockIsolated(false)
        KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.withRealKeychainPathForTesting {
                KeychainAccessGate.withTaskOverrideForTesting(false) {
                    KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                        preflights.setValue(preflights.value + 1)
                        return preflights.value == 1 ? .interactionRequired : .allowed
                    } operation: {
                        self.withMutations { mutation, query in
                            mutations.setValue(mutations.value + [mutation])
                            #expect(query[kSecAttrService as String] as? String == service)
                            #expect(query[kSecAttrAccount as String] as? String == "oauth.claude")
                            #expect(query[kSecReturnData as String] == nil)
                            #expect(query[kSecUseAuthenticationUI as String] as? String ==
                                KeychainNoUIQuery.uiFailPolicyForTesting())
                            #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?
                                .interactionNotAllowed == true)
                            if mutation == .add {
                                if !overlappingWrite.value {
                                    overlappingWrite.setValue(true)
                                    #expect(!KeychainCacheStore.storeResult(key: key, entry: "overlapping"))
                                }
                                #expect(query[kSecValueData as String] as? Data == Data("\"fresh\"".utf8))
                            }
                            return mutation == .add ? addStatus : errSecSuccess
                        } operation: {
                            if readFirst {
                                guard case .interactionRequired = KeychainCacheStore.load(key: key, as: String.self)
                                else { Issue.record("The stale cache must not be read"); return }
                            }
                            #expect(KeychainCacheStore.storeResult(key: key, entry: "fresh"))
                            #expect(KeychainCacheStore.interactionRequiredRetryDate(for: key) == nil)
                        }
                    }
                }
            }
        }
        #expect(preflights.value == (addStatus == errSecDuplicateItem ? 2 : 1))
        #expect(mutations.value == (addStatus == errSecDuplicateItem ? [.delete, .add, .update] : [.delete, .add]))
    }

    @Test
    func `Claude file fallback repopulates a cache whose ACL rejects this build`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("credentials.json")
        let payload = Data("""
        {"claudeAiOauth":{"accessToken":"synthetic-fresh","expiresAt":4102444800000,"scopes":["user:profile"]}}
        """.utf8)
        try payload.write(to: file)
        let stored = LockIsolated<Data?>(nil)
        try KeychainCacheStore.withServiceOverrideForTesting("cache-claude-recovery-\(UUID().uuidString)") {
            try KeychainCacheStore.withRealKeychainPathForTesting {
                try KeychainAccessGate.withTaskOverrideForTesting(false) {
                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                            try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                                try ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(
                                    ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore())
                                {
                                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(file) {
                                        try KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                                            .interactionRequired
                                        } operation: {
                                            try self.withMutations { mutation, query in
                                                if mutation == .add {
                                                    stored.setValue(query[kSecValueData as String] as? Data)
                                                }
                                                return errSecSuccess
                                            } operation: {
                                                let credentials = try ClaudeOAuthCredentialsStore.load(
                                                    environment: [:], allowKeychainPrompt: false)
                                                #expect(credentials.accessToken == "synthetic-fresh")
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(ClaudeOAuthCredentialsStore.CacheEntry.self, from: #require(stored.value))
        #expect(entry.data == payload)
        #expect(entry.owner == .claudeCLI)
    }

    @Test
    func `clearing a rejected cache invalidates the operation preflight memo`() {
        let key = KeychainCacheStore.Key(category: "oauth", identifier: "claude")
        let preflights = LockIsolated(0)
        KeychainCacheStore.withServiceOverrideForTesting("cache-memo-recovery-\(UUID().uuidString)") {
            KeychainCacheStore.withRealKeychainPathForTesting {
                KeychainAccessGate.withTaskOverrideForTesting(false) {
                    KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                        preflights.setValue(preflights.value + 1)
                        return preflights.value == 1 ? .interactionRequired : .notFound
                    } operation: {
                        self.withMutations { _, _ in
                            errSecSuccess
                        } operation: {
                            KeychainAccessPreflight.withMemoizedGenericPasswordChecks {
                                _ = KeychainCacheStore.load(key: key, as: String.self)
                                #expect(KeychainCacheStore.clearResult(key: key) == .removed)
                                guard case .missing = KeychainCacheStore.load(key: key, as: String.self)
                                else { Issue.record("Deleted items must not reuse an earlier ACL rejection"); return }
                            }
                        }
                    }
                }
            }
        }
        #expect(preflights.value == 2)
    }

    @Test
    func `temporary direct delete failure does not invent a stable ACL rejection`() {
        let key = KeychainCacheStore.Key(category: "oauth", identifier: "claude")
        let deletes = LockIsolated(0)
        KeychainCacheStore.withServiceOverrideForTesting("cache-transient-clear-\(UUID().uuidString)") {
            KeychainCacheStore.withRealKeychainPathForTesting {
                KeychainAccessGate.withTaskOverrideForTesting(false) {
                    self.withMutations { mutation, _ in
                        #expect(mutation == .delete)
                        deletes.setValue(deletes.value + 1)
                        return errSecInteractionNotAllowed
                    } operation: {
                        #expect(KeychainCacheStore.clearResult(key: key) == .failed)
                        #expect(KeychainCacheStore.clearResult(key: key) == .failed)
                        #expect(KeychainCacheStore.interactionRequiredRetryDate(for: key) == nil)
                    }
                }
            }
        }
        #expect(deletes.value == 2)
    }

    @Test(arguments: [KeychainSecurity.Mutation.delete, .add])
    func `failed cache replacement is throttled without extending the ACL cooldown`(
        failingOperation: KeychainSecurity.Mutation)
    {
        let key = KeychainCacheStore.Key(category: "oauth", identifier: "claude")
        let now = Date(timeIntervalSince1970: 1000)
        let preflights = LockIsolated(0)
        let mutations = LockIsolated<[KeychainSecurity.Mutation]>([])
        KeychainCacheStore.withServiceOverrideForTesting("cache-repair-failure-\(UUID().uuidString)") {
            KeychainCacheStore.withRealKeychainPathForTesting {
                KeychainAccessGate.withTaskOverrideForTesting(false) {
                    KeychainAccessPreflight.withCheckGenericPasswordOverrideForTesting { _, _ in
                        preflights.setValue(preflights.value + 1)
                        return preflights.value == 1 || failingOperation == .delete ? .interactionRequired : .notFound
                    } operation: {
                        self.withMutations { mutation, _ in
                            mutations.setValue(mutations.value + [mutation])
                            return mutation == failingOperation ? errSecInteractionNotAllowed : errSecSuccess
                        } operation: {
                            for elapsed in [0.0, 1, 299, 300, 301, 599] {
                                KeychainCacheStore.$taskInteractionRequiredNowOverride.withValue(
                                    now.addingTimeInterval(elapsed))
                                {
                                    _ = KeychainCacheStore.load(key: key, as: String.self)
                                    #expect(!KeychainCacheStore.storeResult(key: key, entry: "fresh"))
                                    #expect(KeychainCacheStore.clearResult(key: key) == .failed)
                                    #expect(KeychainCacheStore.interactionRequiredRetryDate(for: key) ==
                                        now.addingTimeInterval(elapsed < 300 ? 300 : 600))
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(preflights.value == (failingOperation == .add ? 3 : 2))
        #expect(mutations.value.filter { $0 == .delete }.count == (failingOperation == .add ? 1 : 2))
        #expect(mutations.value.filter { $0 == .add }.count == (failingOperation == .add ? 2 : 0))
    }
}
#endif
