import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// Intercepts the OAuth strategy's real Google endpoints. `ProviderHTTPClient.shared`
/// uses `URLSession.shared` under tests, so a registered class sees the strategy's requests.
final class AntigravityIdentityFallbackStubURLProtocol: URLProtocol {
    private static let handlerBox = LockIsolated<(@Sendable (URLRequest) throws -> (Data, URLResponse))?>(nil)
    static var handler: (@Sendable (URLRequest) throws -> (Data, URLResponse))? {
        get { Self.handlerBox.value }
        set { Self.handlerBox.setValue(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard self.handler != nil else { return false }
        return request.url?.host == "cloudcode-pa.googleapis.com" || request.url?.host == "oauth2.googleapis.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, response) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct AntigravityIdentityFallbackTests {
    private static let selectedEmail = "selected@example.com"

    @Test
    func `remote 403 with a matching local agy login falls back to the CLI report`() async throws {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.writeLocalCLILogin(email: Self.selectedEmail, home: home)
        let launchMarker = home.appendingPathComponent("agy-launched")
        let agy = try Self.writeFakeAgy(in: home, launchMarker: launchMarker)
        let context = try Self.makeContext(home: home, agyPath: agy)

        let result = try await Self.withForbiddenQuotaEndpoints {
            try await AntigravityOAuthFetchStrategy().fetch(context)
        }

        #expect(result.sourceLabel == "cli")
        #expect(result.usage.primary?.usedPercent == 50)
        #expect(result.usage.identity?.accountEmail == Self.selectedEmail)
        #expect(result.usage.identity?.loginMethod == "cli")
        #expect(FileManager.default.fileExists(atPath: launchMarker.path))
    }

    @Test(arguments: [nil, "someone-else@example.com"] as [String?])
    func `remote 403 without a matching local agy login keeps the identity-only OAuth snapshot`(
        localLogin: String?) async throws
    {
        let home = try Self.makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        if let localLogin {
            try Self.writeLocalCLILogin(email: localLogin, home: home)
        }
        let launchMarker = home.appendingPathComponent("agy-launched")
        let agy = try Self.writeFakeAgy(in: home, launchMarker: launchMarker)
        let context = try Self.makeContext(home: home, agyPath: agy)

        let result = try await Self.withForbiddenQuotaEndpoints {
            try await AntigravityOAuthFetchStrategy().fetch(context)
        }

        #expect(result.sourceLabel == "oauth")
        #expect(result.usage.primary == nil)
        #expect(result.usage.identity?.accountEmail == Self.selectedEmail)
        #expect(result.usage.identity?.loginMethod != "cli")
        #expect(!FileManager.default.fileExists(atPath: launchMarker.path))
    }

    // MARK: - Fixtures

    private static func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-antigravity-identity-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private static func writeLocalCLILogin(email: String, home: URL) throws {
        let configDir = home.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "{\"accountEmail\": \"\(email)\"}".write(
            to: configDir.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8)
    }

    /// A stand-in `agy` that answers `--version` with a report-capable release and
    /// `-p /usage` with a structured quota report; every launch touches `launchMarker`.
    private static func writeFakeAgy(in home: URL, launchMarker: URL) throws -> String {
        let binary = home.appendingPathComponent("agy")
        let script = """
        #!/bin/sh
        : > '\(launchMarker.path)'
        if [ "$1" = "--version" ]; then
          echo '1.2.0'
          exit 0
        fi
        if [ "$1" = "-p" ] && [ "$2" = "/usage" ]; then
          cat <<'EOF'
        \(self.cliUsageReport)
        EOF
          exit 0
        fi
        exit 1
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary.path
    }

    private static let cliUsageReport = """
    {
      "status": "SUCCESS",
      "command": {
        "name": "usage",
        "data": {
          "groups": [
            {
              "name": "Gemini Models",
              "buckets": [
                {
                  "id": "gemini-weekly",
                  "name": "Weekly Limit Remaining",
                  "window": "weekly",
                  "remaining_fraction": 0.5,
                  "reset_time": "2026-09-24T00:00:00Z"
                }
              ]
            }
          ]
        }
      }
    }
    """

    private static func makeContext(home: URL, agyPath: String) throws -> ProviderFetchContext {
        let credentials = AntigravityOAuthCredentials(
            accessToken: "selected-token",
            refreshToken: "selected-refresh",
            expiryDate: Date().addingTimeInterval(3600),
            email: Self.selectedEmail)
        let token = try AntigravityOAuthCredentialsStore.tokenAccountValue(for: credentials)
        let env = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin",
            "ANTIGRAVITY_CLI_PATH": agyPath,
            AntigravityOAuthCredentialsStore.environmentCredentialsKey: token,
        ]
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            selectedTokenAccountID: UUID())
    }

    /// Serves `loadCodeAssist` normally and answers both quota endpoints with 403,
    /// which is the account-scoped OAuth outcome that leaves `modelQuotas` empty.
    private static func withForbiddenQuotaEndpoints<T>(_ body: () async throws -> T) async throws -> T {
        try #require(URLProtocol.registerClass(AntigravityIdentityFallbackStubURLProtocol.self))
        defer {
            URLProtocol.unregisterClass(AntigravityIdentityFallbackStubURLProtocol.self)
            AntigravityIdentityFallbackStubURLProtocol.handler = nil
        }
        AntigravityIdentityFallbackStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch (url.host, url.path) {
            case ("cloudcode-pa.googleapis.com", "/v1internal:loadCodeAssist"):
                return try Self.response(url: url, status: 200, json: [
                    "currentTier": ["id": "free-tier", "name": "free"],
                    "cloudaicompanionProject": "project-123",
                ])
            case ("cloudcode-pa.googleapis.com", "/v1internal:fetchAvailableModels"),
                 ("cloudcode-pa.googleapis.com", "/v1internal:retrieveUserQuota"):
                return try Self.response(url: url, status: 403, json: [
                    "error": ["status": "PERMISSION_DENIED"],
                ])
            default:
                return try Self.response(url: url, status: 404, json: [:])
            }
        }
        return try await body()
    }

    private static func response(url: URL, status: Int, json: [String: Any]) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]))
        return (data, response)
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
