import Foundation
import Testing
@testable import CodexBarCore

struct CopilotOrgCreditsFetcherTests {
    private func makeTransport(
        statusCode: Int,
        body: String) -> ProviderHTTPTransportStub
    {
        ProviderHTTPTransportStub { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        }
    }

    @Test
    func `sums gross quantity across usage items`() async {
        let transport = self.makeTransport(
            statusCode: 200,
            body: """
            {
              "timePeriod": { "year": 2026, "month": 8 },
              "organization": "example-org",
              "usageItems": [
                { "product": "Copilot", "sku": "Copilot AI Credits",
                  "unitType": "ai-credits", "grossQuantity": 31.13 },
                { "product": "Copilot", "sku": "Copilot Cloud Agent",
                  "unitType": "ai-credits", "grossQuantity": 49.97 }
              ]
            }
            """)

        let total = await CopilotOrgCreditsFetcher(
            token: "test-token-placeholder",
            transport: transport)
            .fetchCreditsUsed(org: "example-org")

        #expect(abs((total ?? 0) - 81.10) < 0.001)
        let requests = await transport.requests()
        #expect(requests.first?.url?.path == "/orgs/example-org/settings/billing/ai_credit/usage")
    }

    @Test
    func `returns nil when github rejects the request`() async {
        let transport = self.makeTransport(statusCode: 403, body: #"{"message":"Forbidden"}"#)
        let total = await CopilotOrgCreditsFetcher(
            token: "test-token-placeholder",
            transport: transport)
            .fetchCreditsUsed(org: "example-org")
        #expect(total == nil)
    }

    @Test
    func `returns nil for malformed json`() async {
        let transport = self.makeTransport(statusCode: 200, body: "not json")
        let total = await CopilotOrgCreditsFetcher(
            token: "test-token-placeholder",
            transport: transport)
            .fetchCreditsUsed(org: "example-org")
        #expect(total == nil)
    }

    @Test
    func `returns zero for an empty usage list`() async {
        let transport = self.makeTransport(
            statusCode: 200,
            body: #"{"timePeriod":{"year":2026,"month":8},"organization":"o","usageItems":[]}"#)
        let total = await CopilotOrgCreditsFetcher(
            token: "test-token-placeholder",
            transport: transport)
            .fetchCreditsUsed(org: "o")
        #expect(total == 0)
    }
}
