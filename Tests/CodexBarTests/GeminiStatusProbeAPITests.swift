import CodexBarCore
import Foundation
import Testing

@Suite("Gemini API", .serialized)
struct GeminiStatusProbeAPITests {
    @Test
    func missingCredentialsThrowsNotLoggedIn() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.notLoggedIn) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func rejectsApiKeyAuthType() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeSettings(authType: "api-key")

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.unsupportedAuthType("API key")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func rejectsVertexAuthType() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeSettings(authType: "vertex-ai")

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.unsupportedAuthType("Vertex AI")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func refreshesExpiredTokenAndUpdatesStoredCredentials() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "user@example.com"))

        let binURL = try env.writeFakeGeminiCLI()
        let previousValue = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousValue {
                setenv("GEMINI_CLI_PATH", previousValue, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }

            switch host {
            case "oauth2.googleapis.com":
                let json = GeminiAPITestHelpers.jsonData([
                    "access_token": "new-token",
                    "expires_in": 3600,
                    "id_token": GeminiAPITestHelpers.makeIDToken(email: "user@example.com"),
                ])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudresourcemanager.googleapis.com":
                let json = GeminiAPITestHelpers.jsonData(["projects": []])
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 200, body: json)
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    let auth = request.value(forHTTPHeaderField: "Authorization")
                    if auth != "Bearer new-token" {
                        return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
                    }
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                let auth = request.value(forHTTPHeaderField: "Authorization")
                if auth != "Bearer new-token" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
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

        let updated = try env.readCredentials()
        #expect(updated["access_token"] as? String == "new-token")
    }

    @Test
    func failsRefreshWhenOAuthConfigMissing() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh-token",
            expiry: Date().addingTimeInterval(-3600),
            idToken: nil)

        let binURL = try env.writeFakeGeminiCLI(includeOAuth: false)
        let previousValue = ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"]
        setenv("GEMINI_CLI_PATH", binURL.path, 1)
        defer {
            if let previousValue {
                setenv("GEMINI_CLI_PATH", previousValue, 1)
            } else {
                unsetenv("GEMINI_CLI_PATH")
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.apiError("Could not find Gemini CLI OAuth configuration")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func reportsApiErrors() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 500, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.apiError("HTTP 500")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func reportsNotLoggedInWhenAccessTokenMissing() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path)
        await Self.expectError(.notLoggedIn) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func reportsNotLoggedInOn401() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 401, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.notLoggedIn) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func reportsParseErrorsForInvalidPayload() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = GeminiAPITestHelpers.dataLoader { request in
            guard let url = request.url, let host = url.host else {
                throw URLError(.badURL)
            }
            switch host {
            case "cloudresourcemanager.googleapis.com":
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["projects": []]))
            case "cloudcode-pa.googleapis.com":
                if url.path != "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
                }
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 200,
                    body: GeminiAPITestHelpers.jsonData(["buckets": []]))
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        do {
            _ = try await probe.fetch()
            #expect(Bool(false))
        } catch {
            let cast = error as? GeminiStatusProbeError
            #expect(cast?.errorDescription?.contains("Could not parse Gemini usage") == true)
        }
    }

    private static func expectError(
        _ expected: GeminiStatusProbeError,
        operation: () async throws -> Void) async
    {
        do {
            try await operation()
            #expect(Bool(false))
        } catch {
            #expect(error as? GeminiStatusProbeError == expected)
        }
    }
}
