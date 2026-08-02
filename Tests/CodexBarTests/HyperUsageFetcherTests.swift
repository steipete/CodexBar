import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct HyperUsageFetcherTests {
    @Test
    func `parses a non-negative Hypercredit balance`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try HyperUsageFetcher._parseSnapshotForTesting(Data(#"{"balance":42.5}"#.utf8), now: now)

        #expect(snapshot.balance == 42.5)
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.toUsageSnapshot().providerCost?.balance == 42.5)
        #expect(snapshot.toUsageSnapshot().providerCost?.used == 0)
        #expect(snapshot.toUsageSnapshot().providerCost?.limit == 0)
        #expect(snapshot.toUsageSnapshot().providerCost?.period == "Hypercredits balance")
        #expect(snapshot.toUsageSnapshot().identity?.providerID == .hyper)
    }

    @Test
    func `fetches credits with a signed in session cookie`() async throws {
        let recorder = HyperRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(#"{"balance":18.5}"#.utf8), response)
        }

        let snapshot = try await HyperUsageFetcher._fetchSessionForTesting(
            cookieHeader: "Cookie: session=fixture-session",
            transport: transport)
        let request = try #require(await recorder.values.first)

        #expect(snapshot.balance == 18.5)
        #expect(request.url?.absoluteString == "https://hyper.charm.land/v1/credits")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture-session")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test
    func `session redirect to login is treated as missing credentials`() async {
        let transport = ProviderHTTPTransportHandler { _ in
            let response = try HTTPURLResponse(
                url: #require(URL(string: "https://hyper.charm.land/auth")),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            return (Data("<html>Log in</html>".utf8), response)
        }

        await #expect(throws: HyperUsageError.missingCredentials) {
            try await HyperUsageFetcher._fetchSessionForTesting(
                cookieHeader: "session=expired",
                transport: transport)
        }
    }

    @Test
    func `fetches documented credits endpoint with a bearer API key`() async throws {
        let recorder = HyperRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(#"{"balance":12}"#.utf8), response)
        }

        let snapshot = try await HyperUsageFetcher._fetchUsageForTesting(apiKey: "fixture-token", transport: transport)
        let request = try #require(await recorder.values.first)

        #expect(snapshot.balance == 12)
        #expect(request.url?.scheme == "https")
        #expect(request.url?.host == "hyper.charm.land")
        #expect(request.url?.path == "/v1/credits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test(arguments: [
        "",
        "{}",
        #"{"balance":"#,
        #"{"balance":-1}"#,
        #"{"balance":"invalid"}"#,
    ])
    func `rejects invalid balances`(payload: String) {
        #expect(throws: HyperUsageError.self) {
            try HyperUsageFetcher._parseSnapshotForTesting(Data(payload.utf8))
        }
    }

    @Test
    func `rejects empty credentials before making a request`() async {
        let transport = ProviderHTTPTransportHandler { _ in
            Issue.record("Transport should not be called for empty credentials")
            throw HyperUsageError.networkError("unexpected request")
        }

        await #expect(throws: HyperUsageError.missingCredentials) {
            try await HyperUsageFetcher._fetchUsageForTesting(apiKey: "  ", transport: transport)
        }
    }

    @Test
    func `reports rejected API keys without exposing the key`() async {
        let transport = ProviderHTTPTransportHandler { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil)!
            return (Data(), response)
        }

        await #expect(throws: HyperUsageError.apiError("API key rejected (HTTP 401).")) {
            try await HyperUsageFetcher._fetchUsageForTesting(apiKey: "secret-fixture", transport: transport)
        }
    }
}

private actor HyperRequestRecorder {
    private(set) var values: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.values.append(request)
    }
}
