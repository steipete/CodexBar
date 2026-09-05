import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ElevenLabsUsageFetcherTests {
    @Test
    func `parses subscription response into usage snapshot`() throws {
        let body = #"""
        {
          "tier": "creator",
          "character_count": 25000,
          "character_limit": 100000,
          "voice_slots_used": 2,
          "voice_limit": 10,
          "professional_voice_slots_used": 1,
          "professional_voice_limit": 2,
          "current_overage": {"amount": "0", "currency": "usd"},
          "status": "active",
          "next_character_count_reset_unix": 1738356858
        }
        """#

        let snapshot = try ElevenLabsUsageFetcher._parseSnapshotForTesting(
            Data(body.utf8),
            updatedAt: Date(timeIntervalSince1970: 1))
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.characterCount == 25000)
        #expect(snapshot.characterLimit == 100_000)
        #expect(snapshot.usedPercent == 25)
        #expect(snapshot.remainingCharacters == 75000)
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "25,000 / 100,000 credits")
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_738_356_858))
        #expect(usage.loginMethod(for: .elevenlabs) == "Creator")
        #expect(usage.extraRateWindows?.count == 2)
    }

    @Test
    func `fetch usage sends xi api key header`() async throws {
        let registered = URLProtocol.registerClass(ElevenLabsStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(ElevenLabsStubURLProtocol.self)
            }
            ElevenLabsStubURLProtocol.handler = nil
        }

        ElevenLabsStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v1/user/subscription")
            #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-test")
            #expect(request.timeoutInterval == 15)

            let body = #"""
            {
              "tier": "starter",
              "character_count": 1000,
              "character_limit": 10000,
              "status": "active"
            }
            """#
            return Self.makeResponse(url: url, body: body, statusCode: 200)
        }

        let usage = try await ElevenLabsUsageFetcher.fetchUsage(
            apiKey: " xi-test ",
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "https://elevenlabs.test"])

        #expect(usage.characterCount == 1000)
        #expect(usage.characterLimit == 10000)
        #expect(usage.usedPercent == 10)
    }

    @Test
    func `fetch usage accepts versioned API base with trailing slash`() async throws {
        let registered = URLProtocol.registerClass(ElevenLabsStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(ElevenLabsStubURLProtocol.self)
            }
            ElevenLabsStubURLProtocol.handler = nil
        }

        ElevenLabsStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            #expect(url.path == "/v1/user/subscription")

            let body = #"""
            {
              "tier": "starter",
              "character_count": 1000,
              "character_limit": 10000,
              "status": "active"
            }
            """#
            return Self.makeResponse(url: url, body: body, statusCode: 200)
        }

        let usage = try await ElevenLabsUsageFetcher.fetchUsage(
            apiKey: "xi-test",
            environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "https://elevenlabs.test/v1/"])

        #expect(usage.characterCount == 1000)
    }

    @Test
    func `non success fetch throws generic HTTP error`() async throws {
        let registered = URLProtocol.registerClass(ElevenLabsStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(ElevenLabsStubURLProtocol.self)
            }
            ElevenLabsStubURLProtocol.handler = nil
        }

        ElevenLabsStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(url: url, body: #"{"detail":"bad xi-test"}"#, statusCode: 500)
        }

        do {
            _ = try await ElevenLabsUsageFetcher.fetchUsage(
                apiKey: "xi-test",
                environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "https://elevenlabs.test"])
            Issue.record("Expected ElevenLabsUsageError.apiError")
        } catch let error as ElevenLabsUsageError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected apiError, got \(error)")
                return
            }
            #expect(message == "HTTP 500")
        }
    }

    @Test
    func `invalid API key is reported as rejected`() async throws {
        let error = try await Self.fetchError(
            statusCode: 401,
            body: #"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#)

        guard case .invalidCredentials = error else {
            Issue.record("Expected invalidCredentials, got \(error)")
            return
        }
        #expect(error.errorDescription ==
            "ElevenLabs rejected the selected API key. Check that it is valid and has not been revoked.")
    }

    @Test
    func `missing API key permission is reported as a permission problem`() async throws {
        let error = try await Self.fetchError(
            statusCode: 401,
            body: #"{"detail":{"status":"missing_permissions","message":"Missing user_read permission"}}"#)

        guard case .missingPermissions = error else {
            Issue.record("Expected missingPermissions, got \(error)")
            return
        }
        #expect(error.errorDescription ==
            "ElevenLabs API key is missing the user_read permission required to fetch subscription usage.")
    }

    @Test
    func `unknown unauthorized response remains a generic authentication error`() async throws {
        let error = try await Self.fetchError(
            statusCode: 401,
            body: #"{"detail":{"status":"authentication_failed","message":"Authentication failed"}}"#)

        guard case .authenticationFailed = error else {
            Issue.record("Expected authenticationFailed, got \(error)")
            return
        }
        #expect(error.errorDescription ==
            "ElevenLabs could not authenticate the selected API key. Check the key and its permissions.")
    }

    @Test
    func `forbidden response reports access restrictions`() async throws {
        let error = try await Self.fetchError(
            statusCode: 403,
            body: #"{"detail":{"status":"forbidden","message":"IP not allowed"}}"#)

        guard case .accessDenied = error else {
            Issue.record("Expected accessDenied, got \(error)")
            return
        }
        #expect(error.errorDescription ==
            "ElevenLabs denied access for the selected API key. Check its endpoint permissions and IP allowlist.")
    }

    @Test(arguments: [
        (401, #"{"detail":{"code":"invalid_api_key"}}"#, ElevenLabsUsageError.invalidCredentials),
        (401, #"{"detail":{"code":"unauthorized","status":"invalid_api_key"}}"#, .invalidCredentials),
        (401, #"{"detail":{"code":" INVALID_API_KEY ","status":"missing_permissions"}}"#, .invalidCredentials),
        (401, #"{"detail":{"code":" ","status":"invalid_api_key"}}"#, .invalidCredentials),
        (403, #"{"detail":{"code":"insufficient_permissions"}}"#, .missingPermissions),
        (403, #"{"detail":{"status":"missing_permissions"}}"#, .missingPermissions),
        (401, #"{"detail":{"code":"unknown","message":"sensitive-response-marker"}}"#, .authenticationFailed),
        (403, #"{"detail":{"code":"unknown","message":"sensitive-response-marker"}}"#, .accessDenied),
        (401, #"{"detail":{}}"#, .authenticationFailed),
        (401, #"{"detail":"sensitive-response-marker"}"#, .authenticationFailed),
        (401, #"{"detail":{"code":123}}"#, .authenticationFailed),
        (403, #"{"detail":null}"#, .accessDenied),
        (401, "", .authenticationFailed),
        (403, "not JSON", .accessDenied),
    ])
    func `current and legacy error details preserve safe diagnostics`(
        statusCode: Int,
        body: String,
        expected: ElevenLabsUsageError) async throws
    {
        let error = try await Self.fetchError(statusCode: statusCode, body: body)
        #expect(error.errorDescription == expected.errorDescription)
        #expect(error.errorDescription?.contains("sensitive-response-marker") == false)
    }

    @Test
    func `blank API keys fail before a request`() async throws {
        let error = try await Self.fetchError(statusCode: 200, body: "{}", apiKey: " \n ")
        guard case .missingCredentials = error else {
            Issue.record("Expected missingCredentials, got \(error)")
            return
        }
    }

    private static func fetchError(
        statusCode: Int,
        body: String,
        apiKey: String = "xi-test") async throws -> ElevenLabsUsageError
    {
        let registered = URLProtocol.registerClass(ElevenLabsStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(ElevenLabsStubURLProtocol.self)
            }
            ElevenLabsStubURLProtocol.handler = nil
        }

        ElevenLabsStubURLProtocol.handler = { request in
            #expect(!apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            guard let url = request.url else { throw URLError(.badURL) }
            return Self.makeResponse(url: url, body: body, statusCode: statusCode)
        }

        do {
            _ = try await ElevenLabsUsageFetcher.fetchUsage(
                apiKey: apiKey,
                environment: [ElevenLabsSettingsReader.apiURLEnvironmentKey: "https://elevenlabs.test"])
            throw ExpectedErrorWasNotThrown()
        } catch let error as ElevenLabsUsageError {
            return error
        }
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (HTTPURLResponse, Data)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }
}

private struct ExpectedErrorWasNotThrown: Error {}

final class ElevenLabsStubURLProtocol: URLProtocol {
    private static let _handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "elevenlabs.test"
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
