import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreTests {
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
    func loadsFromKeychainCacheBeforeExpiredFile() throws {
        try KeychainAccessGate.withTaskOverrideForTesting(true) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore.setKeychainAccessOverrideForTesting(true)
            defer { ClaudeOAuthCredentialsStore.setKeychainAccessOverrideForTesting(nil) }

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
            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            _ = try ClaudeOAuthCredentialsStore.load(environment: [:])
            // Re-store to cache after file check has marked file as "seen"
            KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)
            let creds = try ClaudeOAuthCredentialsStore.load(environment: [:])

            #expect(creds.accessToken == "cached")
            #expect(creds.isExpired == false)
        }
    }

    @Test
    func invalidatesCacheWhenCredentialsFileChanges() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
        defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        let first = self.makeCredentialsData(
            accessToken: "first",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        try first.write(to: fileURL)

        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
        let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(data: first, storedAt: Date())
        KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)

        _ = try ClaudeOAuthCredentialsStore.load(environment: [:])

        let updated = self.makeCredentialsData(
            accessToken: "second",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        try updated.write(to: fileURL)

        #expect(ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged())
        KeychainCacheStore.clear(key: cacheKey)

        let creds = try ClaudeOAuthCredentialsStore.load(environment: [:])
        #expect(creds.accessToken == "second")
    }

    @Test
    func returnsExpiredFileWhenNoOtherSources() throws {
        try KeychainAccessGate.withTaskOverrideForTesting(true) {
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

            ClaudeOAuthCredentialsStore.setKeychainAccessOverrideForTesting(true)
            defer { ClaudeOAuthCredentialsStore.setKeychainAccessOverrideForTesting(nil) }

            ClaudeOAuthCredentialsStore.invalidateCache()
            let creds = try ClaudeOAuthCredentialsStore.load(environment: [:])

            #expect(creds.accessToken == "expired-only")
            #expect(creds.isExpired == true)
        }
    }

    @Test
    func hasCachedCredentials_returnsFalseForExpiredUnrefreshableCacheEntry() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        ClaudeOAuthCredentialsStore.invalidateCache()

        let expiredData = self.makeCredentialsData(
            accessToken: "expired-no-refresh",
            expiresAt: Date(timeIntervalSinceNow: -3600),
            refreshToken: nil)
        let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(data: expiredData, storedAt: Date())
        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
        KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)

        #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials() == false)
    }

    @Test
    func hasCachedCredentials_returnsTrueForExpiredRefreshableCacheEntry() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        ClaudeOAuthCredentialsStore.invalidateCache()

        let expiredData = self.makeCredentialsData(
            accessToken: "expired-refreshable",
            expiresAt: Date(timeIntervalSinceNow: -3600),
            refreshToken: "refresh")
        let cacheEntry = ClaudeOAuthCredentialsStore.CacheEntry(data: expiredData, storedAt: Date())
        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
        KeychainCacheStore.store(key: cacheKey, entry: cacheEntry)

        #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials() == true)
    }

    @Test
    func hasCachedCredentials_returnsFalseForExpiredUnrefreshableCredentialsFile() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        ClaudeOAuthCredentialsStore.invalidateCache()

        let expiredData = self.makeCredentialsData(
            accessToken: "expired-file-no-refresh",
            expiresAt: Date(timeIntervalSinceNow: -3600),
            refreshToken: nil)
        try expiredData.write(to: fileURL)

        #expect(ClaudeOAuthCredentialsStore.hasCachedCredentials() == false)
    }

    @Test
    func syncsCacheWhenClaudeKeychainFingerprintChangesAndTokenDiffers() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            ClaudeOAuthCredentialsStore.invalidateCache()
            ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
            defer {
                ClaudeOAuthCredentialsStore.invalidateCache()
                ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
            }

            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
            let cachedData = self.makeCredentialsData(
                accessToken: "cached-token",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            KeychainCacheStore.store(
                key: cacheKey,
                entry: ClaudeOAuthCredentialsStore.CacheEntry(data: cachedData, storedAt: Date()))

            let fingerprint1 = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1")
            ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(fingerprint1)
            ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(cachedData)

            let first = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
            #expect(first.accessToken == "cached-token")

            ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeThrottleForTesting()

            let fingerprint2 = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 2,
                persistentRefHash: "ref2")
            ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(fingerprint2)

            let keychainData = self.makeCredentialsData(
                accessToken: "keychain-token",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(keychainData)

            let second = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
            #expect(second.accessToken == "keychain-token")

            switch KeychainCacheStore.load(key: cacheKey, as: ClaudeOAuthCredentialsStore.CacheEntry.self) {
            case let .found(entry):
                let parsed = try ClaudeOAuthCredentials.parse(data: entry.data)
                #expect(parsed.accessToken == "keychain-token")
            default:
                #expect(Bool(false))
            }
        }
    }

    @Test
    func doesNotSyncWhenClaudeKeychainFingerprintUnchanged() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
        defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

        ClaudeOAuthCredentialsStore.invalidateCache()
        ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
        defer {
            ClaudeOAuthCredentialsStore.invalidateCache()
            ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
        }

        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
        let cachedData = self.makeCredentialsData(
            accessToken: "cached-token",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        KeychainCacheStore.store(
            key: cacheKey,
            entry: ClaudeOAuthCredentialsStore.CacheEntry(data: cachedData, storedAt: Date()))

        let fingerprint = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
            modifiedAt: 1,
            createdAt: 1,
            persistentRefHash: "ref1")
        ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(fingerprint)
        ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(cachedData)

        let first = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
        #expect(first.accessToken == "cached-token")

        ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeThrottleForTesting()
        let keychainData = self.makeCredentialsData(
            accessToken: "keychain-token",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(keychainData)

        let second = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
        #expect(second.accessToken == "cached-token")

        switch KeychainCacheStore.load(key: cacheKey, as: ClaudeOAuthCredentialsStore.CacheEntry.self) {
        case let .found(entry):
            let parsed = try ClaudeOAuthCredentials.parse(data: entry.data)
            #expect(parsed.accessToken == "cached-token")
        default:
            #expect(Bool(false))
        }
    }

    @Test
    func doesNotSyncWhenKeychainCredentialsExpiredButCacheValid() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
        defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

        ClaudeOAuthCredentialsStore.invalidateCache()
        ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
        defer {
            ClaudeOAuthCredentialsStore.invalidateCache()
            ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
        }

        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
        let cachedData = self.makeCredentialsData(
            accessToken: "cached-token",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        KeychainCacheStore.store(
            key: cacheKey,
            entry: ClaudeOAuthCredentialsStore.CacheEntry(data: cachedData, storedAt: Date()))

        ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(
            ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"))
        ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(cachedData)

        let first = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
        #expect(first.accessToken == "cached-token")

        ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeThrottleForTesting()

        ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(
            ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 2,
                persistentRefHash: "ref2"))
        let expiredKeychainData = self.makeCredentialsData(
            accessToken: "expired-keychain-token",
            expiresAt: Date(timeIntervalSinceNow: -3600))
        ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(expiredKeychainData)

        let second = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
        #expect(second.accessToken == "cached-token")

        switch KeychainCacheStore.load(key: cacheKey, as: ClaudeOAuthCredentialsStore.CacheEntry.self) {
        case let .found(entry):
            let parsed = try ClaudeOAuthCredentials.parse(data: entry.data)
            #expect(parsed.accessToken == "cached-token")
        default:
            #expect(Bool(false))
        }
    }

    @Test
    func respectsPromptCooldownGateWhenDisabledPrompting() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        ClaudeOAuthKeychainAccessGate.resetForTesting()
        defer { ClaudeOAuthKeychainAccessGate.resetForTesting() }

        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
        defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

        ClaudeOAuthCredentialsStore.invalidateCache()
        ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
        defer {
            ClaudeOAuthCredentialsStore.invalidateCache()
            ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeTrackingForTesting()
        }

        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
        let cachedData = self.makeCredentialsData(
            accessToken: "cached-token",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        KeychainCacheStore.store(
            key: cacheKey,
            entry: ClaudeOAuthCredentialsStore.CacheEntry(data: cachedData, storedAt: Date()))

        ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(
            ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 1,
                createdAt: 1,
                persistentRefHash: "ref1"))
        ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(cachedData)

        let first = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
        #expect(first.accessToken == "cached-token")

        ClaudeOAuthCredentialsStore._resetClaudeKeychainChangeThrottleForTesting()
        ClaudeOAuthKeychainAccessGate.recordDenied(now: Date())

        ClaudeOAuthCredentialsStore.setClaudeKeychainFingerprintOverrideForTesting(
            ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprint(
                modifiedAt: 2,
                createdAt: 2,
                persistentRefHash: "ref2"))
        let keychainData = self.makeCredentialsData(
            accessToken: "keychain-token",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(keychainData)

        let second = try ClaudeOAuthCredentialsStore.load(
            environment: [:],
            allowKeychainPrompt: false,
            respectKeychainPromptCooldown: true)
        #expect(second.accessToken == "cached-token")

        switch KeychainCacheStore.load(key: cacheKey, as: ClaudeOAuthCredentialsStore.CacheEntry.self) {
        case let .found(entry):
            let parsed = try ClaudeOAuthCredentials.parse(data: entry.data)
            #expect(parsed.accessToken == "cached-token")
        default:
            #expect(Bool(false))
        }
    }

    @Test
    func doesNotShowPreAlertWhenClaudeKeychainReadableWithoutInteraction() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        ClaudeOAuthCredentialsStore.invalidateCache()
        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
        defer {
            ClaudeOAuthCredentialsStore.invalidateCache()
            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(nil)
            KeychainPromptHandler.handler = nil
            KeychainAccessPreflight.setCheckGenericPasswordOverrideForTesting(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        let keychainData = self.makeCredentialsData(
            accessToken: "keychain-token",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(keychainData)

        KeychainAccessPreflight.setCheckGenericPasswordOverrideForTesting { _, _ in
            .allowed
        }

        var preAlertHits = 0
        KeychainPromptHandler.handler = { _ in
            preAlertHits += 1
        }

        let creds = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: true)
        #expect(creds.accessToken == "keychain-token")
        #expect(preAlertHits == 0)
    }

    @Test
    func showsPreAlertWhenClaudeKeychainLikelyRequiresInteraction() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        ClaudeOAuthCredentialsStore.invalidateCache()
        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
        defer {
            ClaudeOAuthCredentialsStore.invalidateCache()
            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(nil)
            KeychainPromptHandler.handler = nil
            KeychainAccessPreflight.setCheckGenericPasswordOverrideForTesting(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        let keychainData = self.makeCredentialsData(
            accessToken: "keychain-token",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(keychainData)

        KeychainAccessPreflight.setCheckGenericPasswordOverrideForTesting { _, _ in
            .interactionRequired
        }

        var preAlertHits = 0
        KeychainPromptHandler.handler = { _ in
            preAlertHits += 1
        }

        let creds = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: true)
        #expect(creds.accessToken == "keychain-token")
        #expect(preAlertHits == 1)
    }

    @Test
    func showsPreAlertWhenClaudeKeychainPreflightFails() throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }

        ClaudeOAuthCredentialsStore.invalidateCache()
        ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
        defer {
            ClaudeOAuthCredentialsStore.invalidateCache()
            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(nil)
            KeychainPromptHandler.handler = nil
            KeychainAccessPreflight.setCheckGenericPasswordOverrideForTesting(nil)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("credentials.json")
        ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(fileURL)
        defer { ClaudeOAuthCredentialsStore.setCredentialsURLOverrideForTesting(nil) }

        let keychainData = self.makeCredentialsData(
            accessToken: "keychain-token",
            expiresAt: Date(timeIntervalSinceNow: 3600))
        ClaudeOAuthCredentialsStore.setClaudeKeychainDataOverrideForTesting(keychainData)

        KeychainAccessPreflight.setCheckGenericPasswordOverrideForTesting { _, _ in
            .failure(-1)
        }

        var preAlertHits = 0
        KeychainPromptHandler.handler = { _ in
            preAlertHits += 1
        }

        let creds = try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: true)
        #expect(creds.accessToken == "keychain-token")
        #expect(preAlertHits == 1)
    }
}
