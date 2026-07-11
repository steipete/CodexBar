import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct GeminiOAuthRecoveryAPITests {
    @Test
    func `explicit oauth2 js path overrides installed gemini cli`() async throws {
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

        let binURL = try env.writeFakeGeminiCLI()
        let oauthEnv = GeminiOAuthConfig.EnvironmentValues(oauth2JSPath: oauthURL.path)
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
        let snapshot = try await BinaryLocator.$geminiBinaryPathOverrideForTesting.withValue(binURL.path) {
            try await GeminiOAuthConfig.$environmentOverride.withValue(oauthEnv) {
                try await probe.fetch()
            }
        }
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
        let oauthEnv = GeminiOAuthConfig.EnvironmentValues(
            clientID: "env-client-id",
            clientSecret: "env-client-secret")
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
        _ = try await BinaryLocator.$geminiBinaryPathOverrideForTesting.withValue(binURL.path) {
            try await GeminiOAuthConfig.$environmentOverride.withValue(oauthEnv) {
                try await probe.fetch()
            }
        }
    }

    @Test
    func `refreshes via known Homebrew Cellar libexec path without gemini binary`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        // Resolvable gemini binary exists but omits OAuth config; Cellar package root
        // under a synthetic Homebrew prefix holds the credentials instead.
        let binURL = try env.writeFakeGeminiCLI(includeOAuth: false, layout: .npmNested)
        let homebrewPrefix = env.homeURL.appendingPathComponent("homebrew-prefix")
        try Self.plantHomebrewCellarGeminiPackage(
            under: homebrewPrefix,
            clientID: "cellar-client-id",
            clientSecret: "cellar-client-secret")

        let clearOAuthEnv = GeminiOAuthConfig.EnvironmentValues()
        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                guard body.contains("client_id=cellar-client-id") else {
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
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer new-token" else {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                }
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
        let snapshot = try await BinaryLocator.$geminiBinaryPathOverrideForTesting.withValue(binURL.path) {
            try await GeminiOAuthConfig.$environmentOverride.withValue(clearOAuthEnv) {
                try await GeminiStatusProbe.$knownInstallPrefixesForTesting.withValue([homebrewPrefix.path]) {
                    try await probe.fetch()
                }
            }
        }
        #expect(snapshot.accountPlan == "Paid")
    }

    private static func plantHomebrewCellarGeminiPackage(
        under prefix: URL,
        clientID: String,
        clientSecret: String) throws
    {
        let packageRoot = prefix
            .appendingPathComponent("Cellar")
            .appendingPathComponent("gemini-cli")
            .appendingPathComponent("0.41.2")
            .appendingPathComponent("libexec")
            .appendingPathComponent("lib")
            .appendingPathComponent("node_modules")
            .appendingPathComponent("@google")
            .appendingPathComponent("gemini-cli")
        let bundleDir = packageRoot.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        try """
        {
          "name": "@google/gemini-cli"
        }
        """.write(
            to: packageRoot.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8)
        try "#!/usr/bin/env node\nawait import('./chunk-OAUTH.js');\n".write(
            to: bundleDir.appendingPathComponent("gemini.js"),
            atomically: true,
            encoding: .utf8)
        try """
        var OAUTH_CLIENT_ID = "\(clientID)";
        var OAUTH_CLIENT_SECRET = "\(clientSecret)";
        """.write(
            to: bundleDir.appendingPathComponent("chunk-OAUTH.js"),
            atomically: true,
            encoding: .utf8)
    }
}
