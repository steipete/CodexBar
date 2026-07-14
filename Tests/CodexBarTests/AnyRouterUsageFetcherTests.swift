import CodexBarCore
import Foundation
import Testing

struct AnyRouterUsageFetcherTests {
    /// Mirrors the payload AnyRouter's own `/api/v1/credits` handler returns: the balance
    /// fields sit at the top level, not inside a `data` object like OpenRouter's.
    private static let creditsJSON = #"""
    {
      "balance": 4.2,
      "monthly_balance": 3,
      "topup_balance": 1.2,
      "used": 0.8,
      "today_cost": 0.5,
      "currency": "usd",
      "billing_provider": "polar"
    }
    """#

    @Test
    func `parses flat credits payload`() throws {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try AnyRouterUsageFetcher._parseSnapshotForTesting(
            Data(Self.creditsJSON.utf8),
            updatedAt: updatedAt)

        #expect(snapshot.balance == 4.2)
        #expect(snapshot.monthlyBalance == 3)
        #expect(snapshot.topupBalance == 1.2)
        #expect(snapshot.used == 0.8)
        #expect(snapshot.todayCost == 0.5)
        #expect(snapshot.currencyCode == "USD")
        #expect(snapshot.updatedAt == updatedAt)
    }

    @Test
    func `total credits count spent plus remaining balance`() throws {
        let snapshot = try AnyRouterUsageFetcher._parseSnapshotForTesting(
            Data(Self.creditsJSON.utf8),
            updatedAt: Date())

        #expect(snapshot.totalCredits == 5.0)
        #expect(abs(snapshot.usedPercent - 16.0) < 0.001)
    }

    @Test
    func `used percent is zero when no credit was ever granted`() throws {
        let snapshot = try AnyRouterUsageFetcher._parseSnapshotForTesting(
            Data(#"{"balance":0,"monthly_balance":0,"topup_balance":0,"used":0,"today_cost":0,"currency":"usd"}"#
                .utf8),
            updatedAt: Date())

        #expect(snapshot.totalCredits == 0)
        #expect(snapshot.usedPercent == 0)
    }

    @Test
    func `usage snapshot exposes spend meter and balance identity`() throws {
        let snapshot = try AnyRouterUsageFetcher._parseSnapshotForTesting(
            Data(Self.creditsJSON.utf8),
            updatedAt: Date()).toUsageSnapshot()

        let primary = try #require(snapshot.primary)
        #expect(abs(primary.usedPercent - 16.0) < 0.001)

        let cost = try #require(snapshot.providerCost)
        #expect(cost.used == 0.8)
        #expect(cost.limit == 5.0)
        #expect(cost.currencyCode == "USD")

        // Identity must stay scoped to AnyRouter — no fields borrowed from another provider.
        let identity = try #require(snapshot.identity)
        #expect(identity.providerID == .anyrouter)
        #expect(identity.accountEmail == nil)
        #expect(identity.loginMethod == "Balance: $4.20")
    }

    @Test
    func `defaults currency to USD when omitted`() throws {
        let snapshot = try AnyRouterUsageFetcher._parseSnapshotForTesting(
            Data(#"{"balance":1,"monthly_balance":1,"topup_balance":0,"used":0,"today_cost":0}"#.utf8),
            updatedAt: Date())

        #expect(snapshot.currencyCode == "USD")
    }

    @Test
    func `rejects malformed payload`() {
        #expect(throws: AnyRouterUsageError.self) {
            try AnyRouterUsageFetcher._parseSnapshotForTesting(
                Data(#"{"credits":"none"}"#.utf8),
                updatedAt: Date())
        }
    }

    @Test
    func `fetch requests credits with bearer key`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let requestURL = try #require(request.url)
            #expect(requestURL.absoluteString == "https://anyrouter.dev/api/v1/credits")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ar-v1-test")
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(Self.creditsJSON.utf8), response)
        }

        let snapshot = try await AnyRouterUsageFetcher.fetchUsage(
            apiKey: "sk-ar-v1-test",
            transport: transport)

        #expect(snapshot.balance == 4.2)
    }

    @Test
    func `fetch honors base URL override`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let requestURL = try #require(request.url)
            #expect(requestURL.absoluteString == "https://gateway.example.com/api/v1/credits")
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data(Self.creditsJSON.utf8), response)
        }

        _ = try await AnyRouterUsageFetcher.fetchUsage(
            apiKey: "sk-ar-v1-test",
            baseURL: #require(URL(string: "https://gateway.example.com/api/v1")),
            transport: transport)
    }

    @Test
    func `fetch reports rejected keys as invalid credentials`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"error":{"code":"invalid_api_key"}}"#.utf8), response)
        }

        await #expect(throws: AnyRouterUsageError.invalidCredentials) {
            try await AnyRouterUsageFetcher.fetchUsage(apiKey: "sk-ar-v1-revoked", transport: transport)
        }
    }

    @Test
    func `fetch surfaces server errors`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: requestURL,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil))
            return (Data(), response)
        }

        await #expect(throws: AnyRouterUsageError.apiError(500)) {
            try await AnyRouterUsageFetcher.fetchUsage(apiKey: "sk-ar-v1-test", transport: transport)
        }
    }

    @Test
    func `fetch rejects an empty API key without calling the network`() async throws {
        let transport = ProviderHTTPTransportHandler { _ in
            Issue.record("Fetcher must not issue a request without an API key")
            throw AnyRouterUsageError.missingCredentials
        }

        await #expect(throws: AnyRouterUsageError.missingCredentials) {
            try await AnyRouterUsageFetcher.fetchUsage(apiKey: "   ", transport: transport)
        }
    }
}
