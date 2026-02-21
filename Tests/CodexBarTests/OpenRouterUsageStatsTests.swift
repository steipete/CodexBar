import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct OpenRouterUsageStatsTests {
    @Test
    func toUsageSnapshot_usesKeyQuotaForPrimaryWindow() {
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyLimit: 20,
            keyUsage: 5,
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.openRouterUsage?.keyQuotaStatus == .available)
    }

    @Test
    func toUsageSnapshot_withoutValidKeyLimitOmitsPrimaryWindow() {
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyLimit: nil,
            keyUsage: nil,
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.openRouterUsage?.keyQuotaStatus == .unavailable)
    }

    @Test
    func toUsageSnapshot_whenNoLimitConfiguredOmitsPrimaryAndMarksNoLimit() {
        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyDataFetched: true,
            keyLimit: nil,
            keyUsage: nil,
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.openRouterUsage?.keyQuotaStatus == .noLimitConfigured)
    }

    @Test
    func sanitizers_redactSensitiveTokenShapes() {
        let body = """
        {"error":"bad token sk-or-v1-abc123","token":"secret-token","authorization":"Bearer sk-or-v1-xyz789"}
        """

        let summary = OpenRouterUsageFetcher._sanitizedResponseBodySummaryForTesting(body)
        let debugBody = OpenRouterUsageFetcher._redactedDebugResponseBodyForTesting(body)

        #expect(summary.contains("sk-or-v1-[REDACTED]"))
        #expect(summary.contains("\"token\":\"[REDACTED]\""))
        #expect(!summary.contains("secret-token"))
        #expect(!summary.contains("sk-or-v1-abc123"))

        #expect(debugBody?.contains("sk-or-v1-[REDACTED]") == true)
        #expect(debugBody?.contains("\"token\":\"[REDACTED]\"") == true)
        #expect(debugBody?.contains("secret-token") == false)
        #expect(debugBody?.contains("sk-or-v1-xyz789") == false)
    }

    @Test
    func non200FetchThrowsGenericHTTPErrorWithoutBodyDetails() async throws {
        let registered = URLProtocol.registerClass(OpenRouterStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(OpenRouterStubURLProtocol.self)
            }
            OpenRouterStubURLProtocol.handler = nil
        }

        OpenRouterStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = #"{"error":"invalid sk-or-v1-super-secret","token":"dont-leak-me"}"#
            return Self.makeResponse(url: url, body: body, statusCode: 401)
        }

        do {
            _ = try await OpenRouterUsageFetcher.fetchUsage(
                apiKey: "sk-or-v1-test",
                environment: ["OPENROUTER_API_URL": "https://openrouter.test/api/v1"])
            Issue.record("Expected OpenRouterUsageError.apiError")
        } catch let error as OpenRouterUsageError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected apiError, got: \(error)")
                return
            }
            #expect(message == "HTTP 401")
            #expect(!message.contains("dont-leak-me"))
            #expect(!message.contains("sk-or-v1-super-secret"))
        }
    }

    @Test
    func fetchUsage_setsCreditsTimeoutAndClientHeaders() async throws {
        let registered = URLProtocol.registerClass(OpenRouterStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(OpenRouterStubURLProtocol.self)
            }
            OpenRouterStubURLProtocol.handler = nil
        }

        OpenRouterStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/credits":
                #expect(request.timeoutInterval == 15)
                #expect(request.value(forHTTPHeaderField: "HTTP-Referer") == "https://codexbar.example")
                #expect(request.value(forHTTPHeaderField: "X-Title") == "CodexBar QA")
                let body = #"{"data":{"total_credits":100,"total_usage":40}}"#
                return Self.makeResponse(url: url, body: body, statusCode: 200)
            case "/api/v1/key":
                let body = #"{"data":{"limit":20,"usage":0.5,"rate_limit":{"requests":120,"interval":"10s"}}}"#
                return Self.makeResponse(url: url, body: body, statusCode: 200)
            default:
                return Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let usage = try await OpenRouterUsageFetcher.fetchUsage(
            apiKey: "sk-or-v1-test",
            environment: [
                "OPENROUTER_API_URL": "https://openrouter.test/api/v1",
                "OPENROUTER_HTTP_REFERER": " https://codexbar.example ",
                "OPENROUTER_X_TITLE": "CodexBar QA",
            ])

        #expect(usage.totalCredits == 100)
        #expect(usage.totalUsage == 40)
        #expect(usage.keyDataFetched)
        #expect(usage.keyLimit == 20)
        #expect(usage.keyUsage == 0.5)
        #expect(usage.keyRemaining == 19.5)
        #expect(usage.keyUsedPercent == 2.5)
        #expect(usage.keyQuotaStatus == .available)
    }

    @Test
    func fetchUsage_whenKeyEndpointFailsMarksQuotaUnavailable() async throws {
        let registered = URLProtocol.registerClass(OpenRouterStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(OpenRouterStubURLProtocol.self)
            }
            OpenRouterStubURLProtocol.handler = nil
        }

        OpenRouterStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/credits":
                let body = #"{"data":{"total_credits":100,"total_usage":40}}"#
                return Self.makeResponse(url: url, body: body, statusCode: 200)
            case "/api/v1/key":
                return Self.makeResponse(url: url, body: "{}", statusCode: 500)
            default:
                return Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let usage = try await OpenRouterUsageFetcher.fetchUsage(
            apiKey: "sk-or-v1-test",
            environment: ["OPENROUTER_API_URL": "https://openrouter.test/api/v1"])

        #expect(!usage.keyDataFetched)
        #expect(usage.keyQuotaStatus == .unavailable)
    }

    @Test
    func usageSnapshot_roundTripPersistsOpenRouterUsageMetadata() throws {
        let openRouter = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45.3895596325,
            balance: 4.6104403675,
            usedPercent: 90.779119265,
            keyDataFetched: true,
            keyLimit: nil,
            keyUsage: nil,
            rateLimit: nil,
            updatedAt: Date(timeIntervalSince1970: 1_739_841_600))
        let snapshot = openRouter.toUsageSnapshot()

        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: data)

        #expect(decoded.openRouterUsage?.keyDataFetched == true)
        #expect(decoded.openRouterUsage?.keyQuotaStatus == .noLimitConfigured)
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

final class OpenRouterStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "openrouter.test"
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
