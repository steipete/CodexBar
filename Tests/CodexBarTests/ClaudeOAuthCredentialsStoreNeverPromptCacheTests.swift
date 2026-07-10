import Foundation
import Security
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ClaudeOAuthCredentialsStoreNeverPromptCacheTests {
    private struct TestState {
        let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
        let pendingStore: ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore
        let recorder: ClaudeOAuthCredentialsStore.OAuthCacheOperationRecorder
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

    private func withTestState<T>(_ operation: (TestState) throws -> T) throws -> T {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let pendingStore = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()
        let recorder = ClaudeOAuthCredentialsStore.OAuthCacheOperationRecorder()
        let fingerprintStore = ClaudeOAuthCredentialsStore.ClaudeKeychainFingerprintStore()
        let state = TestState(pendingStore: pendingStore, recorder: recorder)

        return try KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            return try KeychainAccessGate.withTaskOverrideForTesting(false) {
                try ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(false) {
                    try ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(pendingStore) {
                        try ClaudeOAuthCredentialsStore.withOAuthCacheOperationRecorderForTesting(recorder) {
                            try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                                try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                                    try ClaudeOAuthCredentialsStore
                                        .withClaudeKeychainFingerprintStoreOverrideForTesting(fingerprintStore) {
                                            try operation(state)
                                        }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func withCredentialsFile<T>(
        data: Data?,
        operation: (URL) throws -> T) throws -> T
    {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fileURL = tempDirectory.appendingPathComponent("credentials.json")
        if let data {
            try data.write(to: fileURL)
        }
        return try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
            try operation(fileURL)
        }
    }

    private func seedCache(
        _ state: TestState,
        accessToken: String,
        storedAt: Date = Date())
    {
        let data = self.makeCredentialsData(
            accessToken: accessToken,
            expiresAt: Date(timeIntervalSinceNow: 3600))
        let stored = KeychainCacheStore.storeResult(
            key: state.cacheKey,
            entry: ClaudeOAuthCredentialsStore.CacheEntry(data: data, storedAt: storedAt))
        #expect(stored)
    }

    private func cachedToken(_ state: TestState) throws -> String? {
        switch KeychainCacheStore.load(
            key: state.cacheKey,
            as: ClaudeOAuthCredentialsStore.CacheEntry.self)
        {
        case let .found(entry):
            return try ClaudeOAuthCredentials.parse(data: entry.data).accessToken
        case .missing:
            return nil
        case .invalid, .temporarilyUnavailable:
            Issue.record("Expected a valid or missing test cache entry")
            return nil
        }
    }

    @Test
    func `never mode loads the credentials file with zero oauth cache IO`() throws {
        try self.withTestState { state in
            let fileData = self.makeCredentialsData(
                accessToken: "file-token",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            try self.withCredentialsFile(data: fileData) { _ in
                self.seedCache(state, accessToken: "cached-token")

                let credentials = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    try ProviderInteractionContext.$current.withValue(.background) {
                        try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                    }
                }

                #expect(credentials.accessToken == "file-token")
                #expect(state.recorder.operations.isEmpty)
                #expect(state.pendingStore.isPending)
                let cachedToken = try self.cachedToken(state)
                #expect(cachedToken == "cached-token")
            }
        }
    }

    @Test
    func `never mode file invalidation records a tombstone without oauth cache IO`() throws {
        try self.withTestState { state in
            let initialData = self.makeCredentialsData(
                accessToken: "initial-token",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            try self.withCredentialsFile(data: initialData) { fileURL in
                self.seedCache(state, accessToken: "cached-token")

                let initialChange = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
                }
                #expect(initialChange)

                let updatedData = self.makeCredentialsData(
                    accessToken: "updated-token-with-a-different-size",
                    expiresAt: Date(timeIntervalSinceNow: 7200))
                try updatedData.write(to: fileURL)

                let changed = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
                }
                let changedAgain = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
                }

                #expect(changed)
                #expect(!changedAgain)
                #expect(state.recorder.operations.isEmpty)
                #expect(state.pendingStore.isPending)
                let cachedToken = try self.cachedToken(state)
                #expect(cachedToken == "cached-token")
            }
        }
    }

    @Test
    func `never mode has cached credentials ignores stale oauth cache with zero IO`() throws {
        try self.withTestState { state in
            try self.withCredentialsFile(data: nil) { _ in
                self.seedCache(state, accessToken: "cached-token")

                let hasCached = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ProviderInteractionContext.$current.withValue(.background) {
                        ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:])
                    }
                }

                #expect(!hasCached)
                #expect(state.recorder.operations.isEmpty)
                let cachedToken = try self.cachedToken(state)
                #expect(cachedToken == "cached-token")
            }
        }
    }

    @Test
    func `leaving never mode clears stale oauth cache before repopulating from file`() throws {
        try self.withTestState { state in
            let fileData = self.makeCredentialsData(
                accessToken: "file-token-new",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            try self.withCredentialsFile(data: fileData) { _ in
                self.seedCache(
                    state,
                    accessToken: "cached-token",
                    storedAt: Date(timeIntervalSince1970: 0))

                _ = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.invalidateCacheIfCredentialsFileChanged()
                }
                #expect(state.pendingStore.isPending)
                #expect(state.recorder.operations.isEmpty)

                let credentials = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(
                    .onlyOnUserAction)
                {
                    try ProviderInteractionContext.$current.withValue(.background) {
                        try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                    }
                }

                #expect(credentials.accessToken == "file-token-new")
                #expect(!state.pendingStore.isPending)
                #expect(state.recorder.operations == [.clear, .load, .store])
                let cachedToken = try self.cachedToken(state)
                #expect(cachedToken == "file-token-new")
            }
        }
    }

    @Test
    func `logout under never mode clears stale oauth cache after access is reenabled`() throws {
        try self.withTestState { state in
            try self.withCredentialsFile(data: nil) { _ in
                self.seedCache(state, accessToken: "cached-token")

                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                }
                #expect(state.pendingStore.isPending)
                #expect(state.recorder.operations.isEmpty)
                let staleToken = try self.cachedToken(state)
                #expect(staleToken == "cached-token")

                do {
                    _ = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        try ProviderInteractionContext.$current.withValue(.background) {
                            try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                        }
                    }
                    Issue.record("Expected ClaudeOAuthCredentialsError.notFound")
                } catch let error as ClaudeOAuthCredentialsError {
                    guard case .notFound = error else {
                        Issue.record("Expected .notFound, got \(error)")
                        return
                    }
                }

                #expect(!state.pendingStore.isPending)
                #expect(state.recorder.operations == [.clear, .load])
                let cachedToken = try self.cachedToken(state)
                #expect(cachedToken == nil)
            }
        }
    }

    @Test
    func `pending oauth cache clear retries after a temporarily unavailable delete`() throws {
        try self.withTestState { state in
            let fileData = self.makeCredentialsData(
                accessToken: "file-token-new",
                expiresAt: Date(timeIntervalSinceNow: 3600))
            try self.withCredentialsFile(data: fileData) { _ in
                self.seedCache(state, accessToken: "cached-token")
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                }

                let first = try KeychainCacheStore.withClearFailureStatusOverrideForTesting(
                    errSecInteractionNotAllowed)
                {
                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        try ProviderInteractionContext.$current.withValue(.background) {
                            try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                        }
                    }
                }
                #expect(first.accessToken == "file-token-new")
                #expect(state.pendingStore.isPending)
                let staleToken = try self.cachedToken(state)
                #expect(staleToken == "cached-token")

                let second = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                    try ProviderInteractionContext.$current.withValue(.background) {
                        try ClaudeOAuthCredentialsStore.load(environment: [:], allowKeychainPrompt: false)
                    }
                }
                #expect(second.accessToken == "file-token-new")
                #expect(!state.pendingStore.isPending)
                #expect(state.recorder.operations == [.clear, .clear, .load, .store])
                let refreshedToken = try self.cachedToken(state)
                #expect(refreshedToken == "file-token-new")
            }
        }
    }

    @Test
    func `replacement store failure after successful clear keeps tombstone and cache missing`() throws {
        try self.withTestState { state in
            try self.withCredentialsFile(data: nil) { _ in
                self.seedCache(state, accessToken: "cached-token")
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                }

                let syncData = self.makeCredentialsData(
                    accessToken: "sync-token",
                    expiresAt: Date(timeIntervalSinceNow: 3600),
                    refreshToken: "sync-refresh-token")
                let synced = KeychainCacheStore.withStoreFailureStatusOverrideForTesting(
                    errSecInteractionNotAllowed)
                {
                    ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        ProviderInteractionContext.$current.withValue(.userInitiated) {
                            ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: syncData,
                                fingerprint: nil)
                            {
                                ClaudeOAuthCredentialsStore.syncFromClaudeKeychainWithoutPrompt()
                            }
                        }
                    }
                }

                #expect(synced)
                #expect(state.pendingStore.isPending)
                #expect(state.recorder.operations == [.clear, .store])
                let cachedToken = try self.cachedToken(state)
                #expect(cachedToken == nil)
            }
        }
    }

    @Test
    func `replacement store failure after failed clear keeps tombstone and stale cache`() throws {
        try self.withTestState { state in
            try self.withCredentialsFile(data: nil) { _ in
                self.seedCache(state, accessToken: "cached-token")
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                }

                let syncData = self.makeCredentialsData(
                    accessToken: "sync-token",
                    expiresAt: Date(timeIntervalSinceNow: 3600),
                    refreshToken: "sync-refresh-token")
                let synced = KeychainCacheStore.withClearFailureStatusOverrideForTesting(
                    errSecInteractionNotAllowed)
                {
                    KeychainCacheStore.withStoreFailureStatusOverrideForTesting(errSecInteractionNotAllowed) {
                        ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                            ProviderInteractionContext.$current.withValue(.userInitiated) {
                                ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                    data: syncData,
                                    fingerprint: nil)
                                {
                                    ClaudeOAuthCredentialsStore.syncFromClaudeKeychainWithoutPrompt()
                                }
                            }
                        }
                    }
                }

                #expect(synced)
                #expect(state.pendingStore.isPending)
                #expect(state.recorder.operations == [.clear, .store])
                let cachedToken = try self.cachedToken(state)
                #expect(cachedToken == "cached-token")
            }
        }
    }

    @Test
    func `bundled CLI reads app prompt policy and app shared tombstone`() throws {
        let appDomain = "ClaudeOAuthAppDomainTests.\(UUID().uuidString)"
        let cliDomain = "ClaudeOAuthCLIDomainTests.\(UUID().uuidString)"
        let appDefaults = try #require(UserDefaults(suiteName: appDomain))
        let cliDefaults = try #require(UserDefaults(suiteName: cliDomain))
        defer {
            appDefaults.removePersistentDomain(forName: appDomain)
            cliDefaults.removePersistentDomain(forName: cliDomain)
        }

        appDefaults.set(ClaudeOAuthKeychainPromptMode.never.rawValue, forKey: "claudeOAuthKeychainPromptMode")
        cliDefaults.set(ClaudeOAuthKeychainPromptMode.always.rawValue, forKey: "claudeOAuthKeychainPromptMode")

        let resolved = ClaudeOAuthKeychainPromptPreference.withApplicationUserDefaultsOverrideForTesting(
            appDefaults)
        {
            ClaudeOAuthKeychainPromptPreference.storedMode()
        }
        #expect(resolved == .never)
        #expect(ClaudeOAuthKeychainPromptPreference.storedMode(userDefaults: cliDefaults) == .always)

        let taskOverride = ClaudeOAuthKeychainPromptPreference.withApplicationUserDefaultsOverrideForTesting(
            appDefaults)
        {
            ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.always) {
                ClaudeOAuthKeychainPromptPreference.storedMode()
            }
        }
        #expect(taskOverride == .always)

        let appStore = ClaudeOAuthPendingCacheClearUserDefaultsStore(
            userDefaults: appDefaults,
            key: "pending")
        let cliViewOfAppStore = try ClaudeOAuthPendingCacheClearUserDefaultsStore(
            userDefaults: #require(UserDefaults(suiteName: appDomain)),
            key: "pending")
        appStore.setPending(true)
        #expect(cliViewOfAppStore.isPending)
        cliViewOfAppStore.setPending(false)
        #expect(!appStore.isPending)
    }

    @Test
    func `never mode bypasses oauth cache while preserving experimental security CLI reader`() throws {
        try self.withTestState { state in
            try self.withCredentialsFile(data: nil) { _ in
                self.seedCache(state, accessToken: "cached-token")
                let securityData = self.makeCredentialsData(
                    accessToken: "security-cli-token",
                    expiresAt: Date(timeIntervalSinceNow: 3600),
                    refreshToken: "security-cli-refresh-token")

                let credentials = try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                    .securityCLIExperimental)
                {
                    try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                        try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(securityData)) {
                            try ProviderInteractionContext.$current.withValue(.background) {
                                try ClaudeOAuthCredentialsStore.load(
                                    environment: [:],
                                    allowKeychainPrompt: false)
                            }
                        }
                    }
                }

                #expect(credentials.accessToken == "security-cli-token")
                #expect(state.recorder.operations.isEmpty)
                let cachedToken = try self.cachedToken(state)
                #expect(cachedToken == "cached-token")

                let mcpOnly = Data(#"{"mcpOAuth":{"plugin:test":{"accessToken":"synthetic"}}}"#.utf8)
                let isMcpOnly = ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(mcpOnly)) {
                        ClaudeOAuthCredentialsStore.isMcpOAuthOnlyClaudeKeychainPayloadPresent(
                            interaction: .background,
                            readStrategy: .securityCLIExperimental,
                            keychainAccessDisabled: true,
                            environment: [
                                KeychainAccessGate.disableAccessEnvironmentKey: "1",
                                ClaudeOAuthCredentialsStore.isolatedSecurityCLIKeychainEnvironmentKey:
                                    "/tmp/codexbar-test.keychain-db",
                            ])
                    }
                }
                #expect(isMcpOnly)
            }
        }
    }
}
