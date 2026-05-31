import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreCLIStorageOwnershipTests {
    private func makeCredentialsData(accessToken: String, expiresAt: Date, refreshToken: String? = nil) -> Data {
        let millis = Int(expiresAt.timeIntervalSince1970 * 1000)
        let refreshField: String = {
            guard let refreshToken else { return "" }
            return ",\n            \"refreshToken\": \"\(refreshToken)\""
        }()
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "\(accessToken)",
            "expiresAt": \(millis),
            "scopes": ["user:profile"]\(refreshField)
          }
        }
        """
        return Data(json.utf8)
    }

    @Test
    func `load record treats codexbar cache as claude CLI owned when credentials file exists`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("credentials.json")
            try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            let fileData = self.makeCredentialsData(
                                accessToken: "claude-cli-file",
                                expiresAt: Date(timeIntervalSinceNow: 3600),
                                refreshToken: "cli-refresh-token")
                            try fileData.write(to: fileURL)

                            let cachedData = self.makeCredentialsData(
                                accessToken: "codexbar-cache",
                                expiresAt: Date(timeIntervalSinceNow: 3600),
                                refreshToken: "cached-refresh-token")
                            KeychainCacheStore.store(
                                key: cacheKey,
                                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: cachedData,
                                    storedAt: Date(timeIntervalSinceNow: 60),
                                    owner: .codexbar))

                            let record = try ClaudeOAuthCredentialsStore.loadRecord(
                                environment: [:],
                                allowKeychainPrompt: false,
                                respectKeychainPromptCooldown: true,
                                allowClaudeKeychainRepairWithoutPrompt: false)

                            #expect(record.credentials.accessToken == "codexbar-cache")
                            #expect(record.owner == .claudeCLI)
                            #expect(record.source == .cacheKeychain)
                        }
                    }
                }
            }
        }
    }

    @Test
    func `load with auto refresh delegates expired codexbar cache when credentials file exists`() async throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("credentials.json")
            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            try Data("not valid credentials".utf8).write(to: fileURL)

                            let expiredData = self.makeCredentialsData(
                                accessToken: "expired-codexbar-with-file",
                                expiresAt: Date(timeIntervalSinceNow: -3600),
                                refreshToken: "cached-refresh-token")
                            KeychainCacheStore.store(
                                key: cacheKey,
                                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: expiredData,
                                    storedAt: Date(timeIntervalSinceNow: 60),
                                    owner: .codexbar))

                            await ClaudeOAuthRefreshFailureGate.$shouldAttemptOverride.withValue(false) {
                                do {
                                    _ = try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
                                        environment: [:],
                                        allowKeychainPrompt: false,
                                        respectKeychainPromptCooldown: true)
                                    Issue.record("Expected delegated refresh error when Claude CLI file is present")
                                } catch let error as ClaudeOAuthCredentialsError {
                                    guard case .refreshDelegatedToClaudeCLI = error else {
                                        Issue.record("Expected .refreshDelegatedToClaudeCLI, got \(error)")
                                        return
                                    }
                                } catch {
                                    Issue.record("Expected ClaudeOAuthCredentialsError, got \(error)")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `load record treats codexbar cache as claude CLI owned when Claude keychain item exists`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("credentials.json")
            try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                        defer { KeychainCacheStore.clear(key: cacheKey) }

                        let cachedData = self.makeCredentialsData(
                            accessToken: "codexbar-cache",
                            expiresAt: Date(timeIntervalSinceNow: 3600),
                            refreshToken: "cached-refresh-token")
                        KeychainCacheStore.store(
                            key: cacheKey,
                            entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                data: cachedData,
                                storedAt: Date(),
                                owner: .codexbar))

                        let keychainData = self.makeCredentialsData(
                            accessToken: "claude-keychain",
                            expiresAt: Date(timeIntervalSinceNow: 3600),
                            refreshToken: "keychain-refresh-token")

                        let record = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: keychainData,
                                fingerprint: nil)
                            {
                                try ClaudeOAuthCredentialsStore.loadRecord(
                                    environment: [:],
                                    allowKeychainPrompt: false,
                                    respectKeychainPromptCooldown: true,
                                    allowClaudeKeychainRepairWithoutPrompt: false)
                            }
                        }

                        #expect(record.credentials.accessToken == "codexbar-cache")
                        #expect(record.owner == .claudeCLI)
                        #expect(record.source == .cacheKeychain)
                    }
                }
            }
        }
    }
}
