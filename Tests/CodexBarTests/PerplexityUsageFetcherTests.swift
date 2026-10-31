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

    @Test(arguments: ["recurring", "promotional", "purchased"])
    func `large credit pools retain their percentage and whole count description`(_ type: String) async throws {
        let json = """
        {
          "balance_cents": 1e20,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [{"type":"\(type)","amount_cents":2e20}],
          "total_usage_cents": 1e20
        }
        """
        let usage = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()
        let window = switch type {
        case "recurring": usage.primary
        case "promotional": usage.secondary
        default: usage.tertiary
        }
        let unit = type == "promotional" ? "bonus" : "credits"

        #expect(window?.usedPercent == 50)
        #expect(window?.resetDescription == "100000000000000000000/200000000000000000000 \(unit)")
    }

    @Test(arguments: [(1.6, "2/10 credits"), (-0.25, "0/10 credits")])
    func `credit descriptions preserve rounding and unsigned zero`(used: Double, expected: String) async throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [{"type":"recurring","amount_cents":10.9}],
          "total_usage_cents": \(used)
        }
        """
        let usage = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()

        #expect(usage.primary?.resetDescription == expected)
    }

    @Test
    func `overflowing credit sums omit nonfinite count descriptions`() async throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [
            {"type":"recurring","amount_cents":1e308},
            {"type":"recurring","amount_cents":1e308}
          ],
          "total_usage_cents": 1
        }
        """
        let usage = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()

        #expect(usage.primary != nil)
        #expect(usage.primary?.resetDescription == nil)
    }

    @Test
    func `parses full response with recurring and promotional credits`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)

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
    func `waterfall attribution recurring then purchased then promo`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)

        #expect(snapshot.recurringUsed == 5000) // recurring fully consumed
        #expect(snapshot.purchasedUsed == 3000) // purchased fully consumed
        #expect(snapshot.promoUsed == 1000) // 9000 - 5000 - 3000 = 1000 from promo
    }

    @Test
    func `expired promotional grants are excluded`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)

        #expect(snapshot.promoTotal == 0) // expired grant excluded
        #expect(snapshot.promoUsed == 0)
        #expect(snapshot.promoExpiration == nil)
    }

    @Test
    func `empty credit grants produces zero recurring`() async throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [],
          "total_usage_cents": 0
        }
        """
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)

        #expect(snapshot.recurringTotal == 0)
        #expect(snapshot.promoTotal == 0)
        #expect(snapshot.purchasedTotal == 0)
        #expect(snapshot.planName == nil)
    }

    @Test
    func `malformed JSON throws parse failed`() async {
        let json = """
        { "balance_cents": "not a number", "credit_grants": null }
        """
        await #expect {
            _ = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
        } throws: { error in
            guard case PerplexityAPIError.parseFailed = error else { return false }
            return true
        }
    }

    // MARK: - Plan Name Inference

    @Test
    func `plan name inference`() async throws {
        func makeSnapshot(recurringCents: Double) async throws -> PerplexityUsageSnapshot {
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
            return try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
        }

        #expect(try await makeSnapshot(recurringCents: 0).planName == nil)
        #expect(try await makeSnapshot(recurringCents: 500).planName == "Pro")
        #expect(try await makeSnapshot(recurringCents: 1000).planName == "Pro")
        #expect(try await makeSnapshot(recurringCents: 10000).planName == "Max")
    }

    // MARK: - toUsageSnapshot

    @Test
    func `to usage snapshot always has secondary and tertiary`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()

        // secondary and tertiary always present even when no promo/purchased credits
        #expect(snapshot.secondary != nil)
        #expect(snapshot.tertiary != nil)
    }

    @Test
    func `to usage snapshot zero recurring bar is fully depleted`() async throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "credit_grants": [],
          "total_usage_cents": 0
        }
        """
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()
        let primary = try #require(snapshot.primary)

        // No recurring credits → bar renders as empty (100% used), not full (0% used)
        #expect(primary.usedPercent == 100.0)
    }

    @Test
    func `to usage snapshot omits primary when only fallback credits remain`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 0.0)
        #expect(snapshot.tertiary?.usedPercent == 0.0)
    }

    @Test
    func `to usage snapshot empty pools bars are fully depleted`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()
        let secondary = try #require(snapshot.secondary)
        let tertiary = try #require(snapshot.tertiary)

        // Empty pools render as 100% used (empty bar) not 0% used (full bar)
        #expect(secondary.usedPercent == 100.0)
        #expect(tertiary.usedPercent == 100.0)
    }

    // MARK: - Purchased credits from credit_grants

    @Test
    func `purchased credits from credit grants array`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)

        #expect(snapshot.recurringTotal == 10000)
        #expect(snapshot.purchasedTotal == 40000)
        #expect(snapshot.promoTotal == 55000)

        // Waterfall: recurring eats 10000, purchased eats 40000, promo eats 31935
        #expect(snapshot.recurringUsed == 10000)
        #expect(snapshot.purchasedUsed == 40000)
        #expect(snapshot.promoUsed == 31935)
    }

    @Test
    func `purchased credits prefer grants over field when both present`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)

        // Purchased should use max(8000, 3000) = 8000
        #expect(snapshot.purchasedTotal == 8000)
        // Waterfall: 5000 recurring + 8000 purchased + 1000 promo = 14000
        #expect(snapshot.recurringUsed == 5000)
        #expect(snapshot.purchasedUsed == 8000)
        #expect(snapshot.promoUsed == 1000)
    }

    @Test
    func `purchased credits from field when no grant type`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)

        // Still picks up purchased from the top-level field
        #expect(snapshot.purchasedTotal == 3000)
        #expect(snapshot.recurringUsed == 5000)
        #expect(snapshot.purchasedUsed == 3000)
        #expect(snapshot.promoUsed == 1000)
    }

    @Test
    func `real world max plan with all three pools`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
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
    func `to usage snapshot primary percent matches usage`() async throws {
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
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()
        let primary = try #require(snapshot.primary)

        #expect(primary.usedPercent == 25.0)
    }

    // MARK: - Organization pool credits

    @Test
    func `org member with exhausted seat credits shows available org credits`() async throws {
        // Sanitized billing v2 response from #4826 (thread_usage and invoices removed).
        let json = """
        {
          "balance_cents": 3342.28,
          "renewal_date_ts": 1794405600,
          "spending_limit_cents": null,
          "global_cap_cents": 100000,
          "current_period_purchased_cents": 0,
          "org_pool_draws_cents": 24371,
          "org_user_cap_cents": 300000,
          "is_org_pool_depleted": false,
          "is_fully_migrated_to_billing_v2": true,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 500, "remaining_cents": 0,
              "expires_at_ts": 1794405600, "effective_at_ts": 1791727200,
              "amount_applied_prior_period_cents": 0, "is_admin_grant": null,
              "is_manual_org_pool_reload": null, "priority": 30 }
          ],
          "meter_usage": [{ "meter_type": "asi_token_usage", "cost_cents": 24870.74 }],
          "total_usage_cents": 24870.74
        }
        """
        let usage = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 100)
        let org = try #require(usage.extraRateWindows?.first)
        #expect(usage.extraRateWindows?.count == 1)
        #expect(org.id == "org-credits")
        #expect(org.title == "Organization")
        #expect(abs(org.window.usedPercent - 24371 / (24371 + 3342.28) * 100) < 0.0001)
        #expect(org.window.resetDescription == "24371/27713 credits")
        #expect(usage.automaticPerplexityWindow() == org.window)
        #expect(usage.orderedPerplexityDisplayWindows().first == org.window)
    }

    @Test
    func `org member with seat credits left keeps recurring lane first`() async throws {
        // 4000 of the 10000 seat credits used, nothing drawn from the org pool yet. balance_cents covers the
        // 6000 seat credits left plus 5000 available from the org pool.
        let json = """
        {
          "balance_cents": 11000,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "org_pool_draws_cents": 0,
          "org_user_cap_cents": 300000,
          "is_org_pool_depleted": false,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 10000, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 4000
        }
        """
        let snapshot = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.orgUsed == 0)
        #expect(snapshot.orgAvailable == 5000)
        #expect(usage.primary?.usedPercent == 40)
        let org = try #require(usage.extraRateWindows?.first)
        #expect(org.window.usedPercent == 0)
        #expect(org.window.resetDescription == "0/5000 credits")
        #expect(usage.automaticPerplexityWindow() == usage.primary)
    }

    @Test
    func `org lane appears when only one org field is reported`() async throws {
        let json = """
        {
          "balance_cents": 1000,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "org_pool_draws_cents": 3000,
          "org_user_cap_cents": null,
          "is_org_pool_depleted": null,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 500, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 3500
        }
        """
        let usage = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()
        let org = try #require(usage.extraRateWindows?.first)

        #expect(org.window.usedPercent == 75)
        #expect(org.window.resetDescription == "3000/4000 credits")
        #expect(usage.automaticPerplexityWindow() == org.window)
    }

    @Test
    func `null org fields do not add an org lane`() async throws {
        let json = """
        {
          "balance_cents": 0,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "org_pool_draws_cents": null,
          "org_user_cap_cents": null,
          "is_org_pool_depleted": null,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 500, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 500
        }
        """
        let usage = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()

        #expect(usage.extraRateWindows == nil)
        #expect(usage.automaticPerplexityWindow()?.remainingPercent == 0)
    }

    @Test
    func `depleted org pool reads as exhausted`() async throws {
        let json = """
        {
          "balance_cents": 120,
          "renewal_date_ts": \(Self.renewalTs),
          "current_period_purchased_cents": 0,
          "org_pool_draws_cents": 300000,
          "org_user_cap_cents": 300000,
          "is_org_pool_depleted": true,
          "credit_grants": [
            { "type": "recurring", "amount_cents": 500, "expires_at_ts": \(Self.futureTs) }
          ],
          "total_usage_cents": 300500
        }
        """
        let usage = try await CookiePluginFixtures.perplexity(Data(json.utf8), now: Self.now)
            .toUsageSnapshot()
        let org = try #require(usage.extraRateWindows?.first)

        #expect(org.window.usedPercent == 100)
        #expect(org.window.resetDescription == "300000/300000 credits")
        #expect(usage.automaticPerplexityWindow()?.remainingPercent == 0)
    }
}
