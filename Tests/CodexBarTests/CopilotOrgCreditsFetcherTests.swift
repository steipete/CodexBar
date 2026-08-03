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

    @Test
    func `encodes org names that contain path separators`() async throws {
        let transport = self.makeTransport(statusCode: 200, body: #"{"usageItems":[]}"#)

        _ = await CopilotOrgCreditsFetcher(
            token: "test-token-placeholder",
            transport: transport)
            .fetchCreditsUsed(org: "../../etc")

        let requests = await transport.requests()
        let url = try #require(requests.first?.url)

        // `url.path`/`url.pathComponents` re-decode `%2F` back into a literal `/` -- a Foundation
        // quirk that isn't even stable between direct URL access and URLRequest-wrapped access on
        // this platform -- so neither can be trusted to prove safety here. What actually goes on the
        // wire is the encoded string, so assert on that: the separators must survive as `%2F`.
        #expect(url.absoluteString == "https://api.github.com/orgs/..%2F..%2Fetc/settings/billing/ai_credit/usage")
        #expect(!url.absoluteString.contains("/orgs/../../etc"))
    }

    @Test
    func `org lane merges onto an existing snapshot`() {
        let base = CopilotCreditsUsage(
            seat: CopilotCreditsUsage.Lane(creditsUsed: 31, entitlement: 3000, resetsAt: nil),
            org: nil,
            orgLogin: "example-org")
        let merged = base.mergingOrgLane(creditsUsed: 81.1, entitlement: 6000, resetsAt: nil)
        #expect(merged.seat?.creditsUsed == 31)
        #expect(merged.org?.creditsUsed == 81.1)
        #expect(merged.org?.entitlement == 6000)
        #expect(merged.orgLogin == "example-org")
    }
}
