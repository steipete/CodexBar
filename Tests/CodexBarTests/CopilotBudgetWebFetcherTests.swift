import Foundation
import Testing
@testable import CodexBarCore

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
}
