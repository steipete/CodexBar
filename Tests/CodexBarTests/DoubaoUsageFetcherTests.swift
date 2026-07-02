import Foundation
import Testing
@testable import CodexBarCore

struct DoubaoUsageSnapshotTests {
    @Test
    func `normal usage with both headers present and non-empty reports correct percent`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 750,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "250/1000 requests")
    }

    @Test
    func `boundary normal usage at near-full reports correct percent`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 1,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 99.9)
        #expect(usage.primary?.resetDescription == "999/1000 requests")
    }

    @Test
    func `unreliable headers omit the request limit window`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true,
            requestLimitsReliable: false)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
    }

    @Test
    func `explicit rate limit with zero remaining reports exhausted quota`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
    }

    @Test
    func `both headers missing but key valid omit the request limit window`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
    }

    @Test
    func `invalid key with no headers reports No usage data`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 0,
            limitRequests: 0,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: false)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetDescription == "No usage data")
    }

    @Test
    func `provider identity is correctly tagged as doubao`() {
        let snapshot = DoubaoUsageSnapshot(
            remainingRequests: 500,
            limitRequests: 1000,
            resetTime: nil,
            updatedAt: Date(),
            apiKeyValid: true)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.identity?.providerID == .doubao)
        #expect(usage.identity?.accountEmail == nil)
    }
}

struct DoubaoUsageFetcherTests {
    @Test
    func `coding plan response maps session weekly and monthly windows`() throws {
        let data = Data(
            """
            {
              "ResponseMetadata": {
                "Action": "GetCodingPlanUsage",
                "Version": "2024-01-01",
                "Service": "ark",
                "Region": "cn-beijing"
              },
              "Result": {
                "Status": "Running",
                "UpdateTimestamp": 1782226444,
                "QuotaUsage": [
                  {"Level":"session","Percent":0.116,"ResetTimestamp":1782226478},
                  {"Level":"weekly","Percent":3.182143,"ResetTimestamp":1782662400},
                  {"Level":"monthly","Percent":7.5730535,"ResetTimestamp":1782403199}
                ]
              }
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeCodingPlanUsage(from: data).toUsageSnapshot(
            updatedAt: Date(timeIntervalSince1970: 0))

        #expect(usage.primary?.usedPercent == 0.116)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_782_226_478))
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 3.182143)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.tertiary?.usedPercent == 7.5730535)
        #expect(usage.tertiary?.windowMinutes == 43200)
        #expect(usage.identity?.providerID == .doubao)
        #expect(usage.identity?.loginMethod == "Running")
    }

    @Test
    func `coding plan response ignores missing reset sentinels`() throws {
        let fallbackUpdatedAt = Date(timeIntervalSince1970: 42)
        let data = Data(
            """
            {
              "Result": {
                "Status": "Running",
                "UpdateTimestamp": 0,
                "QuotaUsage": [
                  {"Level":"session","Percent":12.5,"ResetTimestamp":0},
                  {"Level":"weekly","Percent":24,"ResetTimestamp":-1}
                ]
              }
            }
            """.utf8)

        let usage = try DoubaoUsageFetcher.decodeCodingPlanUsage(from: data).toUsageSnapshot(
            updatedAt: fallbackUpdatedAt)

        #expect(usage.updatedAt == fallbackUpdatedAt)
        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.resetsAt == nil)
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 24)
        #expect(usage.secondary?.resetsAt == nil)
        #expect(usage.secondary?.resetDescription == nil)
    }

    @Test
    func `coding plan fetch signs volcengine request`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .rawResponse(
                statusCode: 200,
                body: """
                {
                  "Result": {
                    "Status": "Running",
                    "UpdateTimestamp": 1782226444,
                    "QuotaUsage": [
                      {"Level":"session","Percent":12.5,"ResetTimestamp":1782226478}
                    ]
                  }
                }
                """),
        ])
        let credentials = DoubaoCodingPlanCredentials(
            accessKeyID: "AKLTTEST",
            secretAccessKey: "secret",
            region: "cn-beijing")
        let date = Date(timeIntervalSince1970: 1_781_654_400)

        let snapshot = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
            credentials: credentials,
            session: transport,
            date: date)
        let request = await transport.lastCapturedRequest()

        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 12.5)
        #expect(request?.method == "POST")
        #expect(request?.url == "https://open.volcengineapi.com/?Action=GetCodingPlanUsage&Version=2024-01-01")
        #expect(request?.host == "open.volcengineapi.com")
        #expect(request?.date == "20260617T000000Z")
        #expect(request?.contentSHA256 ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(request?.authorization?.contains(
            "HMAC-SHA256 Credential=AKLTTEST/20260617/cn-beijing/ark/request") == true)
        #expect(request?.authorization?.contains(
            "SignedHeaders=content-type;host;x-content-sha256;x-date") == true)
    }

    @Test
    func `coding plan fetch surfaces volcengine access denied error`() async {
        let transport = DoubaoScriptedTransport(results: [
            .rawResponse(
                statusCode: 403,
                body: """
                {
                  "ResponseMetadata": {
                    "Action": "GetCodingPlanUsage",
                    "Error": {
                      "CodeN": 100013,
                      "Code": "AccessDenied",
                      "Message": "User is not authorized to perform: ark:GetCodingPlanUsage"
                    }
                  }
                }
                """),
        ])
        let credentials = DoubaoCodingPlanCredentials(
            accessKeyID: "AKLTTEST",
            secretAccessKey: "secret",
            region: "cn-beijing")

        await #expect {
            _ = try await DoubaoUsageFetcher.fetchCodingPlanUsage(
                credentials: credentials,
                session: transport,
                date: Date(timeIntervalSince1970: 1_781_654_400))
        } throws: { error in
            guard case let DoubaoUsageError.apiError(code, message) = error else { return false }
            return code == 403
                && message.contains("AccessDenied")
                && message.contains("ark:GetCodingPlanUsage")
                && !message.contains("bytes")
        }
    }

    @Test
    func `repeated successful zero remaining responses omit unknown request limit`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .response(statusCode: 200, limit: 1000, remaining: 0),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `successful final request followed by rate limit reports exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .response(statusCode: 429, limit: 1000, remaining: 0),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `headerless rate limit confirmation preserves exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .response(statusCode: 429, limit: nil, remaining: nil),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `rate limit with request limit header reports exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 429, limit: 1000, remaining: nil),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 1)
    }

    @Test
    func `bare rate limit omits unknown request limit`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 429, limit: nil, remaining: nil),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.rateLimitsUnavailable(for: .doubao))
        #expect(await transport.requestCount() == 1)
    }

    @Test
    func `failed zero remaining confirmation preserves exhausted quota`() async throws {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .failure(URLError(.timedOut)),
        ])

        let snapshot = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription == "1000/1000 requests")
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `task cancellation during confirmation propagates`() async {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .cancellation,
        ])

        await #expect(throws: CancellationError.self) {
            _ = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        }
        #expect(await transport.requestCount() == 2)
    }

    @Test
    func `url cancellation during confirmation propagates`() async {
        let transport = DoubaoScriptedTransport(results: [
            .response(statusCode: 200, limit: 1000, remaining: 0),
            .failure(URLError(.cancelled)),
        ])

        await #expect {
            _ = try await DoubaoUsageFetcher.fetchUsage(apiKey: "test-key", session: transport)
        } throws: { error in
            (error as? URLError)?.code == .cancelled
        }
        #expect(await transport.requestCount() == 2)
    }
}

private actor DoubaoScriptedTransport: ProviderHTTPTransport {
    enum Result {
        case response(statusCode: Int, limit: Int?, remaining: Int?)
        case rawResponse(statusCode: Int, body: String)
        case failure(URLError)
        case cancellation
    }

    struct CapturedRequest {
        let url: String?
        let method: String?
        let host: String?
        let date: String?
        let contentSHA256: String?
        let authorization: String?
    }

    private var results: [Result]
    private var requests = 0
    private var capturedRequest: CapturedRequest?

    init(results: [Result]) {
        self.results = results
    }

    func requestCount() -> Int {
        self.requests
    }

    func lastCapturedRequest() -> CapturedRequest? {
        self.capturedRequest
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.requests += 1
        self.capturedRequest = CapturedRequest(
            url: request.url?.absoluteString,
            method: request.httpMethod,
            host: request.value(forHTTPHeaderField: "Host"),
            date: request.value(forHTTPHeaderField: "X-Date"),
            contentSHA256: request.value(forHTTPHeaderField: "X-Content-Sha256"),
            authorization: request.value(forHTTPHeaderField: "Authorization"))
        let result = self.results.removeFirst()
        switch result {
        case let .response(statusCode, limit, remaining):
            var headers: [String: String] = [:]
            if let limit {
                headers["x-ratelimit-limit-requests"] = String(limit)
            }
            if let remaining {
                headers["x-ratelimit-remaining-requests"] = String(remaining)
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers)!
            return (Data(#"{"usage":{"total_tokens":1}}"#.utf8), response)
        case let .rawResponse(statusCode, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: [:])!
            return (Data(body.utf8), response)
        case let .failure(error):
            throw error
        case .cancellation:
            throw CancellationError()
        }
    }
}
