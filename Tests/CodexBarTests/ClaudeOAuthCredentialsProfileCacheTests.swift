import Foundation
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
                        try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting(operation: operation)
                    }
                }
            }
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
        let historicalProfileIdentifier = ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(environment: [:])

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
                        key: .oauth(provider: .claude),
                        as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                    {
                    case let .found(entry):
                        #expect(entry.data == legacyCacheData)
                        #expect(entry.storedAt == cacheStoredAt)
                        #expect(entry.owner == .codexbar)
                        #expect(entry.historyOwnerIdentifier == historyOwnerIdentifier)
                        #expect(entry.profileIdentifier == historicalProfileIdentifier)
                    case .missing, .invalid, .temporarilyUnavailable:
                        Issue.record("Expected the legacy default cache to be migrated in place")
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
                key: .oauth(provider: .claude),
                as: ClaudeOAuthCredentialsStore.CacheEntry.self)
            {
            case let .found(entry):
                #expect(entry.profileIdentifier == ClaudeOAuthCredentialsStore.credentialsProfileIdentifier(
                    environment: environment))
                #expect(try ClaudeOAuthCredentials.parse(data: entry.data).accessToken == "file-token")
            case .missing, .invalid, .temporarilyUnavailable:
                Issue.record("Expected the custom profile file to replace the legacy entry")
            }
        }
    }
}
