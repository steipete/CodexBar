import CodexBarCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite(.serialized)
struct GeminiConsumerTierMigrationTests {
    @Test(arguments: [
        "UNSUPPORTED_CLIENT",
        "IneligibleTierError",
        "no longer supported for Gemini Code Assist for individuals",
        "please migrate Gemini to the Antigravity suite",
    ])
    func `detects consumer tier deprecation signals`(signal: String) {
        #expect(GeminiStatusProbeError.isConsumerTierDeprecationSignal(signal))
    }

    @Test(arguments: [
        "UNAUTHENTICATED",
        "HTTP 500",
        "quota bucket missing",
    ])
    func `ignores unrelated api errors`(signal: String) {
        #expect(!GeminiStatusProbeError.isConsumerTierDeprecationSignal(signal))
    }

    @Test
    func `reports consumer tier deprecation from loadCodeAssist`() async throws {
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
            case "cloudcode-pa.googleapis.com":
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 403,
                        body: GeminiAPITestHelpers.consumerTierDeprecationResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.consumerTierDeprecated) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `reports consumer tier deprecation from quota api`() async throws {
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
                if url.path == "/v1internal:loadCodeAssist" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 200,
                        body: GeminiAPITestHelpers.loadCodeAssistStandardTierResponse())
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: 403,
                        body: GeminiAPITestHelpers.consumerTierDeprecationResponse())
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.consumerTierDeprecated) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `reports consumer tier deprecation from token refresh`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "old-token",
            refreshToken: "refresh",
            expiry: Date().addingTimeInterval(-3600),
            idToken: nil)

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
                return GeminiAPITestHelpers.response(
                    url: url.absoluteString,
                    status: 400,
                    body: GeminiAPITestHelpers.consumerTierDeprecationResponse())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
        }

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.consumerTierDeprecated) {
            _ = try await probe.fetch()
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
