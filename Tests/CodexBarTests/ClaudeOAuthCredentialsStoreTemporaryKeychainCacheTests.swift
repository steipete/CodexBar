import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreTemporaryKeychainCacheTests {
    private struct WrongCacheEntry: Codable {
        let value: String
    }

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

    #if os(macOS)
    @Test
    func `credentials file invalidation preserves keychain cache when temporarily unavailable`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                    defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

                    let tempDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                    let fileURL = tempDir.appendingPathComponent("credentials.json")
                    try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        let firstFile = self.makeCredentialsData(
                            accessToken: "first-file",
                            expiresAt: Date(timeIntervalSinceNow: 3600))
                        try firstFile.write(to: fileURL)
                        #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged())

                        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                        let cachedData = self.makeCredentialsData(
                            accessToken: "cached-token",
                            expiresAt: Date(timeIntervalSinceNow: 3600))
                        KeychainCacheStore.store(
                            key: cacheKey,
                            entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                data: cachedData,
                                storedAt: Date(),
                                owner: .claudeCLI))
                        defer { KeychainCacheStore.clear(key: cacheKey) }

                        let updatedFile = self.makeCredentialsData(
                            accessToken: "updated-file-token-longer",
                            expiresAt: Date(timeIntervalSinceNow: 3600))
                        try updatedFile.write(to: fileURL)

                        KeychainCacheStore.withLoadFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                            #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged())
                        }

                        switch KeychainCacheStore.load(
                            key: cacheKey,
                            as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                        {
                        case let .found(entry):
                            let parsed = try ClaudeOAuthCredentials.parse(data: entry.data)
                            #expect(parsed.accessToken == "cached-token")
                        case .missing, .temporarilyUnavailable, .invalid:
                            #expect(Bool(false), "Expected temporary unavailability not to clear Claude cache")
                        }

                        #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged())

                        switch KeychainCacheStore.load(
                            key: cacheKey,
                            as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                        {
                        case .missing:
                            #expect(true)
                        case .found, .temporarilyUnavailable, .invalid:
                            #expect(Bool(false), "Expected pending invalidation to clear stale Claude cache")
                        }
                    }
                }
            }
        }
    }

    @Test
    func `temporary keychain cache unavailability does not overwrite cache from credentials file fallback`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(true) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                        defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

                        let tempDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        let fileURL = tempDir.appendingPathComponent("credentials.json")
                        try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                            let fileData = self.makeCredentialsData(
                                accessToken: "file-fallback-token",
                                expiresAt: Date(timeIntervalSinceNow: 3600))
                            try fileData.write(to: fileURL)

                            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                            let cachedData = self.makeCredentialsData(
                                accessToken: "cached-token",
                                expiresAt: Date(timeIntervalSinceNow: 3600))
                            KeychainCacheStore.store(
                                key: cacheKey,
                                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: cachedData,
                                    storedAt: Date(),
                                    owner: .claudeCLI))
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            let loaded = try KeychainCacheStore.withLoadFailureStatusOverrideForTesting(
                                errSecInteractionNotAllowed)
                            {
                                try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                            }
                            #expect(loaded.accessToken == "file-fallback-token")

                            switch KeychainCacheStore.load(
                                key: cacheKey,
                                as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                            {
                            case let .found(entry):
                                let parsed = try ClaudeOAuthCredentials.parse(data: entry.data)
                                #expect(parsed.accessToken == "cached-token")
                            case .missing, .temporarilyUnavailable, .invalid:
                                #expect(Bool(false), "Expected file fallback not to overwrite unavailable cache")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `has cached credentials treats temporary keychain cache unavailability as present`() {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                ClaudeOAuthCredentialsStore.invalidateCache()
                let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                let cachedData = self.makeCredentialsData(
                    accessToken: "cached-token",
                    expiresAt: Date(timeIntervalSinceNow: 3600))
                KeychainCacheStore.store(
                    key: cacheKey,
                    entry: ClaudeOAuthCredentialsStore.CacheEntry(data: cachedData, storedAt: Date()))
                defer { KeychainCacheStore.clear(key: cacheKey) }

                let hasCached = KeychainCacheStore.withLoadFailureStatusOverrideForTesting(
                    errSecInteractionNotAllowed)
                {
                    ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:])
                }

                #expect(hasCached == true)
            }
        }
    }
    #endif

    @Test
    func `invalid keychain cache is cleared by load`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            try KeychainAccessGate.withTaskOverrideForTesting(true) {
                KeychainCacheStore.setTestStoreForTesting(true)
                defer { KeychainCacheStore.setTestStoreForTesting(false) }

                ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
                defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

                try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                        let tempDir = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                        let fileURL = tempDir.appendingPathComponent("credentials.json")
                        try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                            KeychainCacheStore.store(key: cacheKey, entry: WrongCacheEntry(value: "wrong-shape"))

                            do {
                                _ = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                                Issue.record("Expected ClaudeOAuthCredentialsError.notFound")
                            } catch let error as ClaudeOAuthCredentialsError {
                                guard case .notFound = error else {
                                    Issue.record("Expected .notFound, got \(error)")
                                    return
                                }
                            }

                            switch KeychainCacheStore.load(
                                key: cacheKey,
                                as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                            {
                            case .missing:
                                #expect(true)
                            case .found, .temporarilyUnavailable, .invalid:
                                #expect(Bool(false), "Expected invalid Claude cache to be cleared")
                            }
                        }
                    }
                }
            }
        }
    }
}
