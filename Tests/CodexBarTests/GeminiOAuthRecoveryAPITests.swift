import CodexBarCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite(.serialized)
struct GeminiOAuthRecoveryAPITests {
    @Test
    func `refreshes using oauth2 js path when gemini cli omits oauth config`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let oauthURL = env.homeURL.appendingPathComponent("oauth2.js")
        try """
        const OAUTH_CLIENT_ID = 'path-client-id';
        const OAUTH_CLIENT_SECRET = 'path-client-secret';
        """.write(to: oauthURL, atomically: true, encoding: .utf8)

        let binURL = try env.writeFakeGeminiCLI(includeOAuth: false)
        let previousGeminiPath = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        let previousOAuthPath = ProcessInfo.processInfo.environment["GEMINI_OAUTH2_JS_PATH"]
        let previousClientID = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_ID"]
        let previousClientSecret = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_SECRET"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        setenv("GEMINI_OAUTH2_JS_PATH", oauthURL.path, 1)
        unsetenv("GEMINI_OAUTH_CLIENT_ID")
        unsetenv("GEMINI_OAUTH_CLIENT_SECRET")
        defer {
            if let previousGeminiPath {
                setenv("GEMINI_CLI_PATH", previousGeminiPath, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
            if let previousOAuthPath {
                setenv("GEMINI_OAUTH2_JS_PATH", previousOAuthPath, 1)
            } else {
                unsetenv("GEMINI_OAUTH2_JS_PATH")
            }
            if let previousClientID {
                setenv("GEMINI_OAUTH_CLIENT_ID", previousClientID, 1)
            } else {
                unsetenv("GEMINI_OAUTH_CLIENT_ID")
            }
            if let previousClientSecret {
                setenv("GEMINI_OAUTH_CLIENT_SECRET", previousClientSecret, 1)
            } else {
                unsetenv("GEMINI_OAUTH_CLIENT_SECRET")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=path-client-id") else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.sampleQuotaResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        #expect(snapshot.accountPlan == "Paid")
    }

    @Test
    func `prefers environment oauth client over installed gemini cli`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: nil)

        let binURL = try env.writeFakeGeminiCLI()
        let previousGeminiPath = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        setenv("GEMINI_OAUTH_CLIENT_ID", "env-client-id", 1)
        setenv("GEMINI_OAUTH_CLIENT_SECRET", "env-client-secret", 1)
        defer {
            if let previousGeminiPath {
                setenv("GEMINI_CLI_PATH", previousGeminiPath, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
            unsetenv("GEMINI_OAUTH_CLIENT_ID")
            unsetenv("GEMINI_OAUTH_CLIENT_SECRET")
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "oauth2.googleapis.com":
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=env-client-id"),
                      body.contains("client_secret=env-client-secret")
                else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 400, body: Data())
                }
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistFreeTierResponse())
                }
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.sampleFlashQuotaResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 2, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        _ = try await probe.fetch()
    }
}
