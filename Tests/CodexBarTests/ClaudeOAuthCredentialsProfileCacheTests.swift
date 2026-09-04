import Foundation
import Security
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsProfileCacheTests {
    private struct LegacyCacheEntry: Codable {
        let data: Data
        let storedAt: Date
        let owner: ClaudeOAuthCredentialOwner?
        let historyOwnerIdentifier: String?
    }

    private func makeCredentialsData(
        accessToken: String,
        expiresAt: Date = Date(timeIntervalSinceNow: 3600)) -> Data
    {
        let expiresAt = Int(expiresAt.timeIntervalSince1970 * 1000)
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(expiresAt),
            "scopes": ["user:profile"]
          }
        }
        """.utf8)
    }

    private func withIsolatedCache<T>(_ operation: () throws -> T) throws -> T {
        let service = "com.steipete.codexbar.cache.profile-tests.\(UUID().uuidString)"
        let pendingStore = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()
        return try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }
                return try ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(pendingStore) {
                    try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        try ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
                            try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting(operation: operation)
                        }
                    }
                }
            }
        }
    }

    private func profileIdentifier(environment: [String: String]) -> String {
        ClaudeOAuthCredentialsStore.withEnvironmentCredentialsURLForTesting {
            ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: environment)
        }
    }

    @Test
    func `newer cache from another profile never overrides older credentials file`() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileA = tempRoot.appendingPathComponent("profile-a", isDirectory: true)
        let profileB = tempRoot.appendingPathComponent("profile-b", isDirectory: true)
        try FileManager.default.createDirectory(at: profileA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let credentialsA = profileA.appendingPathComponent(".credentials.json")
        let credentialsB = profileB.appendingPathComponent(".credentials.json")
        try self.makeCredentialsData(accessToken: "profile-a-token").write(to: credentialsA)
        try self.makeCredentialsData(accessToken: "profile-b-token").write(to: credentialsB)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: credentialsB.path)

        let environmentA = ["CLAUDE_CONFIG_DIR": profileA.path]
        let environmentB = ["CLAUDE_CONFIG_DIR": profileB.path]
        let missingEnvironment = ["CLAUDE_CONFIG_DIR": tempRoot.appendingPathComponent("missing").path]

        try self.withIsolatedCache {
            ClaudeOAuthCredentialsStore.invalidateCache()
            let first = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                try ClaudeOAuthCredentialsStore.load(
                    environment: environmentA,
                    allowKeychainPrompt: false)
            }
            #expect(first.accessToken == "profile-a-token")

            // A's cache is newer than B's file. The profile identity, not freshness, must decide ownership.
            let second = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                try ClaudeOAuthCredentialsStore.load(
                    environment: environmentB,
                    allowKeychainPrompt: false)
            }
            #expect(second.accessToken == "profile-b-token")
            #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: missingEnvironment) == false)
        }
    }

    @Test
    func `profile caches survive switching Claude config directories`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileA = root.appendingPathComponent("profile-a", isDirectory: true)
        let profileB = root.appendingPathComponent("profile-b", isDirectory: true)
        try FileManager.default.createDirectory(at: profileA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environmentA = ["CLAUDE_CONFIG_DIR": profileA.path]
        let environmentB = ["CLAUDE_CONFIG_DIR": profileB.path]
        let identifierA = self.profileIdentifier(environment: environmentA)
        let identifierB = self.profileIdentifier(environment: environmentB)

        try self.withIsolatedCache {
            KeychainCacheStore.store(
                key: ClaudeOAuthCredentialsStore.cacheKeyForTesting(profileIdentifier: identifierA),
                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                    data: self.makeCredentialsData(accessToken: "profile-a-refresh-token"),
                    storedAt: Date(),
                    owner: .codexbar,
                    profileIdentifier: identifierA))
            KeychainCacheStore.store(
                key: ClaudeOAuthCredentialsStore.cacheKeyForTesting(profileIdentifier: identifierB),
                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                    data: self.makeCredentialsData(accessToken: "profile-b-refresh-token"),
                    storedAt: Date(),
                    owner: .codexbar,
                    profileIdentifier: identifierB))

            let first = try ClaudeOAuthCredentialsStore.loadRecord(
                environment: environmentA,
                allowKeychainPrompt: false,
                allowClaudeKeychainRepairWithoutPrompt: false)
            let second = try ClaudeOAuthCredentialsStore.loadRecord(
                environment: environmentB,
                allowKeychainPrompt: false,
                allowClaudeKeychainRepairWithoutPrompt: false)
            let resumed = try ClaudeOAuthCredentialsStore.loadRecord(
                environment: environmentA,
                allowKeychainPrompt: false,
                allowClaudeKeychainRepairWithoutPrompt: false)

            #expect(first.credentials.accessToken == "profile-a-refresh-token")
            #expect(second.credentials.accessToken == "profile-b-refresh-token")
            #expect(resumed.credentials.accessToken == "profile-a-refresh-token")
        }
    }

    @Test
    func `file fingerprint from one profile does not clear cache only sibling`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileA = root.appendingPathComponent("profile-a", isDirectory: true)
        let profileB = root.appendingPathComponent("profile-b", isDirectory: true)
        try FileManager.default.createDirectory(at: profileA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environmentA = ["CLAUDE_CONFIG_DIR": profileA.path]
        let environmentB = ["CLAUDE_CONFIG_DIR": profileB.path]
        let identifierB = self.profileIdentifier(environment: environmentB)
        try self.makeCredentialsData(accessToken: "profile-a-file-token")
            .write(to: profileA.appendingPathComponent(".credentials.json"))

        try self.withIsolatedCache {
            KeychainCacheStore.store(
                key: ClaudeOAuthCredentialsStore.cacheKeyForTesting(profileIdentifier: identifierB),
                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                    data: self.makeCredentialsData(accessToken: "profile-b-cache-token"),
                    storedAt: Date(),
                    owner: .codexbar,
                    profileIdentifier: identifierB))

            #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(
                environment: environmentA))
            #expect(!ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(
                environment: environmentB))

            let record = try ClaudeOAuthCredentialsStore.loadRecord(
                environment: environmentB,
                allowKeychainPrompt: false,
                allowClaudeKeychainRepairWithoutPrompt: false)
            #expect(record.credentials.accessToken == "profile-b-cache-token")
            #expect(record.source == .cacheKeychain)
        }
    }

    @Test
    func `invalidating one profile preserves another profile cache`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileA = root.appendingPathComponent("profile-a", isDirectory: true)
        let profileB = root.appendingPathComponent("profile-b", isDirectory: true)
        try FileManager.default.createDirectory(at: profileA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environmentA = ["CLAUDE_CONFIG_DIR": profileA.path]
        let environmentB = ["CLAUDE_CONFIG_DIR": profileB.path]
        let identifierA = self.profileIdentifier(environment: environmentA)
        let identifierB = self.profileIdentifier(environment: environmentB)

        try self.withIsolatedCache {
            KeychainCacheStore.store(
                key: ClaudeOAuthCredentialsStore.cacheKeyForTesting(profileIdentifier: identifierA),
                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                    data: self.makeCredentialsData(accessToken: "profile-a-token"),
                    storedAt: Date(),
                    owner: .codexbar,
                    profileIdentifier: identifierA))
            KeychainCacheStore.store(
                key: ClaudeOAuthCredentialsStore.cacheKeyForTesting(profileIdentifier: identifierB),
                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                    data: self.makeCredentialsData(accessToken: "profile-b-token"),
                    storedAt: Date(),
                    owner: .codexbar,
                    profileIdentifier: identifierB))

            ClaudeOAuthCredentialsStore.invalidateCache(environment: environmentA)

            #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: environmentA) == false)
            #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: environmentB) == true)
        }
    }

    @Test
    func `deferred cleanup for one profile does not erase another profile cache`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileA = root.appendingPathComponent("profile-a", isDirectory: true)
        let profileB = root.appendingPathComponent("profile-b", isDirectory: true)
        try FileManager.default.createDirectory(at: profileA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environmentA = ["CLAUDE_CONFIG_DIR": profileA.path]
        let environmentB = ["CLAUDE_CONFIG_DIR": profileB.path]
        let identifierA = self.profileIdentifier(environment: environmentA)
        let identifierB = self.profileIdentifier(environment: environmentB)

        try self.withIsolatedCache {
            KeychainCacheStore.store(
                key: ClaudeOAuthCredentialsStore.cacheKeyForTesting(profileIdentifier: identifierB),
                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                    data: self.makeCredentialsData(accessToken: "profile-b-token"),
                    storedAt: Date(),
                    owner: .codexbar,
                    profileIdentifier: identifierB))

            let pendingStore = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()
            pendingStore.markPending(profileIdentifier: identifierA)
            try ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(pendingStore) {
                let record = try ClaudeOAuthCredentialsStore.loadRecord(
                    environment: environmentB,
                    allowKeychainPrompt: false,
                    allowClaudeKeychainRepairWithoutPrompt: false)
                #expect(record.credentials.accessToken == "profile-b-token")
                #expect(pendingStore.isPending(profileIdentifier: identifierA))
                #expect(!pendingStore.isPending(profileIdentifier: identifierB))
            }
        }
    }

    @Test
    func `legacy default profile cache migrates without losing refreshed credentials`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        let fileModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cacheStoredAt = Date(timeIntervalSince1970: 1_700_000_100)
        let fileData = self.makeCredentialsData(
            accessToken: "expired-file-token",
            expiresAt: Date(timeIntervalSince1970: 1_600_000_000))
        try fileData.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: fileModifiedAt],
            ofItemAtPath: fileURL.path)
        let legacyCacheData = self.makeCredentialsData(accessToken: "legacy-refreshed-token")
        let historyOwnerIdentifier = String(repeating: "a", count: 64)
        let historicalProfileIdentifier = self.profileIdentifier(environment: [:])

        try self.withIsolatedCache {
            try ClaudeOAuthCredentialsStore.withCredentialsProfileIdentifierOverrideForTesting(
                historicalProfileIdentifier)
            {
                try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    let environment: [String: String] = [:]
                    KeychainCacheStore.store(
                        key: .oauth(provider: .claude),
                        entry: LegacyCacheEntry(
                            data: legacyCacheData,
                            storedAt: cacheStoredAt,
                            owner: .codexbar,
                            historyOwnerIdentifier: historyOwnerIdentifier))

                    let record = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                        .onlyOnUserAction)
                    {
                        try ClaudeOAuthCredentialsStore.loadRecord(
                            environment: environment,
                            allowKeychainPrompt: false,
                            allowClaudeKeychainRepairWithoutPrompt: false)
                    }
                    #expect(record.credentials.accessToken == "legacy-refreshed-token")
                    #expect(record.source == .cacheKeychain)

                    switch KeychainCacheStore.load(
                        key: ClaudeOAuthCredentialsStore.cacheKeyForTesting(
                            profileIdentifier: historicalProfileIdentifier),
                        as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                    {
                    case let .found(entry):
                        #expect(entry.data == legacyCacheData)
                        #expect(entry.storedAt == cacheStoredAt)
                        #expect(entry.owner == .codexbar)
                        #expect(entry.historyOwnerIdentifier == historyOwnerIdentifier)
                        #expect(entry.profileIdentifier == historicalProfileIdentifier)
                    case .interactionRequired, .missing, .invalid, .temporarilyUnavailable:
                        Issue.record("Expected the legacy default cache to be migrated to its profile key")
                    }
                }
            }
        }
    }

    @Test
    func `failed legacy deletion cannot resurrect after profile invalidation`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let missingCredentialsURL = tempDir.appendingPathComponent("missing-credentials.json")
        let historicalProfileIdentifier = self.profileIdentifier(environment: [:])
        let pendingStore = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()

        try self.withIsolatedCache {
            try ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(pendingStore) {
                try ClaudeOAuthCredentialsStore.withCredentialsProfileIdentifierOverrideForTesting(
                    historicalProfileIdentifier)
                {
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                        let legacyKey = KeychainCacheStore.Key.oauth(provider: .claude)
                        KeychainCacheStore.store(
                            key: legacyKey,
                            entry: LegacyCacheEntry(
                                data: self.makeCredentialsData(accessToken: "stale-legacy-token"),
                                storedAt: Date(),
                                owner: .codexbar,
                                historyOwnerIdentifier: nil))

                        let migrated = try KeychainCacheStore.withClearFailureStatusOverrideForTesting(
                            errSecInteractionNotAllowed)
                        {
                            try ClaudeOAuthCredentialsStore.loadRecord(
                                environment: [:],
                                allowKeychainPrompt: false,
                                allowClaudeKeychainRepairWithoutPrompt: false)
                        }
                        #expect(migrated.credentials.accessToken == "stale-legacy-token")
                        #expect(pendingStore.isPending(profileIdentifier: historicalProfileIdentifier))

                        ClaudeOAuthCredentialsStore.invalidateCache(environment: [:])

                        #expect(!pendingStore.isPending(profileIdentifier: historicalProfileIdentifier))
                        do {
                            _ = try ClaudeOAuthCredentialsStore.loadRecord(
                                environment: [:],
                                allowKeychainPrompt: false,
                                allowClaudeKeychainRepairWithoutPrompt: false)
                            Issue.record("Expected invalidation to prevent stale legacy cache re-import")
                        } catch let error as ClaudeOAuthCredentialsError {
                            guard case .notFound = error else {
                                Issue.record("Expected .notFound, got \(error)")
                                return
                            }
                        }

                        guard case .missing = KeychainCacheStore.load(
                            key: legacyKey,
                            as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                        else {
                            Issue.record("Expected deferred legacy cleanup to remove the stale cache")
                            return
                        }
                    }
                }
            }
        }
    }

    @Test
    func `pending legacy cleanup cannot shield migrated cache from file change`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentialsURL = root.appendingPathComponent("credentials.json")
        let historicalProfileIdentifier = self.profileIdentifier(environment: [:])
        let pendingStore = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()

        try self.withIsolatedCache {
            try ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(pendingStore) {
                try ClaudeOAuthCredentialsStore.withCredentialsProfileIdentifierOverrideForTesting(
                    historicalProfileIdentifier)
                {
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(credentialsURL) {
                        let legacyKey = KeychainCacheStore.Key.oauth(provider: .claude)
                        KeychainCacheStore.store(
                            key: legacyKey,
                            entry: LegacyCacheEntry(
                                data: self.makeCredentialsData(accessToken: "stale-legacy-token"),
                                storedAt: Date(),
                                owner: .codexbar,
                                historyOwnerIdentifier: nil))

                        _ = try KeychainCacheStore.withClearFailureStatusOverrideForTesting(
                            errSecInteractionNotAllowed)
                        {
                            try ClaudeOAuthCredentialsStore.loadRecord(
                                environment: [:],
                                allowKeychainPrompt: false,
                                allowClaudeKeychainRepairWithoutPrompt: false)
                        }
                        #expect(pendingStore.isPending(profileIdentifier: historicalProfileIdentifier))

                        try self.makeCredentialsData(accessToken: "changed-file-token").write(to: credentialsURL)
                        #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(environment: [:]))

                        let record = try ClaudeOAuthCredentialsStore.loadRecord(
                            environment: [:],
                            allowKeychainPrompt: false,
                            allowClaudeKeychainRepairWithoutPrompt: false)
                        #expect(record.credentials.accessToken == "changed-file-token")
                        #expect(record.source == .credentialsFile)
                    }
                }
            }
        }
    }

    @Test
    func `cache disabled invalidation conditionally retires legacy default entry`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingCredentialsURL = root.appendingPathComponent("missing-credentials.json")
        let historicalProfileIdentifier = self.profileIdentifier(environment: [:])
        let pendingStore = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()

        try self.withIsolatedCache {
            try ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(pendingStore) {
                try ClaudeOAuthCredentialsStore.withCredentialsProfileIdentifierOverrideForTesting(
                    historicalProfileIdentifier)
                {
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                        let legacyKey = KeychainCacheStore.Key.oauth(provider: .claude)
                        KeychainCacheStore.store(
                            key: legacyKey,
                            entry: LegacyCacheEntry(
                                data: self.makeCredentialsData(accessToken: "invalidated-legacy-token"),
                                storedAt: Date(),
                                owner: .codexbar,
                                historyOwnerIdentifier: nil))

                        ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                            ClaudeOAuthCredentialsStore.invalidateCache(environment: [:])
                        }
                        #expect(pendingStore.isPending(profileIdentifier: historicalProfileIdentifier))

                        do {
                            _ = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                                try ClaudeOAuthCredentialsStore.loadRecord(
                                    environment: [:],
                                    allowKeychainPrompt: false,
                                    allowClaudeKeychainRepairWithoutPrompt: false)
                            }
                            Issue.record("Expected invalidation to prevent legacy cache migration")
                        } catch let error as ClaudeOAuthCredentialsError {
                            guard case .notFound = error else {
                                Issue.record("Expected .notFound, got \(error)")
                                return
                            }
                        }

                        guard case .missing = KeychainCacheStore.load(key: legacyKey, as: LegacyCacheEntry.self) else {
                            Issue.record("Expected the invalidated legacy cache to be retired")
                            return
                        }
                    }
                }
            }
        }
    }

    @Test
    func `released fingerprint without path detects removed default credentials file`() throws {
        let releasedFingerprintData = Data(#"{"modifiedAtMs":1700000000000,"size":321}"#.utf8)
        let releasedFingerprint = try JSONDecoder().decode(
            ClaudeOAuthCredentialsStore.CredentialsFileFingerprint.self,
            from: releasedFingerprintData)
        let historicalCredentialsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json")
            .standardizedFileURL.path
        #expect(releasedFingerprint.path == historicalCredentialsPath)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingCredentialsURL = root.appendingPathComponent("removed-credentials.json")
        let historicalProfileIdentifier = self.profileIdentifier(environment: [:])
        let fingerprintStore = ClaudeOAuthCredentialsStore.CredentialsFileFingerprintStore(
            fingerprint: releasedFingerprint)

        try self.withIsolatedCache {
            ClaudeOAuthCredentialsStore.withCredentialsFileFingerprintStoreOverrideForTesting(
                fingerprintStore)
            {
                ClaudeOAuthCredentialsStore.withCredentialsProfileIdentifierOverrideForTesting(
                    historicalProfileIdentifier)
                {
                    ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(missingCredentialsURL) {
                        let profileKey = ClaudeOAuthCredentialsStore.cacheKeyForTesting(
                            profileIdentifier: historicalProfileIdentifier)
                        KeychainCacheStore.store(
                            key: profileKey,
                            entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                data: self.makeCredentialsData(accessToken: "removed-file-cache-token"),
                                storedAt: Date(),
                                owner: .codexbar,
                                profileIdentifier: historicalProfileIdentifier))

                        #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(
                            environment: [:]))
                        guard case .missing = KeychainCacheStore.load(
                            key: profileKey,
                            as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                        else {
                            Issue.record("Expected the removed default credentials file to invalidate its cache")
                            return
                        }
                    }
                }
            }
        }
    }

    @Test
    func `legacy cache without profile identity fails closed for custom profile`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent(".credentials.json")
        let fileData = self.makeCredentialsData(accessToken: "file-token")
        try fileData.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: fileURL.path)
        let legacyCacheData = self.makeCredentialsData(accessToken: "legacy-cache-token")

        try self.withIsolatedCache {
            let environment = ["CLAUDE_CONFIG_DIR": tempDir.path]
            _ = ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(environment: environment)
            KeychainCacheStore.store(
                key: .oauth(provider: .claude),
                entry: LegacyCacheEntry(
                    data: legacyCacheData,
                    storedAt: Date(),
                    owner: .claudeCLI,
                    historyOwnerIdentifier: nil))

            let record = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                .onlyOnUserAction)
            {
                try ClaudeOAuthCredentialsStore.loadRecord(
                    environment: environment,
                    allowKeychainPrompt: false,
                    allowClaudeKeychainRepairWithoutPrompt: false)
            }
            #expect(record.credentials.accessToken == "file-token")
            #expect(record.source == .credentialsFile)

            switch KeychainCacheStore.load(
                key: ClaudeOAuthCredentialsStore.cacheKeyForTesting(
                    profileIdentifier: self.profileIdentifier(environment: environment)),
                as: ClaudeOAuthCredentialsStore.CacheEntry.self)
            {
            case let .found(entry):
                #expect(entry.profileIdentifier == self.profileIdentifier(environment: environment))
                #expect(try ClaudeOAuthCredentials.parse(data: entry.data).accessToken == "file-token")
            case .interactionRequired, .missing, .invalid, .temporarilyUnavailable:
                Issue.record("Expected the custom profile file to populate its own cache entry")
            }
        }
    }

    @Test
    func `rejected credentials file stays quarantined per profile until its fingerprint changes`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profileA = root.appendingPathComponent("profile-a", isDirectory: true)
        let profileB = root.appendingPathComponent("profile-b", isDirectory: true)
        try FileManager.default.createDirectory(at: profileA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: profileB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let environmentA = ["CLAUDE_CONFIG_DIR": profileA.path]
        let environmentB = ["CLAUDE_CONFIG_DIR": profileB.path]
        let fileA = profileA.appendingPathComponent(".credentials.json")
        let fileB = profileB.appendingPathComponent(".credentials.json")
        let staleA = self.makeCredentialsData(accessToken: "stale-profile-a-token")
        let freshA = self.makeCredentialsData(accessToken: "fresh-profile-a-token-with-new-size")
        let profileBData = self.makeCredentialsData(accessToken: "profile-b-token")
        try staleA.write(to: fileA)
        try profileBData.write(to: fileB)

        try self.withIsolatedCache {
            #expect(ClaudeOAuthCredentialsStore.quarantineCurrentCredentialsFileForOAuth(
                environment: environmentA))
            #expect(ClaudeOAuthCredentialsStore.isCurrentCredentialsFileQuarantinedForOAuth(
                environment: environmentA))
            #expect(!ClaudeOAuthCredentialsStore.isCurrentCredentialsFileQuarantinedForOAuth(
                environment: environmentB))
            #expect(try ClaudeOAuthCredentialsStore.loadFromFile(environment: environmentB) == profileBData)
            let error = #expect(throws: ClaudeOAuthCredentialsError.self) {
                try ClaudeOAuthCredentialsStore.loadFromFile(environment: environmentA)
            }
            guard case .notFound = error else {
                Issue.record("Expected the quarantined file to fail closed as not found")
                return
            }

            try freshA.write(to: fileA)

            #expect(!ClaudeOAuthCredentialsStore.isCurrentCredentialsFileQuarantinedForOAuth(
                environment: environmentA))
            #expect(try ClaudeOAuthCredentialsStore.loadFromFile(environment: environmentA) == freshA)
        }
    }
}
