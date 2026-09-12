import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct AntigravityOfflineFallbackProofTests {
    @Test
    func `counts db in app-data directory`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let appData = AntigravityOfflineStore.appDataDirectory(home: tmp, env: [:])
        try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: appData.appendingPathComponent("a.db").path, contents: Data())
        FileManager.default.createFile(atPath: appData.appendingPathComponent("b.db").path, contents: Data())
        #expect(AntigravityOfflineStore.countConversations(home: tmp) == 2)
        #expect(AntigravityOfflineStore.hasOfflineData(home: tmp))
    }

    @Test
    func `counts db in app-data conversations subdirectory`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let appDataConv = AntigravityOfflineStore.appDataDirectory(home: tmp, env: [:])
            .appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: appDataConv, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: appDataConv.appendingPathComponent("c.db").path, contents: Data())
        #expect(AntigravityOfflineStore.countConversations(home: tmp) == 1)
    }

    @Test
    func `offline snapshot does not carry selected OAuth email`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let conv = AntigravityOfflineStore.conversationsDirectory(home: tmp, env: [:])
        try FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: conv.appendingPathComponent("x.db").path, contents: Data())
        let credentials = AntigravityOAuthCredentials(
            accessToken: "ya29.fake",
            refreshToken: "1//fake",
            expiryDate: Date().addingTimeInterval(3600),
            email: "selected@example.com")
        guard let tokenValue = try? AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials) else {
            Issue.record("failed to encode credentials"); return
        }
        let context = Self.makeContext(
            env: ["HOME": tmp.path, AntigravityOAuthCredentialsStore.environmentCredentialsKey: tokenValue],
            selectedTokenAccountID: UUID())
        let strategy = AntigravityOfflineFetchStrategy()
        let result = try await strategy.fetch(context)
        #expect(result.usage.identity?.accountEmail == nil)
        #expect(result.usage.extraRateWindows?.first?.title == "Offline · 1 conversation")
        #expect(result.sourceLabel == "offline")
    }

    @Test
    func `oauth shouldFallback when offline data exists`() async {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let conv = AntigravityOfflineStore.conversationsDirectory(home: tmp, env: [:])
        try? FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: conv.appendingPathComponent("a.db").path, contents: Data())
        let ctxWithData = Self.makeContext(env: ["HOME": tmp.path])
        let ctxEmpty = Self.makeContext(env: ["HOME": "/tmp/empty-\(UUID().uuidString)"])
        let oauth = AntigravityOAuthFetchStrategy()
        let shouldFallbackWithData = await oauth.shouldFallback(
            on: ProviderFetchError.noAvailableStrategy(.antigravity),
            context: ctxWithData)
        let shouldFallbackEmpty = await oauth.shouldFallback(
            on: ProviderFetchError.noAvailableStrategy(.antigravity),
            context: ctxEmpty)
        #expect(shouldFallbackWithData == true)
        #expect(shouldFallbackEmpty == false)
    }

    private static func makeContext(
        env: [String: String],
        selectedTokenAccountID: UUID? = nil) -> ProviderFetchContext
    {
        var effectiveEnv = env
        effectiveEnv["HOME"] = effectiveEnv["HOME"]
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "codexbar-antigravity-empty-home-\(UUID().uuidString)",
                isDirectory: true)
            .path
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: effectiveEnv,
            settings: nil,
            fetcher: UsageFetcher(environment: effectiveEnv),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: selectedTokenAccountID)
    }

    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }
}
