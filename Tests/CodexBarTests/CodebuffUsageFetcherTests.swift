import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CodebuffUsageFetcherTests {
    @Test
    func `usage URL composes the correct endpoint`() throws {
        let base = try #require(URL(string: "https://www.codebuff.com"))
        let url = CodebuffUsageFetcher.usageURL(baseURL: base)
        #expect(url.absoluteString == "https://www.codebuff.com/api/v1/usage")
    }

    @Test
    func `subscription URL composes the correct endpoint`() throws {
        let base = try #require(URL(string: "https://www.codebuff.com"))
        let url = CodebuffUsageFetcher.subscriptionURL(baseURL: base)
        #expect(url.absoluteString == "https://www.codebuff.com/api/user/subscription")
    }

    @Test
    func `usage request sends required fingerprint id`() async throws {
        defer {
            CodebuffStubURLProtocol.handler = nil
            CodebuffStubURLProtocol.requests = []
            CodebuffStubURLProtocol.requestBodies = []
        }
        CodebuffStubURLProtocol.requests = []
        CodebuffStubURLProtocol.requestBodies = []
        CodebuffStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/usage":
                return try Self.makeResponse(url: url, body: #"{"usage":25,"quota":100,"remainingBalance":75}"#)
            case "/api/user/subscription":
                return try Self.makeResponse(url: url, body: "{}")
            default:
                return try Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let snapshot = try await CodebuffUsageFetcher.fetchUsage(apiKey: "cb-test", session: Self.makeSession())
        let usageIndex = try #require(CodebuffStubURLProtocol.requests.firstIndex {
            $0.url?.path == "/api/v1/usage"
        })
        let body = try #require(CodebuffStubURLProtocol.requestBodies[usageIndex])
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])

        #expect(payload["fingerprintId"] == "codexbar-usage")
        #expect(snapshot.creditsUsed == 25)
    }

    @Test
    func `usage fetch can skip subscription endpoint for API key tokens`() async throws {
        defer {
            CodebuffStubURLProtocol.handler = nil
            CodebuffStubURLProtocol.requests = []
            CodebuffStubURLProtocol.requestBodies = []
        }
        CodebuffStubURLProtocol.requests = []
        CodebuffStubURLProtocol.requestBodies = []
        CodebuffStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            switch url.path {
            case "/api/v1/usage":
                return try Self.makeResponse(url: url, body: #"{"usage":25,"quota":100,"remainingBalance":75}"#)
            case "/api/user/subscription":
                Issue.record("Subscription endpoint should not be called for API key tokens")
                return try Self.makeResponse(url: url, body: "{}", statusCode: 500)
            default:
                return try Self.makeResponse(url: url, body: "{}", statusCode: 404)
            }
        }

        let snapshot = try await CodebuffUsageFetcher.fetchUsage(
            apiKey: "cb-test",
            includeSubscription: false,
            session: Self.makeSession())

        #expect(snapshot.creditsUsed == 25)
        #expect(CodebuffStubURLProtocol.requests.map(\.url?.path) == ["/api/v1/usage"])
    }

    @Test
    func `api strategy only fetches subscription for credentials file tokens`() {
        let envResolution = ProviderTokenResolution(token: "env-token", source: .environment)
        let fileResolution = ProviderTokenResolution(token: "file-token", source: .authFile)

        #expect(CodebuffAPIFetchStrategy.shouldFetchSubscription(for: envResolution) == false)
        #expect(CodebuffAPIFetchStrategy.shouldFetchSubscription(for: fileResolution) == true)
    }

    @Test
    func `status 401 maps to unauthorized`() {
        #expect(CodebuffUsageFetcher._statusErrorForTesting(401) == .unauthorized)
        #expect(CodebuffUsageFetcher._statusErrorForTesting(403) == .unauthorized)
    }

    @Test
    func `status 404 maps to endpoint not found`() {
        #expect(CodebuffUsageFetcher._statusErrorForTesting(404) == .endpointNotFound)
    }

    @Test
    func `status 500 maps to service unavailable`() {
        guard case .serviceUnavailable(503) = CodebuffUsageFetcher._statusErrorForTesting(503)
        else {
            Issue.record("Expected .serviceUnavailable(503)")
            return
        }
    }

    @Test
    func `status 200 returns nil`() {
        #expect(CodebuffUsageFetcher._statusErrorForTesting(200) == nil)
    }

    @Test
    func `usage payload parses numeric credit fields`() throws {
        let json = """
        {
          "usage": 1250,
          "quota": 5000,
          "remainingBalance": 3750,
          "autoTopupEnabled": true,
          "next_quota_reset": "2026-05-01T00:00:00Z"
        }
        """

        let payload = try CodebuffUsageFetcher._parseUsagePayloadForTesting(Data(json.utf8))
        #expect(payload.used == 1250)
        #expect(payload.total == 5000)
        #expect(payload.remaining == 3750)
        #expect(payload.autoTopupEnabled == true)
        #expect(payload.nextQuotaReset != nil)
    }

    @Test
    func `usage payload accepts string-encoded numbers`() throws {
        let json = """
        { "usage": "12", "quota": "100", "remainingBalance": "88" }
        """
        let payload = try CodebuffUsageFetcher._parseUsagePayloadForTesting(Data(json.utf8))
        #expect(payload.used == 12)
        #expect(payload.total == 100)
        #expect(payload.remaining == 88)
    }

    @Test
    func `usage payload returns nil fields when absent`() throws {
        let payload = try CodebuffUsageFetcher._parseUsagePayloadForTesting(Data("{}".utf8))
        #expect(payload.used == nil)
        #expect(payload.total == nil)
        #expect(payload.remaining == nil)
        #expect(payload.autoTopupEnabled == nil)
    }

    @Test
    func `usage payload throws on malformed JSON`() {
        #expect {
            _ = try CodebuffUsageFetcher._parseUsagePayloadForTesting(Data("not-json".utf8))
        } throws: { error in
            guard case CodebuffUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `subscription payload parses tier and weekly window`() throws {
        let json = """
        {
          "hasSubscription": true,
          "subscription": {
            "status": "active",
            "tier": "pro",
            "billingPeriodEnd": "2026-05-15T00:00:00Z"
          },
          "rateLimit": {
            "weeklyUsed": 2100,
            "weeklyLimit": 7000,
            "weeklyResetsAt": "2026-05-08T00:00:00Z"
          },
          "email": "user@example.com"
        }
        """

        let payload = try CodebuffUsageFetcher._parseSubscriptionPayloadForTesting(Data(json.utf8))
        #expect(payload.tier == "pro")
        #expect(payload.status == "active")
        #expect(payload.weeklyUsed == 2100)
        #expect(payload.weeklyLimit == 7000)
        #expect(payload.weeklyResetsAt != nil)
        #expect(payload.email == "user@example.com")
        #expect(payload.billingPeriodEnd != nil)
    }

    @Test
    func `subscription payload prefers display name over numeric tier`() throws {
        let json = """
        { "subscription": { "tier": 2, "displayName": "Pro" } }
        """
        let payload = try CodebuffUsageFetcher._parseSubscriptionPayloadForTesting(Data(json.utf8))
        #expect(payload.tier == "Pro")
    }

    @Test
    func `subscription payload falls back to numeric scheduled tier`() throws {
        let json = """
        { "subscription": { "scheduledTier": 3 } }
        """
        let payload = try CodebuffUsageFetcher._parseSubscriptionPayloadForTesting(Data(json.utf8))
        #expect(payload.tier == "3")
    }

    @Test
    func `subscription payload formats oversized numeric tier without trapping`() throws {
        let json = """
        { "subscription": { "scheduledTier": 9223372036854775808 } }
        """
        let payload = try CodebuffUsageFetcher._parseSubscriptionPayloadForTesting(Data(json.utf8))
        #expect(payload.tier == "9223372036854775808")
    }

    @Test
    func `subscription payload tolerates missing rate limit`() throws {
        let json = """
        { "subscription": { "status": "trialing", "tier": "free" } }
        """
        let payload = try CodebuffUsageFetcher._parseSubscriptionPayloadForTesting(Data(json.utf8))
        #expect(payload.weeklyUsed == nil)
        #expect(payload.weeklyLimit == nil)
        #expect(payload.status == "trialing")
    }

    @Test
    func `snapshot maps to rate window with credits window`() {
        let snapshot = CodebuffUsageSnapshot(
            creditsUsed: 250,
            creditsTotal: 1000,
            creditsRemaining: 750,
            weeklyUsed: 100,
            weeklyLimit: 500,
            weeklyResetsAt: Date(timeIntervalSince1970: 1_777_680_000),
            tier: "pro",
            autoTopUpEnabled: true,
            updatedAt: Date())

        let unified = snapshot.toUsageSnapshot()
        #expect(unified.primary?.usedPercent == 25)
        // The credit balance is intentionally NOT stored in `resetDescription` —
        // generic renderers prepend "Resets " when `resetsAt` is absent, which would
        // surface misleading text like "Resets 250/1,000 credits".
        #expect(unified.primary?.resetDescription == nil)
        #expect(unified.secondary?.usedPercent == 20)
        #expect(unified.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(unified.secondary?.resetsAt == Date(timeIntervalSince1970: 1_777_680_000))
        #expect(unified.secondary?.resetDescription == nil)
        #expect(unified.identity?.providerID == .codebuff)
        #expect(unified.identity?.loginMethod?.contains("Pro") == true)
        #expect(unified.identity?.loginMethod?.contains("auto top-up") == true)
    }

    @Test
    func `snapshot infers total from used plus remaining`() {
        let snapshot = CodebuffUsageSnapshot(
            creditsUsed: 40,
            creditsTotal: nil,
            creditsRemaining: 60)

        let unified = snapshot.toUsageSnapshot()
        #expect(unified.primary?.usedPercent == 40)
    }

    @Test
    func `snapshot surfaces exhausted state when quota is missing from payload`() {
        // Only `creditsUsed` is populated (no total, no remaining) — the API response is
        // degenerate but we still want the row to be visible so the user notices the
        // missing configuration instead of seeing an empty/healthy-looking bar.
        let usedOnly = CodebuffUsageSnapshot(
            creditsUsed: 42,
            creditsTotal: nil,
            creditsRemaining: nil)
        #expect(usedOnly.toUsageSnapshot().primary?.usedPercent == 100)

        // Only `creditsRemaining` is populated — same fallback should apply.
        let remainingOnly = CodebuffUsageSnapshot(
            creditsUsed: nil,
            creditsTotal: nil,
            creditsRemaining: 17)
        #expect(remainingOnly.toUsageSnapshot().primary?.usedPercent == 100)
    }

    @Test
    func `snapshot hides credit window when no credit fields are present`() {
        let empty = CodebuffUsageSnapshot()
        #expect(empty.toUsageSnapshot().primary == nil)
    }

    @Test
    func `missing credentials fetch call throws missing credentials`() async {
        do {
            _ = try await CodebuffUsageFetcher.fetchUsage(apiKey: "   ")
            Issue.record("Expected missingCredentials error")
        } catch let error as CodebuffUsageError {
            #expect(error == .missingCredentials)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodebuffStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private static func makeResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) throws -> (HTTPURLResponse, Data)
    {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])
        else {
            throw URLError(.badServerResponse)
        }
        return (response, Data(body.utf8))
    }
}

final class CodebuffStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var requestBodies: [Data?] = []

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "www.codebuff.com"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(self.request)
        Self.requestBodies.append(Self.bodyData(from: self.request))
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

    private static func bodyData(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}
