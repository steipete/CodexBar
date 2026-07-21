import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsProfileCacheTests {
    private func makeCredentialsData(accessToken: String) -> Data {
        let expiresAt = Int(Date(timeIntervalSinceNow: 3600).timeIntervalSince1970 * 1000)
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
    func `legacy cache without profile identity fails closed`() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        let fileData = self.makeCredentialsData(accessToken: "file-token")
        try fileData.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: fileURL.path)
        let legacyCacheData = self.makeCredentialsData(accessToken: "legacy-cache-token")

        try self.withIsolatedCache {
            try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                let environment: [String: String] = [:]
                _ = ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged(environment: environment)
                KeychainCacheStore.store(
                    key: .oauth(provider: .claude),
                    entry: ClaudeOAuthCredentialsStore.CacheEntry(
                        data: legacyCacheData,
                        storedAt: Date(),
                        owner: .claudeCLI,
                        profileIdentifier: nil))

                let credentials = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                    .onlyOnUserAction)
                {
                    try ClaudeOAuthCredentialsStore.load(environment: environment, allowKeychainPrompt: false)
                }
                #expect(credentials.accessToken == "file-token")

                switch KeychainCacheStore.load(
                    key: .oauth(provider: .claude),
                    as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                {
                case let .found(entry):
                    #expect(entry.profileIdentifier != nil)
                    #expect(try ClaudeOAuthCredentials.parse(data: entry.data).accessToken == "file-token")
                case .missing, .invalid, .temporarilyUnavailable:
                    Issue.record("Expected the file-backed cache to replace the legacy entry")
                }
            }
        }
    }
}
