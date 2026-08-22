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

    @Test
    func `reports consumer tier deprecation from loadCodeAssist 200 ineligible tiers`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = Self.cloudCodeLoader(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse()),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse()))

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.consumerTierDeprecated) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `maps quota 403 to consumer tier deprecation after unsupported client signal`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = Self.cloudCodeLoader(
            loadCodeAssist: (
                200,
                GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(currentTierId: "free-tier")),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse()))

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.consumerTierDeprecated) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `keeps licensed tier accounts despite ineligible free tier listing`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "dev@example.com", hostedDomain: "example.com"))

        let dataLoader = Self.cloudCodeLoader(
            loadCodeAssist: (
                200,
                GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(currentTierId: "standard-tier")),
            quota: (200, GeminiAPITestHelpers.sampleQuotaResponse()))

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        #expect(snapshot.accountPlan == "Paid")
    }

    @Test
    func `keeps plain http 403 error without unsupported client signal`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = Self.cloudCodeLoader(
            loadCodeAssist: (200, GeminiAPITestHelpers.loadCodeAssistStandardTierResponse()),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse()))

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.apiError("HTTP 403")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `keeps http 403 for licensed tier despite unsupported client listing`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: GeminiAPITestHelpers.makeIDToken(email: "dev@example.com", hostedDomain: "example.com"))

        let dataLoader = Self.cloudCodeLoader(
            loadCodeAssist: (
                200,
                GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(currentTierId: "standard-tier")),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse()))

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.apiError("HTTP 403")) {
            _ = try await probe.fetch()
        }
    }

    @Test
    func `keeps a named paid tier without current tier out of the shutdown path`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = Self.cloudCodeLoader(
            loadCodeAssist: (
                200,
                GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(paidTierName: "Plus")),
            quota: (200, GeminiAPITestHelpers.sampleQuotaResponse()))

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        let snapshot = try await probe.fetch()
        #expect(snapshot.accountPlan == "Plus")
    }

    @Test
    func `keeps http 403 for a named paid tier without current tier`() async throws {
        let env = try GeminiTestEnvironment()
        defer { env.cleanup() }
        try env.writeCredentials(
            accessToken: "token",
            refreshToken: nil,
            expiry: Date().addingTimeInterval(3600),
            idToken: nil)

        let dataLoader = Self.cloudCodeLoader(
            loadCodeAssist: (
                200,
                GeminiAPITestHelpers.loadCodeAssistUnsupportedClientResponse(paidTierName: "Plus")),
            quota: (403, GeminiAPITestHelpers.quotaSubscriptionRequiredResponse()))

        let probe = GeminiStatusProbe(timeout: 1, homeDirectory: env.homeURL.path, dataLoader: dataLoader)
        await Self.expectError(.apiError("HTTP 403")) {
            _ = try await probe.fetch()
        }
    }

    private static func cloudCodeLoader(
        loadCodeAssist: (status: Int, body: Data),
        quota: (status: Int, body: Data)) -> @Sendable (URLRequest) async throws -> (Data, URLResponse)
    {
        GeminiAPITestHelpers.dataLoader { request in
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
                        status: loadCodeAssist.status,
                        body: loadCodeAssist.body)
                }
                if url.path == "/v1internal:retrieveUserQuota" {
                    return GeminiAPITestHelpers.response(
                        url: url.absoluteString,
                        status: quota.status,
                        body: quota.body)
                }
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            default:
                return GeminiAPITestHelpers.response(url: url.absoluteString, status: 404, body: Data())
            }
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
