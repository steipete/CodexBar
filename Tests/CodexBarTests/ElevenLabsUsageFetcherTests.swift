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
