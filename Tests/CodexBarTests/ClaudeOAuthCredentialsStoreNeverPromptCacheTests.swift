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
        let stored = ClaudeOAuthCredentialsStore.withOAuthCacheOperationRecorderForTesting(nil) {
            KeychainCacheStore.storeResult(
                key: state.cacheKey,
                entry: ClaudeOAuthCredentialsStore.CacheEntry(data: data, storedAt: storedAt))
        }
        #expect(stored)
    }

    private func cachedToken(_ state: TestState) throws -> String? {
        try ClaudeOAuthCredentialsStore.withOAuthCacheOperationRecorderForTesting(nil) {
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
    }

    private func runDefaults(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
    func `has cached credentials ignores stale oauth cache when pending clear fails`() throws {
        try self.withTestState { state in
            try self.withCredentialsFile(data: nil) { _ in
                self.seedCache(state, accessToken: "cached-token")
                ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                    ClaudeOAuthCredentialsStore.invalidateCache()
                }

                let hasCached = KeychainCacheStore.withClearFailureStatusOverrideForTesting(
                    errSecInteractionNotAllowed)
                {
                    ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                        ProviderInteractionContext.$current.withValue(.background) {
                            ClaudeOAuthCredentialsStore.hasCachedCredentials(environment: [:])
                        }
                    }
                }

                #expect(!hasCached)
                #expect(state.pendingStore.isPending)
                #expect(state.recorder.operations == [.clear])
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
    func `bundled CLI resolves the owning app prompt policy domain`() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appURL = tempDirectory.appendingPathComponent("CodexBar.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let binURL = tempDirectory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let info: [String: Any] = [
            "CFBundleExecutable": "CodexBar",
            "CFBundleIdentifier": ClaudeOAuthKeychainPromptPreference.debugApplicationDefaultsDomain,
            "CFBundlePackageType": "APPL",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data().write(to: macOSURL.appendingPathComponent("CodexBar"))

        let helperURL = helpersURL.appendingPathComponent("CodexBarCLI")
        try Data().write(to: helperURL)
        let symlinkURL = binURL.appendingPathComponent("codexbar")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: helperURL)

        let bundledCLIDomain = ClaudeOAuthKeychainPromptPreference.resolveApplicationDefaultsDomain(
            bundleIdentifier: nil,
            bundleURL: nil,
            executableURL: nil,
            invocationURL: symlinkURL)
        #expect(bundledCLIDomain == ClaudeOAuthKeychainPromptPreference.debugApplicationDefaultsDomain)

        let debugWidgetDomain = ClaudeOAuthKeychainPromptPreference.resolveApplicationDefaultsDomain(
            bundleIdentifier: "com.steipete.codexbar.debug.widget",
            bundleURL: nil,
            executableURL: nil,
            invocationURL: nil)
        #expect(debugWidgetDomain == ClaudeOAuthKeychainPromptPreference.debugApplicationDefaultsDomain)

        let standaloneDomain = ClaudeOAuthKeychainPromptPreference.resolveApplicationDefaultsDomain(
            bundleIdentifier: nil,
            bundleURL: nil,
            executableURL: URL(fileURLWithPath: "/usr/local/bin/codexbar"),
            invocationURL: nil)
        #expect(standaloneDomain == ClaudeOAuthKeychainPromptPreference.releaseApplicationDefaultsDomain)

        let testProcessDomain = ClaudeOAuthKeychainPromptPreference.resolveApplicationDefaultsDomain(
            bundleIdentifier: nil,
            bundleURL: Bundle.main.bundleURL,
            executableURL: Bundle.main.executableURL,
            invocationURL: CommandLine.arguments.first.map(URL.init(fileURLWithPath:)),
            bundleIdentifierForApp: { _ in nil })
        #expect(testProcessDomain == ClaudeOAuthKeychainPromptPreference.releaseApplicationDefaultsDomain)
    }

    @Test
    func `shared tombstone propagates across process boundaries`() throws {
        let domain = "ClaudeOAuthPendingCacheTests.\(UUID().uuidString)"
        let key = "pending"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lockURL = tempDirectory.appendingPathComponent("cache.lock")
        let userDefaults = try #require(UserDefaults(suiteName: domain))
        defer {
            userDefaults.removePersistentDomain(forName: domain)
            userDefaults.synchronize()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let store = ClaudeOAuthPendingCacheClearUserDefaultsStore(
            domain: domain,
            key: key,
            lockURL: lockURL)
        store.markPending()

        let childRead = try self.runDefaults(["read", domain, key])
        #expect(childRead.status == 0)
        #expect(!childRead.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let childDelete = try self.runDefaults(["delete", domain, key])
        #expect(childDelete.status == 0)
        #expect(!store.isPending)

        let childWrite = try self.runDefaults(["write", domain, key, UUID().uuidString])
        #expect(childWrite.status == 0)
        #expect(store.isPending)

        store.withCacheTransaction { pending in
            pending = false
        }
        let childReadAfterResolution = try self.runDefaults(["read", domain, key])
        #expect(childReadAfterResolution.status != 0)
    }

    @Test
    func `newer tombstone survives an older cache transaction`() throws {
        let domain = "ClaudeOAuthPendingCacheRaceTests.\(UUID().uuidString)"
        let key = "pending"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lockURL = tempDirectory.appendingPathComponent("cache.lock")
        let userDefaults = try #require(UserDefaults(suiteName: domain))
        defer {
            userDefaults.removePersistentDomain(forName: domain)
            userDefaults.synchronize()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let store = ClaudeOAuthPendingCacheClearUserDefaultsStore(
            domain: domain,
            key: key,
            lockURL: lockURL)
        store.markPending()

        let newerGeneration = UUID().uuidString
        var childWriteStatus: Int32?
        store.withCacheTransaction { pending in
            childWriteStatus = try? self.runDefaults(["write", domain, key, newerGeneration]).status
            pending = false
        }
        userDefaults.synchronize()

        #expect(childWriteStatus == 0)
        #expect(userDefaults.string(forKey: key) == newerGeneration)
        #expect(store.isPending)
    }

    @Test
    func `legacy boolean tombstone remains pending until cache resolution`() throws {
        let domain = "ClaudeOAuthPendingCacheLegacyTests.\(UUID().uuidString)"
        let key = "pending"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let userDefaults = try #require(UserDefaults(suiteName: domain))
        defer {
            userDefaults.removePersistentDomain(forName: domain)
            userDefaults.synchronize()
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        userDefaults.set(true, forKey: key)
        userDefaults.synchronize()

        let store = ClaudeOAuthPendingCacheClearUserDefaultsStore(
            domain: domain,
            key: key,
            lockURL: tempDirectory.appendingPathComponent("cache.lock"))
        #expect(store.isPending)
        store.withCacheTransaction { pending in
            pending = false
        }
        #expect(!store.isPending)
    }

    @Test
    func `cache transaction fails closed when its lock is unavailable`() throws {
        let domain = "ClaudeOAuthPendingCacheLockFailureTests.\(UUID().uuidString)"
        let key = "pending"
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let nonDirectoryURL = tempDirectory.appendingPathComponent("not-a-directory")
        try Data().write(to: nonDirectoryURL)
        let userDefaults = try #require(UserDefaults(suiteName: domain))
        defer {
            userDefaults.removePersistentDomain(forName: domain)
            userDefaults.synchronize()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let store = ClaudeOAuthPendingCacheClearUserDefaultsStore(
            domain: domain,
            key: key,
            lockURL: nonDirectoryURL.appendingPathComponent("cache.lock"))
        var operationCalled = false
        store.withCacheTransaction { _ in
            operationCalled = true
        }
        userDefaults.synchronize()

        #expect(!operationCalled)
        #expect(userDefaults.string(forKey: key) != nil)
        #expect(store.isPending)
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
                            try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                data: securityData,
                                fingerprint: nil)
                            {
                                try ProviderInteractionContext.$current.withValue(.background) {
                                    try ClaudeOAuthCredentialsStore.load(
                                        environment: [:],
                                        allowKeychainPrompt: false)
                                }
                            }
                        }
                    }
                }

                #expect(credentials.accessToken == "security-cli-token")
                #expect(state.recorder.operations.isEmpty)
                #expect(state.pendingStore.isPending)
                let cachedToken = try self.cachedToken(state)
                #expect(cachedToken == "cached-token")

                do {
                    _ = try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        try ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                            .securityCLIExperimental)
                        {
                            try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.onlyOnUserAction) {
                                try ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(.data(nil)) {
                                    try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                        data: Data(),
                                        fingerprint: nil)
                                    {
                                        try ProviderInteractionContext.$current.withValue(.background) {
                                            try ClaudeOAuthCredentialsStore.load(
                                                environment: [:],
                                                allowKeychainPrompt: false)
                                        }
                                    }
                                }
                            }
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
                let clearedToken = try self.cachedToken(state)
                #expect(clearedToken == nil)

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
                #expect(!isMcpOnly)
            }
        }
    }
}
