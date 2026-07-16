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

    private func withClaudeOAuthTokenRefreshStub<T>(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data),
        operation: () async throws -> T) async rethrows -> T
    {
        let registered = URLProtocol.registerClass(ClaudeOAuthTokenRefreshStubURLProtocol.self)
        ClaudeOAuthTokenRefreshStubURLProtocol.reset()
        ClaudeOAuthTokenRefreshStubURLProtocol.handler = handler
        defer {
            if registered {
                URLProtocol.unregisterClass(ClaudeOAuthTokenRefreshStubURLProtocol.self)
            }
            ClaudeOAuthTokenRefreshStubURLProtocol.reset()
        }
        return try await operation()
    }

    private func requestBodyString(_ request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }

        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    @Test
    func `successful codexbar refresh is re-owned when Claude CLI storage appears`() async throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let fileURL = tempDir.appendingPathComponent("credentials.json")
            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            let expiredData = self.makeCredentialsData(
                                accessToken: "expired-codexbar-only",
                                expiresAt: Date(timeIntervalSinceNow: -3600),
                                refreshToken: "cached-refresh-token")
                            KeychainCacheStore.store(
                                key: cacheKey,
                                entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                    data: expiredData,
                                    storedAt: Date(timeIntervalSinceNow: 60),
                                    owner: .codexbar))

                            var tokenRefreshRequestCount = 0
                            let refreshed = try await self.withClaudeOAuthTokenRefreshStub(handler: { request in
                                tokenRefreshRequestCount += 1
                                #expect(request.url?.host == "platform.claude.com")
                                #expect(request.url?.path == "/v1/oauth/token")
                                #expect(request.httpMethod == "POST")
                                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
                                #expect(
                                    request.value(forHTTPHeaderField: "Content-Type") ==
                                        "application/x-www-form-urlencoded")

                                let body = self.requestBodyString(request)
                                #expect(body.contains("grant_type=refresh_token"))
                                #expect(body.contains("refresh_token=cached-refresh-token"))
                                #expect(body.contains("client_id=\(ClaudeOAuthCredentialsStore.defaultOAuthClientID)"))

                                let response = try HTTPURLResponse(
                                    url: #require(request.url),
                                    statusCode: 200,
                                    httpVersion: "HTTP/1.1",
                                    headerFields: ["Content-Type": "application/json"])!
                                let json = """
                                {
                                  "access_token": "fresh-codexbar-token",
                                  "refresh_token": "fresh-refresh-token",
                                  "expires_in": 3600,
                                  "token_type": "Bearer"
                                }
                                """
                                return (response, Data(json.utf8))
                            }, operation: {
                                try await ClaudeOAuthRefreshFailureGate.$shouldAttemptOverride.withValue(true) {
                                    try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
                                        environment: [:],
                                        allowKeychainPrompt: false,
                                        respectKeychainPromptCooldown: true)
                                }
                            })

                            #expect(refreshed.accessToken == "fresh-codexbar-token")
                            #expect(refreshed.refreshToken == "fresh-refresh-token")
                            #expect(tokenRefreshRequestCount == 1)

                            switch KeychainCacheStore.load(
                                key: cacheKey,
                                as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                            {
                            case let .found(entry):
                                #expect(entry.owner == .codexbar)
                                let parsed = try ClaudeOAuthCredentials.parse(data: entry.data)
                                #expect(parsed.accessToken == "fresh-codexbar-token")
                                #expect(parsed.refreshToken == "fresh-refresh-token")
                            default:
                                Issue.record("Expected refreshed CodexBar-owned cache entry")
                            }

                            let keychainData = self.makeCredentialsData(
                                accessToken: "claude-keychain",
                                expiresAt: Date(timeIntervalSinceNow: 3600),
                                refreshToken: "keychain-refresh-token")

                            let recordAfterCLIStorageAppears = try ClaudeOAuthCredentialsStore
                                .withClaudeKeychainOverridesForTesting(data: keychainData, fingerprint: nil) {
                                    try ClaudeOAuthCredentialsStore.loadRecord(
                                        environment: [:],
                                        allowKeychainPrompt: false,
                                        respectKeychainPromptCooldown: true,
                                        allowClaudeKeychainRepairWithoutPrompt: false)
                                }

                            #expect(recordAfterCLIStorageAppears.credentials.accessToken == "fresh-codexbar-token")
                            #expect(recordAfterCLIStorageAppears.owner == .claudeCLI)
                            #expect(recordAfterCLIStorageAppears.source == .memoryCache)
                        }
                    }
                }
            }
        }
    }

    @Test
    func `rotated refresh token preserves history owner through cache restart`() async throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let fileURL = tempDir.appendingPathComponent("credentials.json")
            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
            defer { KeychainCacheStore.clear(key: cacheKey) }

            try await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                try await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                    try await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                        ClaudeOAuthCredentialsStore.invalidateCache()
                        let expiredData = self.makeCredentialsData(
                            accessToken: "access-before-rotation",
                            expiresAt: Date(timeIntervalSinceNow: -3600),
                            refreshToken: "refresh-before-rotation")
                        let originalCredentials = try ClaudeOAuthCredentials.parse(data: expiredData)
                        let originalHistoryOwner = try #require(originalCredentials.historyOwnerIdentifier)
                        KeychainCacheStore.store(
                            key: cacheKey,
                            entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                data: expiredData,
                                storedAt: Date(),
                                owner: .codexbar))

                        let refreshedRecord = try await ClaudeOAuthCredentialsStore
                            .withIsolatedMemoryCacheForTesting {
                                try await self.withClaudeOAuthTokenRefreshStub(handler: { request in
                                    let response = try HTTPURLResponse(
                                        url: #require(request.url),
                                        statusCode: 200,
                                        httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": "application/json"])!
                                    let json = """
                                    {
                                      "access_token": "access-after-rotation",
                                      "refresh_token": "refresh-after-rotation",
                                      "expires_in": 3600,
                                      "token_type": "Bearer"
                                    }
                                    """
                                    return (response, Data(json.utf8))
                                }, operation: {
                                    try await ClaudeOAuthRefreshFailureGate.$shouldAttemptOverride.withValue(true) {
                                        try await ClaudeOAuthCredentialsStore.loadRecordWithAutoRefresh(
                                            environment: [:],
                                            allowKeychainPrompt: false,
                                            respectKeychainPromptCooldown: true)
                                    }
                                })
                            }

                        let rotatedCredentialOwner = try #require(
                            refreshedRecord.credentials.historyOwnerIdentifier)
                        #expect(rotatedCredentialOwner != originalHistoryOwner)
                        #expect(refreshedRecord.historyOwnerIdentifier == originalHistoryOwner)

                        switch KeychainCacheStore.load(
                            key: cacheKey,
                            as: ClaudeOAuthCredentialsStore.CacheEntry.self)
                        {
                        case let .found(entry):
                            #expect(entry.owner == .codexbar)
                            #expect(entry.historyOwnerIdentifier == originalHistoryOwner)
                        default:
                            Issue.record("Expected refreshed cache entry with preserved history lineage")
                        }

                        let restartedRecord = try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                            try ClaudeOAuthCredentialsStore.loadRecord(
                                environment: [:],
                                allowKeychainPrompt: false,
                                respectKeychainPromptCooldown: true,
                                allowClaudeKeychainRepairWithoutPrompt: false)
                        }
                        #expect(restartedRecord.credentials.accessToken == "access-after-rotation")
                        #expect(restartedRecord.credentials.refreshToken == "refresh-after-rotation")
                        #expect(restartedRecord.source == .cacheKeychain)
                        #expect(restartedRecord.historyOwnerIdentifier == originalHistoryOwner)
                    }
                }
            }
        }
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
    func `load with auto refresh keeps codexbar cache ownership without Claude CLI storage`() async throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let fileURL = tempDir.appendingPathComponent("missing-credentials.json")
            await ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                await ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                    await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                        await ClaudeOAuthCredentialsStore.withKeychainAccessOverrideForTesting(true) {
                            ClaudeOAuthCredentialsStore.invalidateCache()
                            let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                            defer { KeychainCacheStore.clear(key: cacheKey) }

                            let expiredData = self.makeCredentialsData(
                                accessToken: "expired-codexbar-only",
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
                                    Issue.record("Expected direct CodexBar refresh failure")
                                } catch let error as ClaudeOAuthCredentialsError {
                                    guard case let .refreshFailed(message) = error else {
                                        Issue.record("Expected .refreshFailed, got \(error)")
                                        return
                                    }
                                    #expect(message.contains("suppressed") || message.contains("backed off"))
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

                        let record = try ClaudeOAuthKeychainPromptPreference
                            .withTaskOverrideForTesting(.onlyOnUserAction) {
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

    @Test
    func `load record ignores codexbar cache in never prompt mode`() throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        try KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let fileURL = tempDir.appendingPathComponent("credentials.json")
            let pendingStore = ClaudeOAuthCredentialsStore.PendingCacheClearMemoryStore()
            try ClaudeOAuthCredentialsStore.withPendingCacheClearStoreOverrideForTesting(pendingStore) {
                try ClaudeOAuthCredentialsStore.withIsolatedCredentialsFileTrackingForTesting {
                    try ClaudeOAuthCredentialsStore.withIsolatedMemoryCacheForTesting {
                        try ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
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

                            do {
                                _ = try ClaudeOAuthKeychainPromptPreference.withTaskOverrideForTesting(.never) {
                                    try ClaudeOAuthCredentialsStore.withClaudeKeychainOverridesForTesting(
                                        data: self.makeCredentialsData(
                                            accessToken: "claude-keychain",
                                            expiresAt: Date(timeIntervalSinceNow: 3600),
                                            refreshToken: "keychain-refresh-token"),
                                        fingerprint: nil)
                                    {
                                        try ClaudeOAuthCredentialsStore.loadRecord(
                                            environment: [:],
                                            allowKeychainPrompt: false,
                                            respectKeychainPromptCooldown: true,
                                            allowClaudeKeychainRepairWithoutPrompt: false)
                                    }
                                }
                                Issue.record("Expected ClaudeOAuthCredentialsError.notFound")
                            } catch let error as ClaudeOAuthCredentialsError {
                                guard case .notFound = error else {
                                    Issue.record("Expected .notFound, got \(error)")
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @Test
    func `expired claude CLI owner blocks background mcp O auth but lets user action delegate`() async throws {
        let service = "com.steipete.codexbar.cache.tests.\(UUID().uuidString)"
        let mcpOAuthOnly = Data("""
        {
          "mcpOAuth": {
            "plugin:slack:slack": { "accessToken": "" }
          }
        }
        """.utf8)

        try await KeychainCacheStore.withServiceOverrideForTesting(service) {
            KeychainCacheStore.setTestStoreForTesting(true)
            defer { KeychainCacheStore.setTestStoreForTesting(false) }

            ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting()
            defer { ClaudeOAuthCredentialsStore._resetCredentialsFileTrackingForTesting() }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileURL = tempDir.appendingPathComponent("credentials.json")

            await KeychainAccessGate.withTaskOverrideForTesting(false) {
                await ClaudeOAuthKeychainReadStrategyPreference.withTaskOverrideForTesting(
                    .securityCLIExperimental,
                    operation: {
                        await ClaudeOAuthCredentialsStore.withCredentialsURLOverrideForTesting(fileURL) {
                            await ClaudeOAuthCredentialsStore.withSecurityCLIReadOverrideForTesting(
                                .data(mcpOAuthOnly))
                            {
                                ClaudeOAuthCredentialsStore.invalidateCache()
                                let cacheKey = KeychainCacheStore.Key.oauth(provider: .claude)
                                defer { KeychainCacheStore.clear(key: cacheKey) }

                                let expiredData = self.makeCredentialsData(
                                    accessToken: "expired-claude-cli-owner",
                                    expiresAt: Date(timeIntervalSinceNow: -3600),
                                    refreshToken: "refresh-token")
                                KeychainCacheStore.store(
                                    key: cacheKey,
                                    entry: ClaudeOAuthCredentialsStore.CacheEntry(
                                        data: expiredData,
                                        storedAt: Date(),
                                        owner: .claudeCLI))

                                do {
                                    _ = try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
                                        environment: [:],
                                        allowKeychainPrompt: false,
                                        respectKeychainPromptCooldown: true)
                                    Issue.record("Expected mcpOAuth-only keychain error")
                                } catch let error as ClaudeOAuthCredentialsError {
                                    guard case .mcpOAuthOnlyKeychain = error else {
                                        Issue.record("Expected .mcpOAuthOnlyKeychain, got \(error)")
                                        return
                                    }
                                } catch {
                                    Issue.record("Expected ClaudeOAuthCredentialsError, got \(error)")
                                }

                                do {
                                    _ = try await ProviderInteractionContext.$current.withValue(.userInitiated) {
                                        try await ClaudeOAuthCredentialsStore.loadWithAutoRefresh(
                                            environment: [:],
                                            allowKeychainPrompt: false,
                                            respectKeychainPromptCooldown: true)
                                    }
                                    Issue.record("Expected delegated refresh on explicit user action")
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
                    })
            }
        }
    }
}

private final class ClaudeOAuthTokenRefreshStubURLProtocol: URLProtocol {
    private static let _handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    static func reset() {
        self.handler = nil
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "platform.claude.com" && request.url?.path == "/v1/oauth/token"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
