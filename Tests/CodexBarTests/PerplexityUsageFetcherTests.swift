import Foundation
import Testing
@testable import CodexBarCore

struct PerplexityUsageFetcherTests {
    // Fixed "now" so expiry comparisons are deterministic
    private static let now = Date(timeIntervalSince1970: 1_740_000_000) // Feb 20, 2026
    private static let futureTs: TimeInterval = 1_750_000_000 // ~Jun 2025, after now
    private static let pastTs: TimeInterval = 1_700_000_000 // ~Nov 2023, before now
    private static let renewalTs: TimeInterval = 1_743_000_000 // ~Mar 26, 2026

    // MARK: - JSON Parsing

    @Test
    func `parses full response with recurring and promotional credits`() throws {
        let json = """
        {
          "balance_cents": 7250,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 10000, "expires_at_ts": \(Self.futureTs) },
            { "type": "promotional", "amount_cents": 20000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 2750
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)

        #expect(snapshot.recurringTotal == 10000)
        #expect(snapshot.recurringUsed == 2750)
        #expect(snapshot.promoTotal == 20000)
        #expect(snapshot.promoUsed == 0)
        #expect(snapshot.purchasedTotal == 0)
        #expect(snapshot.purchasedUsed == 0)
        #expect(snapshot.balanceCents == 7250)
        #expect(snapshot.totalUsageCents == 2750)
        #expect(abs(snapshot.renewalDate.timeIntervalSince1970 - Self.renewalTs) < 1)
    }

    @Test
    func `waterfall attribution recurring then purchased then promo`() throws {
        // Usage exceeds recurring, spills into purchased, then promo
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 3000,
          "credit_grants": [
            { "type": "recurring",    "amount_cents": 5000, "expires_at_ts": \(Self.futureTs) },
            { "type": "promotional",  "amount_cents": 4000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 9000
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)

        #expect(snapshot.recurringUsed == 5000) // recurring fully consumed
        #expect(snapshot.purchasedUsed == 3000) // purchased fully consumed
        #expect(snapshot.promoUsed == 1000) // 9000 - 5000 - 3000 = 1000 from promo
    }

    @Test
    func `expired promotional grants are excluded`() throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [
            { "type": "recurring",   "amount_cents": 10000, "expires_at_ts": \(Self.futureTs) },
            { "type": "promotional", "amount_cents": 5000,  "expires_at_ts": \(Self.pastTs) }
          ],
          "total_usage_cents": 1000
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)

        #expect(snapshot.promoTotal == 0) // expired grant excluded
        #expect(snapshot.promoUsed == 0)
        #expect(snapshot.promoExpiration == nil)
    }

    @Test
    func `empty credit grants produces zero recurring`() throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [],
          "total_usage_cents": 0
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)

        #expect(snapshot.recurringTotal == 0)
        #expect(snapshot.promoTotal == 0)
        #expect(snapshot.purchasedTotal == 0)
        #expect(snapshot.planName == nil)
    }

    @Test
    func `malformed JSON throws parse failed`() {
        let json = """
        { "balance_cents": "not a number", "credit_grants": null }
        """
        #expect {
            _ = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)
        } throws: { error in
            guard case PerplexityAPIError.parseFailed = error else { return false }
            return true
        }
    }

    // MARK: - Plan Name Inference

    @Test
    func `plan name inference`() throws {
        func makeSnapshot(recurringCents: Double) throws -> PerplexityUsageSnapshot {
            let json = """
            {
              "balance_cents": 0,
              "renewal_date_ts": \(Self.renewalTs),
              "current_period_purchased_cents": 0,
              "credit_grants": [
                { "type": "recurring", "amount_cents": \(recurringCents), "expires_at_ts": \(Self.futureTs) }
              ],
              "total_usage_cents": 0
            }
            """
            return try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)
        }

        #expect(try makeSnapshot(recurringCents: 0).planName == nil)
        #expect(try makeSnapshot(recurringCents: 500).planName == "Pro")
        #expect(try makeSnapshot(recurringCents: 1000).planName == "Pro")
        #expect(try makeSnapshot(recurringCents: 10000).planName == "Max")
    }

    // MARK: - toUsageSnapshot

    @Test
    func `to usage snapshot always has secondary and tertiary`() throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 10000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 0
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()

        // secondary and tertiary always present even when no promo/purchased credits
        #expect(snapshot.secondary != nil)
        #expect(snapshot.tertiary != nil)
    }

    @Test
    func `to usage snapshot zero recurring bar is fully depleted`() throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [],
          "total_usage_cents": 0
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()
        let primary = try #require(snapshot.primary)

        // No recurring credits → bar renders as empty (100% used), not full (0% used)
        #expect(primary.usedPercent == 100.0)
    }

    @Test
    func `to usage snapshot omits primary when only fallback credits remain`() throws {
        let json = """
        {
          "balance_cents": 6000,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 2000,
          "credit_grants": [
            { "type": "promotional", "amount_cents": 4000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 0
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 0.0)
        #expect(snapshot.tertiary?.usedPercent == 0.0)
    }

    @Test
    func `to usage snapshot empty pools bars are fully depleted`() throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 10000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 0
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()
        let secondary = try #require(snapshot.secondary)
        let tertiary = try #require(snapshot.tertiary)

        // Empty pools render as 100% used (empty bar) not 0% used (full bar)
        #expect(secondary.usedPercent == 100.0)
        #expect(tertiary.usedPercent == 100.0)
    }

    // MARK: - Purchased credits from credit_grants

    @Test
    func `purchased credits from credit grants array`() throws {
        // Purchased credits appear as credit_grant type="purchased" instead of
        // current_period_purchased_cents. The snapshot should pick them up.
        let json = """
        {
          "balance_cents": 23065,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [
            { "type": "recurring",    "amount_cents": 10000, "expires_at_ts": \(Self.futureTs) },
            { "type": "purchased",    "amount_cents": 40000 },
            { "type": "promotional",  "amount_cents": 55000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 81935
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)

        #expect(snapshot.recurringTotal == 10000)
        #expect(snapshot.purchasedTotal == 40000)
        #expect(snapshot.promoTotal == 55000)

        // Waterfall: recurring eats 10000, purchased eats 40000, promo eats 31935
        #expect(snapshot.recurringUsed == 10000)
        #expect(snapshot.purchasedUsed == 40000)
        #expect(snapshot.promoUsed == 31935)
    }

    @Test
    func `purchased credits prefer grants over field when both present`() throws {
        // When both current_period_purchased_cents AND credit_grants type="purchased"
        // are provided, the larger value wins.
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 3000,
          "credit_grants": [
            { "type": "recurring",   "amount_cents": 5000, "expires_at_ts": \(Self.futureTs) },
            { "type": "purchased",   "amount_cents": 8000 },
            { "type": "promotional", "amount_cents": 4000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 14000
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)

        // Purchased should use max(8000, 3000) = 8000
        #expect(snapshot.purchasedTotal == 8000)
        // Waterfall: 5000 recurring + 8000 purchased + 1000 promo = 14000
        #expect(snapshot.recurringUsed == 5000)
        #expect(snapshot.purchasedUsed == 8000)
        #expect(snapshot.promoUsed == 1000)
    }

    @Test
    func `purchased credits from field when no grant type`() throws {
        // Legacy path: current_period_purchased_cents is set but no "purchased" grant
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 3000,
          "credit_grants": [
            { "type": "recurring",    "amount_cents": 5000, "expires_at_ts": \(Self.futureTs) },
            { "type": "promotional",  "amount_cents": 4000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 9000
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)

        // Still picks up purchased from the top-level field
        #expect(snapshot.purchasedTotal == 3000)
        #expect(snapshot.recurringUsed == 5000)
        #expect(snapshot.purchasedUsed == 3000)
        #expect(snapshot.promoUsed == 1000)
    }

    @Test
    func `real world max plan with all three pools`() throws {
        // Real-world scenario: Max plan, 10k recurring + 40k purchased + 55k bonus
        // Total 105,000 available, 23,065 remaining → 81,935 used
        let json = """
        {
          "balance_cents": 23065,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [
            { "type": "recurring",    "amount_cents": 10000, "expires_at_ts": \(Self.futureTs) },
            { "type": "purchased",    "amount_cents": 40000 },
            { "type": "promotional",  "amount_cents": 55000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 81935
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)
        let usage = snapshot.toUsageSnapshot()

        // Primary (recurring): fully consumed → 100%
        let primary = try #require(usage.primary)
        #expect(primary.usedPercent == 100.0)

        // Tertiary (purchased): fully consumed → 100%
        let tertiary = try #require(usage.tertiary)
        #expect(tertiary.usedPercent == 100.0)

        // Secondary (bonus): 31935/55000 ≈ 58.06% used → ~42% remaining
        let secondary = try #require(usage.secondary)
        let expectedPromoPercent = 31935.0 / 55000.0 * 100.0
        #expect(abs(secondary.usedPercent - expectedPromoPercent) < 0.1)
    }

    @Test
    func `to usage snapshot primary percent matches usage`() throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 10000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 2500
        }
        """
        let snapshot = try PerplexityUsageFetcher._parseResponseForTesting(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()
        let primary = try #require(snapshot.primary)

        #expect(primary.usedPercent == 25.0)
    }
}
