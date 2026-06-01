import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CopilotBudgetWebFetcherTests {
    @Test
    func `maps positive copilot budgets to extra rate windows`() {
        let budgets: [CopilotBudgetWebFetcher.Budget] = [
            .init(
                id: "product-budget",
                budgetProductSkus: ["copilot"],
                budgetAmount: 100,
                currentAmount: 15),
            .init(
                id: "agent-budget",
                budgetProductSkus: ["copilot_agent_premium_request"],
                budgetAmount: 20,
                currentAmount: 5),
            .init(
                id: "zero-budget",
                budgetProductSkus: ["spark_premium_request"],
                budgetAmount: 0,
                currentAmount: 0),
        ]

        let windows = CopilotBudgetWebFetcher.extraRateWindows(
            from: budgets,
            now: Date(timeIntervalSince1970: 1_780_358_400))

        #expect(windows.map(\.id) == ["copilot-budget-product-budget", "copilot-budget-agent-budget"])
        #expect(windows.map(\.title) == ["Budget - Copilot", "Budget - Copilot Agent Premium Requests"])
        #expect(windows[0].window.usedPercent == 15)
        #expect(windows[1].window.usedPercent == 25)
        #expect(windows.allSatisfy { $0.window.resetsAt != nil })
    }

    @Test
    func `decodes github web budget response shape`() throws {
        let data = Data("""
        {
          "payload": {
            "budgets": [
              {
                "uuid": "budget-1",
                "targetName": "Example",
                "pricingTargetType": "BundlePricing",
                "pricingTargetId": "premium_requests",
                "targetAmount": 30.0,
                "currentAmount": 0.0
              }
            ],
            "has_next_page": false
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(CopilotBudgetWebFetcher.BudgetResponse.self, from: data)
        let budget = try #require(response.budgets.first)
        #expect(response.hasNextPage == false)
        #expect(budget.id == "budget-1")
        #expect(budget.budgetEntityName == "Example")
        #expect(budget.budgetAmount == 30)
        #expect(budget.currentAmount == 0)

        let windows = CopilotBudgetWebFetcher.extraRateWindows(
            from: response.budgets,
            now: Date(timeIntervalSince1970: 1_780_358_400))
        #expect(windows.map(\.title) == ["Budget - All Premium Request SKUs"])
        #expect(windows.first?.window.usedPercent == 0)
    }

    @Test
    func `ignores malformed embedded minus amounts`() throws {
        let data = Data("""
        {
          "budgets": [
            {
              "uuid": "budget-1",
              "pricingTargetId": "premium_requests",
              "targetAmount": "1-5",
              "currentAmount": "$5.00"
            },
            {
              "uuid": "budget-2",
              "pricingTargetId": "premium_requests",
              "targetAmount": "-$15.00",
              "currentAmount": "$5.00"
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(CopilotBudgetWebFetcher.BudgetResponse.self, from: data)

        #expect(response.budgets.map(\.budgetAmount) == [0, -15])
        #expect(CopilotBudgetWebFetcher.extraRateWindows(
            from: response.budgets,
            now: Date(timeIntervalSince1970: 1_780_358_400)).isEmpty)
    }

    @Test
    func `normalizes documented copilot billing names`() {
        #expect(CopilotBudgetWebFetcher.normalizedBillingIdentifier("Copilot") == "copilot")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Copilot Premium Request") ==
                "copilot_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Copilot Agent Premium Request") ==
                "copilot_agent_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Spark Premium Request") ==
                "spark_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Premium requests") ==
                "copilot_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Bundled premium request budget") ==
                "copilot_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Copilot cloud agent premium requests") ==
                "copilot_agent_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("coding_agent_premium_request") ==
                "copilot_agent_premium_request")
    }

    @Test
    func `extracts github fetch nonce from html`() {
        let html = #"<meta name="x-fetch-nonce" content="v2:abc-123">"#
        #expect(CopilotBudgetWebFetcher.extractFetchNonce(from: html) == "v2:abc-123")
    }

    @Test
    func `invalid github budget JSON maps to invalid response`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                return (Data("{".utf8), response)
            }
            return (Data(#"<meta name="x-fetch-nonce" content="nonce">"#.utf8), response)
        }
        let fetcher = CopilotBudgetWebFetcher(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_780_358_400) })

        do {
            _ = try await fetcher.fetchBudgetWindows(cookieHeader: "user_session=abc")
            Issue.record("Expected invalidResponse")
        } catch let error as CopilotBudgetWebFetcher.Error {
            #expect(error == .invalidResponse)
        }
    }

    @Test
    func `cached cookie non auth errors do not fall back to browser import`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.store(provider: .copilot, cookieHeader: "user_session=cached", sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .copilot) }

        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 500,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            return (Data("{}".utf8), response)
        }
        let fetcher = CopilotBudgetWebFetcher(transport: transport)

        do {
            _ = try await fetcher.fetchBudgetWindows()
            Issue.record("Expected badStatus")
        } catch let error as CopilotBudgetWebFetcher.Error {
            #expect(error == .badStatus(500))
        }

        #expect(await transport.requests().count == 2)
        #expect(CookieHeaderCache.load(provider: .copilot)?.cookieHeader == "user_session=cached")
    }

    @Test
    func `budget page request omits content type on get`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                return (Data(#"{"budgets":[],"has_next_page":false}"#.utf8), response)
            }
            return (Data(#"<meta name="x-fetch-nonce" content="nonce">"#.utf8), response)
        }
        let fetcher = CopilotBudgetWebFetcher(transport: transport)

        _ = try await fetcher.fetchBudgetWindows(cookieHeader: "user_session=abc")

        let pageRequest = try #require(await transport.requests().first { $0.url?.query?.contains("page=") == true })
        #expect(pageRequest.value(forHTTPHeaderField: "Content-Type") == nil)
    }
}
