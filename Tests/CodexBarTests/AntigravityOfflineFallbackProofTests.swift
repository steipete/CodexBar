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
    func `offline diagnostic only surfaces sanitized reasons`() {
        let strategy = AntigravityOfflineFetchStrategy()

        let raw = strategy.diagnostic(forPriorFailure:
            SubprocessRunnerError.nonZeroExit(code: 1, stderr: "raw-secret-stderr"))
        #expect(raw?.contains("raw-secret-stderr") == false)
        #expect(raw?.contains("Diagnostics") == true)

        let body = strategy.diagnostic(forPriorFailure:
            AntigravityStatusProbeError.apiError("HTTP 500: {\"secret\":\"token-value\"}"))
        #expect(body?.contains("token-value") == false)
        #expect(body?.contains("HTTP 500") == true)

        let expired = strategy.diagnostic(forPriorFailure:
            AntigravityStatusProbeError.apiError("HTTP 403: {\"detail\":\"private\"}"))
        #expect(expired?.contains("private") == false)
        #expect(expired?.contains("session expired") == true)

        let classified = strategy.diagnostic(forPriorFailure:
            AntigravityStatusProbeError.cliReportFailed(.exited(code: 1, reason: .unspecified)))
        #expect(classified?.contains("agy exited 1") == true)

        let remote = strategy.diagnostic(forPriorFailure:
            AntigravityRemoteFetchError.apiError("HTTP 429: {\"retry\":\"secret-hint\"}"))
        #expect(remote?.contains("secret-hint") == false)

        let signedOut = strategy.diagnostic(forPriorFailure: AntigravityRemoteFetchError.notLoggedIn)
        #expect(signedOut?.contains("Google auth not found") == true)

        let bareAPI = strategy.diagnostic(forPriorFailure:
            AntigravityStatusProbeError.apiError("quota service warming up"))
        #expect(bareAPI?.hasSuffix("the usage request failed") == true)
        #expect(bareAPI?.contains("warming") == false)

        let mismatch = strategy.diagnostic(forPriorFailure:
            AntigravityStatusProbeError.accountMismatch(expected: "me@example.com", found: "other@example.com"))
        #expect(mismatch?.contains("me@example.com") == false)
        #expect(mismatch?.contains("other@example.com") == false)
        #expect(mismatch?.contains("does not match the selected account") == true)

        // Free-form messages are reduced to a fixed hint even though today's
        // throw sites only pass fixed literals.
        let parse = strategy.diagnostic(forPriorFailure:
            AntigravityStatusProbeError.parseFailed("hypothetical dynamic detail"))
        #expect(parse?.contains("hypothetical dynamic detail") == false)
        #expect(parse?.contains("Diagnostics") == true)

        let urlError = URLError(.notConnectedToInternet)
        let offline = strategy.diagnostic(forPriorFailure: urlError)
        #expect(offline == "Live Antigravity usage is unavailable; showing offline data. "
            + urlError.localizedDescription)
    }

    @Test(arguments: [URLError.notConnectedToInternet, .timedOut, .serverCertificateUntrusted])
    func `offline transport diagnostics discard caller supplied details`(code: URLError.Code) throws {
        let privateURL = "https://synthetic-private.invalid/account@example.com"
        let error = try URLError(code, userInfo: [
            NSLocalizedDescriptionKey: "synthetic-private-diagnostic \(privateURL)",
            NSURLErrorFailingURLErrorKey: #require(URL(string: privateURL)),
            NSUnderlyingErrorKey: NSError(
                domain: "synthetic-private-domain",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-private-underlying"]),
        ])
        let diagnostic = AntigravityOfflineFetchStrategy().diagnostic(forPriorFailure: error)
        #expect(diagnostic == "Live Antigravity usage is unavailable; showing offline data. "
            + URLError(code).localizedDescription)
        #expect(diagnostic?.contains("synthetic-private") == false)
        #expect(diagnostic?.contains("account@example.com") == false)
    }

    @Test
    func `oauth shouldFallback when offline data exists`() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let conv = AntigravityOfflineStore.conversationsDirectory(home: tmp, env: [:])
        try? FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: conv.appendingPathComponent("a.db").path, contents: Data())
        let ctxWithData = Self.makeContext(env: ["HOME": tmp.path])
        let ctxEmpty = Self.makeContext(env: ["HOME": "/tmp/empty-\(UUID().uuidString)"])
        let oauth = AntigravityOAuthFetchStrategy()
        let shouldFallbackWithData = oauth.shouldFallback(
            on: ProviderFetchError.noAvailableStrategy(.antigravity),
            context: ctxWithData)
        let shouldFallbackEmpty = oauth.shouldFallback(
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
