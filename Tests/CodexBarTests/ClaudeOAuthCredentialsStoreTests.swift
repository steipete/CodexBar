import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreTests {
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

    @Test
    func loadsFromKeychainCacheBeforeExpiredFile() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let previousGate = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = true
        defer { KeychainAccessGate.isDisabled = previousGate }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        let expiredData = self.makeCredentialsData(
            accessToken: "expired",
            expiresAt: Date(timeIntervalSinceNow: -3600))
        try expiredData.write(to: fileURL)

        let cachedData = self.makeCredentialsData(
            accessToken: "cached",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(data: cachedData, storedAt: Date())
        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
        ClaudeOAuthCredentialsStore.invalidateCache()
        KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)
        defer { KeychainCacheStore.clear(key: cacheKey) }
        let creds = try ClaudeOAuthCredentialsStore.load(environment: [:])

        #expect(creds.accessToken == "cached")
        #expect(creds.isExpired == false)
    }

    @Test
    func returnsExpiredFileWhenNoOtherSources() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        let expiredData = self.makeCredentialsData(
            accessToken: "expired-only",
            expiresAt: Date(timeIntervalSinceNow: -3600))
        try expiredData.write(to: fileURL)

        let previousGate = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = true
        defer { KeychainAccessGate.isDisabled = previousGate }

        ClaudeOAuthCredentialsStore.invalidateCache()
        let creds = try ClaudeOAuthCredentialsStore.load(environment: [:])

        #expect(creds.accessToken == "expired-only")
        #expect(creds.isExpired == true)
    }
}
