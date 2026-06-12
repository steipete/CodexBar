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
        case failure(URLError)
        case cancellation
    }

    private var results: [Result]
    private var requests = 0

    init(results: [Result]) {
        self.results = results
    }

    func requestCount() -> Int {
        self.requests
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        self.requests += 1
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
        case let .failure(error):
            throw error
        case .cancellation:
            throw CancellationError()
        }
    }
}
