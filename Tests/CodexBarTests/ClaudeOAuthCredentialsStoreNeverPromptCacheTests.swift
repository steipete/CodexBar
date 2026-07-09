import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreNeverPromptCacheTests {
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
    func `never prompt mode load prefers credentials file over codexbar oauth keychain cache in background`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    let fileData = self.makeCredentialsData(
                        accessToken: "file-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    try fileData.write(to: fileURL)

                    let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                    let cacheData = self.makeCredentialsData(
                        accessToken: "cached-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    KeychainCacheStore.store(
                        key: cacheKey,
                        entry: ClaudeOAuthCredentialsStore.CacheEntry(data: cacheData, storedAt: Date()))
                    defer { KeychainCacheStore.clear(key: cacheKey) }

                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let creds = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                            try ProviderInteractionContext.$current.withValue(.background) {
                                try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                            }
                        }
                        #expect(creds.accessToken == "file-token")
                    }
                }
            }
        }
    }

    @Test
    func `never prompt mode load does not write codexbar oauth keychain cache`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    let fileData = self.makeCredentialsData(
                        accessToken: "file-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    try fileData.write(to: fileURL)

                    let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)

                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        _ = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                            try ProviderInteractionContext.$current.withValue(.background) {
                                try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                            }
                        }

                        switch KeychainCacheStore.load(key: cacheKey, as: ClaudeOAuthCredentialsStore.CacheEntry.self) {
                        case .missing:
                            break
                        case .found, .invalid, .temporarilyUnavailable:
                            Issue.record("Expected CodexBar OAuth keychain cache to stay empty under never prompt mode")
                        }
                    }
                }
            }
        }
    }

    @Test
    func `never prompt mode invalidate credentials file changed leaves codexbar oauth keychain cache untouched`()
        throws
    {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    let initialData = self.makeCredentialsData(
                        accessToken: "initial-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    try initialData.write(to: fileURL)

                    let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                    let cacheData = self.makeCredentialsData(
                        accessToken: "cached-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    KeychainCacheStore.store(
                        key: cacheKey,
                        entry: ClaudeOAuthCredentialsStore.CacheEntry(data: cacheData, storedAt: Date()))
                    defer { KeychainCacheStore.clear(key: cacheKey) }

                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        _ = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                            ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
                        }

                        let updatedData = self.makeCredentialsData(
                            accessToken: "updated-token-with-different-length",
                            expiresAt: Date(timeIntervalSinceNow: 7200))
                        Thread.sleep(forTimeInterval: 1.1)
                        try updatedData.write(to: fileURL)

                        let changed = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                            ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
                        }
                        #expect(changed)

                        switch KeychainCacheStore.load(key: cacheKey, as: ClaudeOAuthCredentialsStore.CacheEntry.self) {
                        case let .found(entry):
                            let creds = try ClaudeOAuthCredentials.parse(data: entry.data)
                            #expect(creds.accessToken == "cached-token")
                        case .missing, .invalid, .temporarilyUnavailable:
                            Issue
                                .record(
                                    "Expected CodexBar OAuth keychain cache to remain after never-mode invalidation")
                        }
                    }
                }
            }
        }
    }

    @Test
    func `never prompt mode has cached credentials ignores codexbar oauth keychain cache`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(false) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    }

                    let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                    let cacheData = self.makeCredentialsData(
                        accessToken: "cached-token",
                        expiresAt: Date(timeIntervalSinceNow: 3600))
                    KeychainCacheStore.store(
                        key: cacheKey,
                        entry: ClaudeOAuthCredentialsStore.CacheEntry(data: cacheData, storedAt: Date()))
                    defer { KeychainCacheStore.clear(key: cacheKey) }

                    let hasCache = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                        ProviderInteractionContext.$current.withValue(.background) {
                            ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:])
                        }
                    }
                    #expect(!hasCache)
                }
            }
        }
    }
}
