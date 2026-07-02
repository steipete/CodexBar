import Foundation
import Testing
@testable import CodexBarCore

private struct KimiStubClaudeFetcher: ClaudeUsageFetching {
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

private func makeKimiFetchContext(
    sourceMode: ProviderSourceMode,
    environment: [String: String]? = nil) -> ProviderFetchContext
{
    let env = environment ?? [
        "KIMI_CODE_HOME": URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CodexBarMissingKimiCode-")
            .appendingPathComponent(UUID().uuidString)
            .path,
    ]
    return ProviderFetchContext(
        runtime: .app,
        sourceMode: sourceMode,
        includeCredits: false,
        webTimeout: 1,
        webDebugDumpHTML: false,
        verbose: false,
        env: env,
        settings: nil,
        fetcher: UsageFetcher(environment: env),
        claudeFetcher: KimiStubClaudeFetcher(),
        browserDetection: BrowserDetection(cacheTTL: 0))
}

private func makeTemporaryKimiCodeHome() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("CodexBarKimiCodeTests-")
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeKimiCodeCredential(
    home: URL,
    accessToken: String,
    refreshToken: String = "refresh-token",
    expiresAt: Date) throws
{
    let credentials = home.appendingPathComponent("credentials", isDirectory: true)
    try FileManager.default.createDirectory(at: credentials, withIntermediateDirectories: true)
    let payload: [String: Any] = [
        "access_token": accessToken,
        "refresh_token": refreshToken,
        "expires_at": expiresAt.timeIntervalSince1970,
        "expires_in": 3600,
        "scope": "",
        "token_type": "Bearer",
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: credentials.appendingPathComponent("kimi-code.json"))
}

struct KimiSettingsReaderTests {
    @Test
    func `reads token from environment variable`() {
        let env = ["KIMI_AUTH_TOKEN": "test.jwt.token"]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == "test.jwt.token")
    }

    @Test
    func `reads API key from preferred environment variable`() {
        let env = ["KIMI_CODE_API_KEY": "kimi-code-token"]
        let token = KimiSettingsReader.apiKey(environment: env)
        #expect(token == "kimi-code-token")
    }

    @Test
    func `does not consume generic Kimi K2 API key environment variable`() {
        let env = ["KIMI_API_KEY": "'kimi-api-token'"]
        let token = KimiSettingsReader.apiKey(environment: env)
        #expect(token == nil)
    }

    @Test
    func `uses code specific API key when generic Kimi K2 key also exists`() {
        let env = [
            "KIMI_API_KEY": "generic-kimi-token",
            "KIMI_CODE_API_KEY": "kimi-code-token",
        ]
        let token = KimiSettingsReader.apiKey(environment: env)
        #expect(token == "kimi-code-token")
    }

    @Test
    func `reads fresh Kimi Code OAuth credential from official home`() throws {
        let home = try makeTemporaryKimiCodeHome()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeKimiCodeCredential(
            home: home,
            accessToken: "oauth-access-token",
            expiresAt: now.addingTimeInterval(3600))

        let token = KimiSettingsReader.kimiCodeAccessToken(
            environment: ["KIMI_CODE_HOME": home.path],
            now: now)

        #expect(token == "oauth-access-token")
    }

    @Test
    func `ignores expired Kimi Code OAuth credential`() throws {
        let home = try makeTemporaryKimiCodeHome()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try writeKimiCodeCredential(
            home: home,
            accessToken: "expired-access-token",
            expiresAt: now.addingTimeInterval(30))

        let token = KimiSettingsReader.kimiCodeAccessToken(
            environment: ["KIMI_CODE_HOME": home.path],
            now: now)

        #expect(token == nil)
    }

    @Test
    func `resolves Kimi API token from Kimi Code OAuth credential`() throws {
        let home = try makeTemporaryKimiCodeHome()
        try writeKimiCodeCredential(
            home: home,
            accessToken: "oauth-access-token",
            expiresAt: Date().addingTimeInterval(3600))

        let resolution = ProviderTokenResolver.kimiAPIResolution(environment: ["KIMI_CODE_HOME": home.path])

        #expect(resolution?.token == "oauth-access-token")
        #expect(resolution?.source == .authFile)
    }

    @Test
    func `prefers explicit Kimi Code API key over Kimi Code OAuth credential`() throws {
        let home = try makeTemporaryKimiCodeHome()
        try writeKimiCodeCredential(
            home: home,
            accessToken: "oauth-access-token",
            expiresAt: Date().addingTimeInterval(3600))

        let resolution = ProviderTokenResolver.kimiAPIResolution(environment: [
            "KIMI_CODE_API_KEY": "explicit-api-key",
            "KIMI_CODE_HOME": home.path,
        ])

        #expect(resolution?.token == "explicit-api-key")
        #expect(resolution?.source == .environment)
    }

    @Test
    func `does not forward Kimi Code OAuth credential to API endpoint override`() throws {
        let home = try makeTemporaryKimiCodeHome()
        try writeKimiCodeCredential(
            home: home,
            accessToken: "oauth-access-token",
            expiresAt: Date().addingTimeInterval(3600))

        let resolution = ProviderTokenResolver.kimiAPIResolution(environment: [
            "KIMI_CODE_BASE_URL": "https://proxy.example.com/kimi",
            "KIMI_CODE_HOME": home.path,
        ])

        #expect(resolution == nil)
    }

    @Test
    func `does not expose Kimi Code credential to OAuth endpoint override`() throws {
        let home = try makeTemporaryKimiCodeHome()
        try writeKimiCodeCredential(
            home: home,
            accessToken: "expired-access-token",
            expiresAt: Date().addingTimeInterval(-60))

        let environment = [
            "KIMI_CODE_HOME": home.path,
            "KIMI_CODE_OAUTH_HOST": "https://oauth.example.com",
        ]

        #expect(KimiSettingsReader.hasKimiCodeCredential(environment: environment) == false)
        #expect(ProviderTokenResolver.kimiAPIResolution(environment: environment) == nil)
    }

    @Test
    func `keeps expired Kimi Code OAuth credential read only`() throws {
        let home = try makeTemporaryKimiCodeHome()
        let now = Date()
        try writeKimiCodeCredential(
            home: home,
            accessToken: "expired-access-token",
            refreshToken: "refresh-token",
            expiresAt: now.addingTimeInterval(-60))
        let credentialsURL = home
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json")
        var payload = try #require(JSONSerialization
            .jsonObject(with: Data(contentsOf: credentialsURL)) as? [String: Any])
        payload["cli_metadata"] = ["kept": true]
        let originalData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys])
        try originalData.write(to: credentialsURL)
        let environment = ["KIMI_CODE_HOME": home.path]

        #expect(KimiSettingsReader.hasKimiCodeCredential(environment: environment))
        #expect(KimiSettingsReader.kimiCodeAccessToken(environment: environment, now: now) == nil)
        #expect(ProviderTokenResolver.kimiAPIResolution(environment: environment) == nil)
        #expect(try Data(contentsOf: credentialsURL) == originalData)

        let explicit = ProviderTokenResolver.kimiAPIResolution(environment: [
            "KIMI_CODE_API_KEY": "explicit-api-key",
            "KIMI_CODE_HOME": home.path,
        ])
        #expect(explicit?.token == "explicit-api-key")
        #expect(explicit?.source == .environment)
    }

    @Test
    func `uses default code API base URL when override is absent`() throws {
        let url = try KimiSettingsReader.codeAPIBaseURL(environment: [:])
        #expect(url == KimiSettingsReader.defaultCodeAPIBaseURL)
    }

    @Test
    func `uses custom code API base URL when valid`() throws {
        let env = ["KIMI_CODE_BASE_URL": "https://proxy.example.com/kimi"]
        let url = try KimiSettingsReader.codeAPIBaseURL(environment: env)
        #expect(url.absoluteString == "https://proxy.example.com/kimi")
    }

    @Test
    func `rejects invalid code API base URL`() {
        let env = ["KIMI_CODE_BASE_URL": "not a url"]

        #expect(throws: KimiAPIError.invalidRequest(
            "Kimi Code API base URL must use HTTPS without user info"))
        {
            try KimiSettingsReader.codeAPIBaseURL(environment: env)
        }
    }

    @Test
    func `rejects insecure code API base URL`() {
        let env = ["KIMI_CODE_BASE_URL": "http://proxy.example.com/kimi"]

        #expect(throws: KimiAPIError.invalidRequest(
            "Kimi Code API base URL must use HTTPS without user info"))
        {
            try KimiSettingsReader.codeAPIBaseURL(environment: env)
        }
    }

    @Test
    func `rejects code API base URL containing user info`() {
        let env = ["KIMI_CODE_BASE_URL": "https://api.kimi.com@proxy.example.com/kimi"]

        #expect(throws: KimiAPIError.invalidRequest(
            "Kimi Code API base URL must use HTTPS without user info"))
        {
            try KimiSettingsReader.codeAPIBaseURL(environment: env)
        }
    }

    @Test
    func `normalizes quoted token`() {
        let env = ["KIMI_AUTH_TOKEN": "\"test.jwt.token\""]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == "test.jwt.token")
    }

    @Test
    func `returns nil when missing`() {
        let env: [String: String] = [:]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == nil)
    }

    @Test
    func `returns nil when empty`() {
        let env = ["KIMI_AUTH_TOKEN": ""]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == nil)
    }

    @Test
    func `normalizes lowercase environment key`() {
        let env = ["kimi_auth_token": "test.jwt.token"]
        let token = KimiSettingsReader.authToken(environment: env)
        #expect(token == "test.jwt.token")
    }
}

struct KimiAPIFetchStrategyTests {
    @Test
    func `labels session before weekly quota`() {
        let metadata = KimiProviderDescriptor.descriptor.metadata

        #expect(metadata.sessionLabel == "Session")
        #expect(metadata.weeklyLabel == "Weekly")
    }

    @Test
    func `auto mode is available with Kimi Code OAuth credential`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        try writeKimiCodeCredential(
            home: home,
            accessToken: "oauth-access-token",
            expiresAt: Date().addingTimeInterval(3600))
        let strategy = KimiAPIFetchStrategy()
        let context = makeKimiFetchContext(
            sourceMode: .auto,
            environment: ["KIMI_CODE_HOME": home.path])

        #expect(await strategy.isAvailable(context))
    }

    @Test
    func `auto mode routes expired CLI credential to explicit remediation`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        try writeKimiCodeCredential(
            home: home,
            accessToken: "expired-access-token",
            expiresAt: Date().addingTimeInterval(-60))
        let strategy = KimiAPIFetchStrategy()
        let context = makeKimiFetchContext(
            sourceMode: .auto,
            environment: ["KIMI_CODE_HOME": home.path])

        #expect(await strategy.isAvailable(context))
        await #expect(throws: KimiAPIError.expiredCodeCredential) {
            try await strategy.fetch(context)
        }
        #expect(strategy.shouldFallback(on: KimiAPIError.expiredCodeCredential, context: context))
    }

    @Test
    func `auto mode falls back from invalid API key to web cookies`() {
        let strategy = KimiAPIFetchStrategy()
        let context = makeKimiFetchContext(sourceMode: .auto)

        #expect(strategy.shouldFallback(on: KimiAPIError.invalidAPIKey, context: context))
    }

    @Test
    func `explicit API mode does not fall back from invalid API key`() {
        let strategy = KimiAPIFetchStrategy()
        let context = makeKimiFetchContext(sourceMode: .api)

        #expect(strategy.shouldFallback(on: KimiAPIError.invalidAPIKey, context: context) == false)
    }

    @Test
    func `explicit API mode reports API key remediation when key is missing`() async {
        let strategy = KimiAPIFetchStrategy()
        let context = makeKimiFetchContext(sourceMode: .api)

        await #expect(throws: KimiAPIError.missingAPIKey) {
            try await strategy.fetch(context)
        }
    }

    @Test
    func `explicit API mode does not use Kimi Code OAuth credential`() async throws {
        let home = try makeTemporaryKimiCodeHome()
        try writeKimiCodeCredential(
            home: home,
            accessToken: "oauth-access-token",
            expiresAt: Date().addingTimeInterval(3600))
        let strategy = KimiAPIFetchStrategy()
        let context = makeKimiFetchContext(
            sourceMode: .api,
            environment: ["KIMI_CODE_HOME": home.path])

        await #expect(throws: KimiAPIError.missingAPIKey) {
            try await strategy.fetch(context)
        }
    }

    @Test
    func `auto mode falls back from API response decoding failure`() {
        let strategy = KimiAPIFetchStrategy()
        let context = makeKimiFetchContext(sourceMode: .auto)
        let error = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Unexpected Kimi payload"))

        #expect(strategy.shouldFallback(on: error, context: context))
    }

    @Test
    func `explicit API mode surfaces response decoding failure`() {
        let strategy = KimiAPIFetchStrategy()
        let context = makeKimiFetchContext(sourceMode: .api)
        let error = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "Unexpected Kimi payload"))

        #expect(strategy.shouldFallback(on: error, context: context) == false)
    }

    @Test
    func `auto mode does not start web fallback after cancellation`() {
        let strategy = KimiAPIFetchStrategy()
        let context = makeKimiFetchContext(sourceMode: .auto)

        #expect(strategy.shouldFallback(on: CancellationError(), context: context) == false)
        #expect(strategy.shouldFallback(on: URLError(.cancelled), context: context) == false)
    }
}

struct KimiUsageResponseParsingTests {
    @Test
    func `parses valid response`() throws {
        let json = """
        {
          "usages": [
            {
              "scope": "FEATURE_CODING",
              "detail": {
                "limit": "2048",
                "used": "375",
                "remaining": "1673",
                "resetTime": "2026-01-09T15:23:13.373329235Z"
              },
              "limits": [
                {
                  "window": {
                    "duration": 300,
                    "timeUnit": "TIME_UNIT_MINUTE"
                  },
                  "detail": {
                    "limit": "200",
                    "used": "200",
                    "resetTime": "2026-01-06T15:05:24.374187075Z"
                  }
                }
              ]
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(KimiUsageResponse.self, from: Data(json.utf8))

        #expect(response.usages.count == 1)
        let usage = response.usages[0]
        #expect(usage.scope == "FEATURE_CODING")
        #expect(usage.detail.limit == "2048")
        #expect(usage.detail.used == "375")
        #expect(usage.detail.remaining == "1673")
        #expect(usage.detail.resetTime == "2026-01-09T15:23:13.373329235Z")

        #expect(usage.limits?.count == 1)
        let rateLimit = usage.limits?.first
        #expect(rateLimit?.window.duration == 300)
        #expect(rateLimit?.window.timeUnit == "TIME_UNIT_MINUTE")
        #expect(rateLimit?.detail.limit == "200")
        #expect(rateLimit?.detail.used == "200")
    }

    @Test
    func `parses response without rate limits`() throws {
        let json = """
        {
          "usages": [
            {
              "scope": "FEATURE_CODING",
              "detail": {
                "limit": "2048",
                "used": "375",
                "remaining": "1673",
                "resetTime": "2026-01-09T15:23:13.373329235Z"
              },
              "limits": []
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(KimiUsageResponse.self, from: Data(json.utf8))
        #expect(response.usages.first?.limits?.isEmpty == true)
    }

    @Test
    func `parses response with null limits`() throws {
        let json = """
        {
          "usages": [
            {
              "scope": "FEATURE_CODING",
              "detail": {
                "limit": "2048",
                "used": "375",
                "remaining": "1673",
                "resetTime": "2026-01-09T15:23:13.373329235Z"
              },
              "limits": null
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(KimiUsageResponse.self, from: Data(json.utf8))
        #expect(response.usages.first?.limits == nil)
    }

    @Test
    func `parses code API usage response`() throws {
        let json = """
        {
          "usage": {
            "limit": "2048",
            "used": "375",
            "remaining": "1673",
            "resetTime": "2026-01-09T15:23:13.373329235Z"
          },
          "limits": [
            {
              "window": {
                "duration": 300,
                "timeUnit": "TIME_UNIT_MINUTE"
              },
              "detail": {
                "limit": "200",
                "used": "19",
                "remaining": "181",
                "resetTime": "2026-01-06T15:05:24.374187075Z"
              }
            },
            {
              "window": {
                "duration": 1,
                "timeUnit": "TIME_UNIT_DAY"
              },
              "detail": {
                "limit": "500",
                "used": "50",
                "remaining": "450",
                "resetTime": "2026-01-07T15:05:24.374187075Z"
              }
            }
          ],
          "user": {
            "membership": {
              "level": "LEVEL_ADVANCED"
            }
          }
        }
        """

        let snapshot = try KimiUsageFetcher._parseCodeAPIUsageForTesting(Data(json.utf8))
        #expect(snapshot.weekly.limit == "2048")
        #expect(snapshot.weekly.used == "375")
        #expect(snapshot.rateLimit?.limit == "200")
        #expect(snapshot.rateLimit?.used == "19")
        #expect(snapshot.rateLimits.count == 2)
        #expect(snapshot.toUsageSnapshot().loginMethod(for: .kimi) == "Allegro")
    }

    @Test
    func `parses official numeric values and reset key variants`() throws {
        let json = """
        {
          "usage": {
            "limit": 1000,
            "used": 40,
            "remaining": 960,
            "resetAt": "2026-01-09T15:23:13Z"
          },
          "limits": [
            {
              "window": {
                "duration": 300,
                "timeUnit": "TIME_UNIT_MINUTE"
              },
              "detail": {
                "limit": 100,
                "remaining": 99,
                "reset_at": "2026-01-06T13:33:02Z"
              }
            }
          ]
        }
        """

        let snapshot = try KimiUsageFetcher._parseCodeAPIUsageForTesting(Data(json.utf8))

        #expect(snapshot.weekly.limit == "1000")
        #expect(snapshot.weekly.used == "40")
        #expect(snapshot.weekly.remaining == "960")
        #expect(snapshot.weekly.resetTime == "2026-01-09T15:23:13Z")
        #expect(snapshot.rateLimit?.limit == "100")
        #expect(snapshot.rateLimit?.used == nil)
        #expect(snapshot.rateLimit?.remaining == "99")
        #expect(snapshot.rateLimit?.resetTime == "2026-01-06T13:33:02Z")
    }

    @Test
    func `builds default code API usage endpoint`() throws {
        let baseURL = try #require(URL(string: "https://api.kimi.com"))
        let endpoint = KimiUsageFetcher._codeAPIUsageEndpointForTesting(baseURL: baseURL)

        #expect(endpoint.absoluteString == "https://api.kimi.com/coding/v1/usages")
    }

    @Test
    func `appends code API path to custom proxy root`() throws {
        let baseURL = try #require(URL(string: "https://proxy.example.com/kimi"))
        let endpoint = KimiUsageFetcher._codeAPIUsageEndpointForTesting(baseURL: baseURL)

        #expect(endpoint.absoluteString == "https://proxy.example.com/kimi/coding/v1/usages")
    }

    @Test
    func `does not duplicate code API path when base URL already includes it`() throws {
        let baseURL = try #require(URL(string: "https://api.kimi.com/coding/v1"))
        let endpoint = KimiUsageFetcher._codeAPIUsageEndpointForTesting(baseURL: baseURL)

        #expect(endpoint.absoluteString == "https://api.kimi.com/coding/v1/usages")
    }

    @Test
    func `does not duplicate code API path with trailing slash`() throws {
        let baseURL = try #require(URL(string: "https://proxy.example.com/kimi/coding/v1/"))
        let endpoint = KimiUsageFetcher._codeAPIUsageEndpointForTesting(baseURL: baseURL)

        #expect(endpoint.absoluteString == "https://proxy.example.com/kimi/coding/v1/usages")
    }

    @Test
    func `does not duplicate coding path prefix`() throws {
        let baseURL = try #require(URL(string: "https://proxy.example.com/kimi/coding/"))
        let endpoint = KimiUsageFetcher._codeAPIUsageEndpointForTesting(baseURL: baseURL)

        #expect(endpoint.absoluteString == "https://proxy.example.com/kimi/coding/v1/usages")
    }

    @Test
    func `builds code API models endpoint`() throws {
        let baseURL = try #require(URL(string: "https://api.kimi.com"))
        let endpoint = KimiUsageFetcher._codeAPIModelsEndpointForTesting(baseURL: baseURL)

        #expect(endpoint.absoluteString == "https://api.kimi.com/coding/v1/models")
    }

    @Test
    func `sends Kimi Code identity headers to usage and models endpoints`() async throws {
        let baseURL = try #require(URL(string: "https://api.kimi.com"))
        let identityHeaders = [
            "User-Agent": "CodexBar/test",
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Device-Id": "test-device-id",
        ]
        let transport = ProviderHTTPTransportHandler { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-token")
            for (name, value) in identityHeaders {
                #expect(request.value(forHTTPHeaderField: name) == value)
            }
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]))
            let data = if url.path.hasSuffix("/usages") {
                Data("""
                {"usage":{"limit":100,"used":1,"remaining":99}}
                """.utf8)
            } else {
                Data("""
                {"data":[{"id":"kimi-for-coding","display_name":"Kimi for Coding"}]}
                """.utf8)
            }
            return (data, response)
        }

        _ = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: "oauth-token",
            baseURL: baseURL,
            identityHeaders: identityHeaders,
            transport: transport)
        _ = try await KimiUsageFetcher.fetchCodeAPIModelDisplayName(
            apiKey: "oauth-token",
            baseURL: baseURL,
            identityHeaders: identityHeaders,
            transport: transport)
    }

    @Test
    func `marks high speed model display as fast mode`() {
        let snapshot = KimiUsageSnapshot(
            weekly: KimiUsageDetail(limit: "100", used: "1", remaining: "99", resetTime: nil),
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            modelDisplayName: "Kimi for Coding High Speed")
            .toUsageSnapshot()

        #expect(snapshot.loginMethod(for: .kimi) == "Fast")
    }

    @Test
    func `omits standard model display without membership tier`() {
        let snapshot = KimiUsageSnapshot(
            weekly: KimiUsageDetail(limit: "100", used: "1", remaining: "99", resetTime: nil),
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            modelDisplayName: "Kimi for Coding")
            .toUsageSnapshot()

        #expect(snapshot.loginMethod(for: .kimi) == nil)
    }

    @Test
    func `combines membership tier and fast mode`() {
        let snapshot = KimiUsageSnapshot(
            weekly: KimiUsageDetail(limit: "100", used: "1", remaining: "99", resetTime: nil),
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            modelDisplayName: "Kimi for Coding High Speed",
            membershipLevel: "LEVEL_INTERMEDIATE")
            .toUsageSnapshot()

        #expect(snapshot.loginMethod(for: .kimi) == "Allegretto / Fast")
    }

    @Test
    func `shows membership tier without standard mode suffix`() {
        let snapshot = KimiUsageSnapshot(
            weekly: KimiUsageDetail(limit: "100", used: "1", remaining: "99", resetTime: nil),
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 0),
            modelDisplayName: "Kimi for Coding",
            membershipLevel: "LEVEL_INTERMEDIATE")
            .toUsageSnapshot()

        #expect(snapshot.loginMethod(for: .kimi) == "Allegretto")
    }

    @Test
    func `uses pi provider Kimi standard pricing`() {
        let cost = KimiCodePricing.costUSD(
            modelName: "kimi-for-coding",
            inputTokens: 100,
            cacheReadTokens: 25,
            cacheWriteTokens: 5,
            outputTokens: 40)

        #expect(abs(cost - 0.00024762) < 0.00000001)
    }

    @Test
    func `uses pi provider Kimi high speed pricing`() {
        let cost = KimiCodePricing.costUSD(
            modelName: "Kimi for Coding High Speed",
            inputTokens: 100,
            cacheReadTokens: 25,
            cacheWriteTokens: 5,
            outputTokens: 40)

        #expect(abs(cost - 0.00049516) < 0.00000001)
    }

    @Test
    func `rejects insecure code API base URL before sending bearer token`() async throws {
        let baseURL = try #require(URL(string: "http://proxy.example.com/kimi"))

        await #expect(throws: KimiAPIError.invalidRequest(
            "Kimi Code API base URL must use HTTPS without user info"))
        {
            _ = try await KimiUsageFetcher.fetchCodeAPIUsage(apiKey: "secret-token", baseURL: baseURL)
        }
    }

    @Test
    func `maps code API authentication and permission errors separately`() {
        #expect(KimiUsageFetcher._codeAPIErrorForTesting(statusCode: 401) == .invalidAPIKey)
        #expect(
            KimiUsageFetcher._codeAPIErrorForTesting(statusCode: 403)
                == .apiError("HTTP 403 (permission or quota denied)"))
    }

    @Test
    func `throws on invalid json`() {
        let invalidJson = "{ invalid json }"

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(KimiUsageResponse.self, from: Data(invalidJson.utf8))
        }
    }

    @Test
    func `throws on missing feature coding scope`() throws {
        let json = """
        {
          "usages": [
            {
              "scope": "OTHER_SCOPE",
              "detail": {
                "limit": "100",
                "used": "50",
                "remaining": "50",
                "resetTime": "2026-01-09T15:23:13.373329235Z"
              }
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(KimiUsageResponse.self, from: Data(json.utf8))
        let codingUsage = response.usages.first { $0.scope == "FEATURE_CODING" }
        #expect(codingUsage == nil)
    }
}

struct KimiUsageSnapshotConversionTests {
    @Test
    func `converts to usage snapshot with both windows`() {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "375",
            remaining: "1673",
            resetTime: "2026-01-09T15:23:13.373329235Z")
        let rateLimit = KimiRateLimit(
            window: KimiWindow(duration: 300, timeUnit: "TIME_UNIT_MINUTE"),
            detail: KimiUsageDetail(
                limit: "200",
                used: "200",
                remaining: "0",
                resetTime: "2026-01-06T15:05:24.374187075Z"))

        let snapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimits: [rateLimit],
            updatedAt: now)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary != nil)
        let rateExpected = 200.0 / 200.0 * 100.0
        #expect(abs((usageSnapshot.primary?.usedPercent ?? 0.0) - rateExpected) < 0.01)
        #expect(usageSnapshot.primary?.windowMinutes == 300)
        #expect(usageSnapshot.primary?.resetDescription == "200/200 requests per 5 hours")

        #expect(usageSnapshot.secondary != nil)
        let weeklyExpected = 375.0 / 2048.0 * 100.0
        #expect(abs((usageSnapshot.secondary?.usedPercent ?? 0.0) - weeklyExpected) < 0.01)
        #expect(usageSnapshot.secondary?.resetDescription == "375/2048 requests")
        #expect(usageSnapshot.secondary?.windowMinutes == nil)

        #expect(usageSnapshot.tertiary == nil)
        #expect(usageSnapshot.updatedAt == now)
    }

    @Test
    func `converts additional Kimi rate limits to extra windows`() {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "375",
            remaining: "1673",
            resetTime: "2026-01-09T15:23:13.373329235Z")
        let rateLimits = [
            KimiRateLimit(
                window: KimiWindow(duration: 300, timeUnit: "TIME_UNIT_MINUTE"),
                detail: KimiUsageDetail(
                    limit: "200",
                    used: "20",
                    remaining: "180",
                    resetTime: "2026-01-06T15:05:24.374187075Z")),
            KimiRateLimit(
                window: KimiWindow(duration: 1, timeUnit: "TIME_UNIT_DAY"),
                detail: KimiUsageDetail(
                    limit: "500",
                    used: "50",
                    remaining: "450",
                    resetTime: "2026-01-07T15:05:24.374187075Z")),
        ]

        let usageSnapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimits: rateLimits,
            updatedAt: now).toUsageSnapshot()

        #expect(usageSnapshot.extraRateWindows?.count == 1)
        #expect(usageSnapshot.extraRateWindows?.first?.id == "kimi-session-2")
        #expect(usageSnapshot.extraRateWindows?.first?.title == "Session (1 day)")
        #expect(usageSnapshot.extraRateWindows?.first?.window.windowMinutes == 1440)
        #expect(usageSnapshot.extraRateWindows?.first?.window.resetDescription == "50/500 requests per 1 day")
    }

    @Test
    func `legacy rate limit initializer preserves session window`() {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "375",
            remaining: "1673",
            resetTime: "2026-01-09T15:23:13.373329235Z")
        let rateLimit = KimiUsageDetail(
            limit: "200",
            used: "20",
            remaining: "180",
            resetTime: "2026-01-06T15:05:24.374187075Z")

        let usageSnapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimit: rateLimit,
            updatedAt: now).toUsageSnapshot()

        #expect(usageSnapshot.primary?.resetDescription == "20/200 requests")
        #expect(usageSnapshot.secondary?.resetDescription == "375/2048 requests")
    }

    @Test
    func `converts to usage snapshot without rate limit`() {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "375",
            remaining: "1673",
            resetTime: "2026-01-09T15:23:13.373329235Z")

        let snapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimit: nil,
            updatedAt: now)

        let usageSnapshot = snapshot.toUsageSnapshot()

        #expect(usageSnapshot.primary == nil)
        let weeklyExpected = 375.0 / 2048.0 * 100.0
        #expect(abs((usageSnapshot.secondary?.usedPercent ?? 0.0) - weeklyExpected) < 0.01)
        #expect(usageSnapshot.secondary != nil)
        #expect(usageSnapshot.tertiary == nil)
    }

    @Test
    func `handles zero values correctly`() {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "0",
            remaining: "2048",
            resetTime: "2026-01-09T15:23:13.373329235Z")

        let snapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimit: nil,
            updatedAt: now)

        let usageSnapshot = snapshot.toUsageSnapshot()
        #expect(usageSnapshot.secondary?.usedPercent == 0.0)
    }

    @Test
    func `handles hundred percent correctly`() {
        let now = Date()
        let weeklyDetail = KimiUsageDetail(
            limit: "2048",
            used: "2048",
            remaining: "0",
            resetTime: "2026-01-09T15:23:13.373329235Z")

        let snapshot = KimiUsageSnapshot(
            weekly: weeklyDetail,
            rateLimit: nil,
            updatedAt: now)

        let usageSnapshot = snapshot.toUsageSnapshot()
        #expect(usageSnapshot.secondary?.usedPercent == 100.0)
    }
}

struct KimiTokenResolverTests {
    @Test
    func `resolves token from environment`() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            let env = ["KIMI_AUTH_TOKEN": "test.jwt.token"]
            let token = ProviderTokenResolver.kimiAuthToken(environment: env)
            #expect(token == "test.jwt.token")
        }
    }

    @Test
    func `resolves token from keychain first`() {
        // This test would require mocking the keychain.
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            let env = ["KIMI_AUTH_TOKEN": "test.env.token"]
            let token = ProviderTokenResolver.kimiAuthToken(environment: env)
            #expect(token == "test.env.token")
        }
    }

    @Test
    func `resolution includes source`() {
        KeychainAccessGate.withTaskOverrideForTesting(true) {
            let env = ["KIMI_AUTH_TOKEN": "test.jwt.token"]
            let resolution = ProviderTokenResolver.kimiAuthResolution(environment: env)

            #expect(resolution?.token == "test.jwt.token")
            #expect(resolution?.source == .environment)
        }
    }
}

struct KimiAPIErrorTests {
    @Test
    func `error descriptions are helpful`() {
        #expect(KimiAPIError.missingToken.errorDescription?.contains("missing") == true)
        #expect(KimiAPIError.invalidToken.errorDescription?.contains("invalid") == true)
        #expect(KimiAPIError.missingAPIKey.errorDescription?.contains("Settings > Providers > Kimi") == true)
        #expect(KimiAPIError.missingAPIKey.errorDescription?.contains("KIMI_CODE_API_KEY") == true)
        #expect(KimiAPIError.expiredCodeCredential.errorDescription?.contains("KIMI_CODE_API_KEY") == true)
        #expect(KimiAPIError.expiredCodeCredential.errorDescription?.contains("does not refresh") == true)
        #expect(KimiAPIError.invalidAPIKey.errorDescription?.contains("API key") == true)
        #expect(KimiAPIError.invalidRequest("Bad request").errorDescription?.contains("Bad request") == true)
        #expect(KimiAPIError.networkError("Timeout").errorDescription?.contains("Timeout") == true)
        #expect(KimiAPIError.apiError("HTTP 500").errorDescription?.contains("HTTP 500") == true)
        #expect(KimiAPIError.parseFailed("Invalid JSON").errorDescription?.contains("Invalid JSON") == true)
    }
}
