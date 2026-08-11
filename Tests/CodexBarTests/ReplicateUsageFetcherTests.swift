import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ReplicateUsageFetcherTests {
    private static let invoicesJSON = """
    {
      "invoices": [
        {
          "id": "inv_1",
          "type": "monthly-usage",
          "status": "DRAFT",
          "started_on": "2026-08-01",
          "ended_before": null,
          "total_cost": "12.40",
          "total_cost_before_adjustments": "12.40"
        }
      ]
    }
    """

    private static let creditJSON = """
    { "unused_credit": "80.0", "link_to_add_credit": "https://replicate.com/account/billing#add-credit" }
    """

    private static func httpResponse(url: URL, statusCode: Int) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
    }

    @Test
    func `maps spend balance and username into usage snapshot`() throws {
        let invoicesJSON = """
        {
          "invoices": [
            {
              "id": "inv_1",
              "type": "monthly-usage",
              "status": "DRAFT",
              "started_on": "2026-08-01",
              "ended_before": null,
              "total_cost": "12.40",
              "total_cost_before_adjustments": "12.40"
            }
          ]
        }
        """
        let creditJSON = """
        { "unused_credit": "80.0", "link_to_add_credit": "https://replicate.com/account/billing#add-credit" }
        """

        let summary = try ReplicateUsageFetcher._parseSummaryForTesting(
            Data(invoicesJSON.utf8),
            creditData: Data(creditJSON.utf8),
            username: "demo")

        #expect(abs(summary.currentMonthSpend - 12.4) <= 0.0001)
        #expect(summary.currencyCode == "USD")
        #expect(summary.creditBalance == 80.0)
        #expect(summary.spendLimit == nil)
        #expect(summary.username == "demo")

        let usage = summary.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.secondary == nil)
        #expect(abs((usage.providerCost?.used ?? -1) - 12.4) <= 0.0001)
        #expect(usage.providerCost?.currencyCode == "USD")
        #expect(usage.providerCost?.period == "This month")
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.balance == 80.0)
        #expect(usage.identity?.providerID == UsageProvider.replicate.instanceID)
        #expect(usage.identity?.accountOrganization == "demo")
        #expect(usage.dataConfidence == .exact)

        let detail = usage.primary?.resetDescription ?? ""
        #expect(detail.contains("$12.40 spent this month"))
        #expect(detail.contains("$80.00 credit"))
    }

    @Test
    func `spend only omits missing extras`() throws {
        let invoicesJSON = """
        {
          "invoices": [
            {
              "id": "inv_1",
              "type": "monthly-usage",
              "status": "DRAFT",
              "started_on": "2026-08-01",
              "ended_before": null,
              "total_cost": "0.00",
              "total_cost_before_adjustments": "0.00"
            }
          ]
        }
        """

        let summary = try ReplicateUsageFetcher._parseSummaryForTesting(Data(invoicesJSON.utf8))

        #expect(summary.currentMonthSpend == 0)
        #expect(summary.creditBalance == nil)
        #expect(summary.spendLimit == nil)

        let usage = summary.toUsageSnapshot()
        #expect(usage.providerCost?.used == 0)
        #expect(usage.providerCost?.balance == nil)
        #expect(usage.primary?.resetDescription == "$0.00 spent this month")
    }

    @Test
    func `malformed credit JSON still returns spend`() throws {
        let summary = try ReplicateUsageFetcher._parseSummaryForTesting(
            Data(Self.invoicesJSON.utf8),
            creditData: Data("{not json".utf8),
            username: "demo")

        #expect(abs(summary.currentMonthSpend - 12.4) <= 0.0001)
        #expect(summary.creditBalance == nil)
        #expect(summary.username == "demo")
    }

    @Test
    func `invalid unused credit string still returns spend`() throws {
        let creditJSON = """
        { "unused_credit": "not-a-number", "link_to_add_credit": "https://replicate.com/account/billing#add-credit" }
        """

        let summary = try ReplicateUsageFetcher._parseSummaryForTesting(
            Data(Self.invoicesJSON.utf8),
            creditData: Data(creditJSON.utf8),
            username: "demo")

        #expect(abs(summary.currentMonthSpend - 12.4) <= 0.0001)
        #expect(summary.creditBalance == nil)
        #expect(summary.username == "demo")
    }

    @Test
    func `invalid root returns parse error`() {
        #expect {
            _ = try ReplicateUsageFetcher._parseSummaryForTesting(Data("[]".utf8))
        } throws: { error in
            guard case ReplicateUsageError.parseFailed = error else { return false }
            return true
        }
    }

    @Test
    func `http 401 maps to invalidCredentials`() async {
        let transport = ProviderHTTPTransportStub { request in
            let response = try Self.httpResponse(url: #require(request.url), statusCode: 401)
            return (Data(), response)
        }

        await #expect(throws: ReplicateUsageError.invalidCredentials) {
            _ = try await ReplicateUsageFetcher._fetchUsageForTesting(
                cookieHeader: "sessionid=test",
                username: "demo",
                accountKind: "user",
                transport: transport)
        }
    }

    @Test
    func `http 429 maps to rateLimited`() async {
        let transport = ProviderHTTPTransportStub { request in
            let response = try Self.httpResponse(url: #require(request.url), statusCode: 429)
            return (Data(), response)
        }

        await #expect(throws: ReplicateUsageError.rateLimited) {
            _ = try await ReplicateUsageFetcher._fetchUsageForTesting(
                cookieHeader: "sessionid=test",
                username: "demo",
                accountKind: "user",
                transport: transport)
        }
    }

    @Test
    func `fetches invoices then best effort unused credit`() async throws {
        let invoicesURL = ReplicateBillingEndpoints.userInvoicesURL(username: "demo")
        let creditURL = ReplicateBillingEndpoints.userUnusedCreditURL(username: "demo")
        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url == invoicesURL {
                let response = try Self.httpResponse(url: url, statusCode: 200)
                return (Data(Self.invoicesJSON.utf8), response)
            }
            if url == creditURL {
                let response = try Self.httpResponse(url: url, statusCode: 200)
                return (Data(Self.creditJSON.utf8), response)
            }
            throw URLError(.unsupportedURL)
        }

        let summary = try await ReplicateUsageFetcher._fetchUsageForTesting(
            cookieHeader: "sessionid=test; csrftoken=abc",
            username: "demo",
            accountKind: "user",
            transport: transport)

        #expect(abs(summary.currentMonthSpend - 12.4) <= 0.0001)
        #expect(summary.creditBalance == 80.0)
        #expect(summary.username == "demo")

        let requests = await transport.requests()
        #expect(requests.count == 2)
        #expect(requests[0].url == invoicesURL)
        #expect(requests[1].url == creditURL)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/json" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "sessionid=test; csrftoken=abc" })
        #expect(requests.allSatisfy { $0.timeoutInterval == ReplicateBillingEndpoints.timeoutSeconds })
    }
}
