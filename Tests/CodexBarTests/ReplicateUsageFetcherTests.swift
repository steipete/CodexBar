import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct ReplicateUsageFetcherTests {
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
    func `invalid root returns parse error`() {
        #expect {
            _ = try ReplicateUsageFetcher._parseSummaryForTesting(Data("[]".utf8))
        } throws: { error in
            guard case ReplicateUsageError.parseFailed = error else { return false }
            return true
        }
    }
}
