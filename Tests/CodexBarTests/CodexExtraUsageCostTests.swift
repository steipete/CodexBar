import Foundation
import Testing
@testable import CodexBarCore

struct CodexExtraUsageCostTests {
    @Test
    func `monthly credit maps to extra usage used versus limit`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 36.8,
                limit: 1000,
                remainingPercent: 96.32,
                resetsAt: Date(timeIntervalSince1970: 1_788_220_800),
                updatedAt: now))

        let cost = try #require(CodexExtraUsageCost.providerCost(from: credits))
        #expect(cost.used == 36.8)
        #expect(cost.limit == 1000)
        #expect(cost.currencyCode == CodexExtraUsageCost.currencyCode)
        #expect(cost.period == "Monthly credit limit")
        #expect(cost.balance == nil)
        #expect(cost.resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
    }

    @Test
    func `purchased extra credits are a remaining balance`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let credits = CreditsSnapshot(remaining: 14.5, events: [], updatedAt: now)

        let cost = try #require(CodexExtraUsageCost.providerCost(from: credits))
        #expect(cost.used == 0)
        #expect(cost.limit == 0)
        #expect(cost.balance == 14.5)
        #expect(cost.period == "Extra usage")
    }

    @Test
    func `purchased extra credits sit beside a monthly cap`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let credits = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 120,
                limit: 400,
                remainingPercent: 70,
                resetsAt: nil,
                updatedAt: now))

        let cost = try #require(CodexExtraUsageCost.providerCost(from: credits))
        #expect(cost.used == 120)
        #expect(cost.limit == 400)
        #expect(cost.balance == 50)
    }

    @Test
    func `monthly remaining is not treated as purchased extra credits`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let credits = CreditsSnapshot(
            remaining: 280,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 120,
                limit: 400,
                remainingPercent: 70,
                resetsAt: nil,
                updatedAt: now))

        let cost = try #require(CodexExtraUsageCost.providerCost(from: credits))
        #expect(cost.balance == nil)
    }

    @Test
    func `zero remaining without a monthly cap retains the successful reading`() {
        let credits = CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())
        #expect(CodexExtraUsageCost.providerCost(from: credits)?.balanceUpdatedAt == credits.updatedAt)
        #expect(CodexExtraUsageCost.providerCost(from: credits)?.balance == nil)
        #expect(CodexExtraUsageCost.providerCost(from: nil) == nil)
    }

    @Test
    func `attached monthly cap wins over balance-only live credits`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let liveCredits = CreditsSnapshot(remaining: 14.5, events: [], updatedAt: now)
        let attached = ProviderCostSnapshot(
            used: 120,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            period: "Monthly credit limit",
            resetsAt: Date(timeIntervalSince1970: 1_788_220_800),
            updatedAt: now)

        let resolved = try #require(CodexExtraUsageCost.resolving(liveCredits: liveCredits, attached: attached))
        #expect(resolved.used == 120)
        #expect(resolved.limit == 400)
        #expect(resolved.resetsAt == Date(timeIntervalSince1970: 1_788_220_800))
        #expect(resolved.balance == 14.5)
    }

    @Test
    func `the fresher cap wins when both sides carry one`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let liveCredits = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: nil,
                updatedAt: now))
        let attached = ProviderCostSnapshot(
            used: 120,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            updatedAt: now.addingTimeInterval(-3600))

        let olderAttached = try #require(CodexExtraUsageCost.resolving(liveCredits: liveCredits, attached: attached))
        #expect(olderAttached.used == 300)

        // A dashboard that refreshed after the retained credits is the authoritative cap.
        let newerAttached = try #require(CodexExtraUsageCost.resolving(
            liveCredits: liveCredits,
            attached: ProviderCostSnapshot(
                used: 380,
                limit: 400,
                currencyCode: CodexExtraUsageCost.currencyCode,
                updatedAt: now.addingTimeInterval(3600))))
        #expect(newerAttached.used == 380)
        #expect(newerAttached.balance == 50)
    }

    @Test
    func `the monthly cap ages by its own timestamp, not the balance refresh`() throws {
        let capFetchedAt = Date(timeIntervalSince1970: 1_780_000_000)
        // CodexMonthlyCreditPreservation.merging pairs a fresh balance fetch with a preserved older cap.
        let preserved = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: capFetchedAt.addingTimeInterval(7200),
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: nil,
                updatedAt: capFetchedAt))

        let live = try #require(CodexExtraUsageCost.providerCost(from: preserved))
        #expect(live.updatedAt == capFetchedAt)

        let resolved = try #require(CodexExtraUsageCost.resolving(
            liveCredits: preserved,
            attached: ProviderCostSnapshot(
                used: 380,
                limit: 400,
                currencyCode: CodexExtraUsageCost.currencyCode,
                updatedAt: capFetchedAt.addingTimeInterval(3600))))
        #expect(resolved.used == 380)
    }

    @Test
    func `the purchased balance comes from the fresher side, not from whichever cap wins`() throws {
        let capFetchedAt = Date(timeIntervalSince1970: 1_780_000_000)
        // The cap and the balance age apart: the preserved cap is two hours behind the credits fetch that
        // carries it, and the dashboard sits in between, so the winning cap is not the fresher balance.
        let preserved = CreditsSnapshot(
            remaining: 50,
            events: [],
            updatedAt: capFetchedAt.addingTimeInterval(7200),
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: nil,
                updatedAt: capFetchedAt))
        let dashboard = ProviderCostSnapshot(
            used: 380,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: 30,
            updatedAt: capFetchedAt.addingTimeInterval(3600))

        let staleDashboardBalance = try #require(CodexExtraUsageCost.resolving(
            liveCredits: preserved,
            attached: dashboard))
        #expect(staleDashboardBalance.used == 380)
        #expect(staleDashboardBalance.balance == 50)

        // The other direction: balance-only credits older than the dashboard yield to its balance.
        let freshDashboardBalance = try #require(CodexExtraUsageCost.resolving(
            liveCredits: CreditsSnapshot(remaining: 14.5, events: [], updatedAt: capFetchedAt),
            attached: dashboard))
        #expect(freshDashboardBalance.balance == 30)
    }

    @Test
    func `a winning live cap still takes the attached balance when its own credits fetch failed`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        // CodexMonthlyCreditPreservation.merging stands a preserved cap up beside a `remaining: 0`
        // placeholder when the credits fetch fails, so the missing balance is unread, not spent.
        let placeholder = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: nil,
                updatedAt: now),
            balanceReadSucceeded: false)
        let dashboard = ProviderCostSnapshot(
            used: 120,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: 30,
            updatedAt: now.addingTimeInterval(-3600))

        let resolved = try #require(CodexExtraUsageCost.resolving(liveCredits: placeholder, attached: dashboard))
        #expect(resolved.used == 300)
        #expect(resolved.balance == 30)
    }

    @Test
    func `a newer successful zero purchased-credit balance clears an older attached balance`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let liveCredits = CreditsSnapshot(
            remaining: 0,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: nil,
                updatedAt: now))
        let dashboard = ProviderCostSnapshot(
            used: 120,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: 30,
            updatedAt: now.addingTimeInterval(-3600))

        let resolved = try #require(CodexExtraUsageCost.resolving(liveCredits: liveCredits, attached: dashboard))
        #expect(resolved.used == 300)
        #expect(resolved.balance == nil)
    }

    @Test
    func `a cap-only dashboard read leaves the purchased balance unread`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        // The dashboard exposes the balance as an optional field, so a cap-only read omits it entirely.
        let capOnly = Self.dashboard(creditsRemaining: nil, at: now)
        let capOnlyCredits = try #require(capOnly.toCreditsSnapshot())
        #expect(capOnlyCredits.remaining == 0)
        #expect(capOnlyCredits.balanceReadSucceeded == false)

        let attached = ProviderCostSnapshot(
            used: 120,
            limit: 400,
            currencyCode: CodexExtraUsageCost.currencyCode,
            balance: 30,
            updatedAt: now.addingTimeInterval(-3600))
        let preserved = try #require(
            CodexExtraUsageCost.resolving(liveCredits: capOnlyCredits, attached: attached))
        #expect(preserved.balance == 30)

        // An explicitly reported zero is a confirmed reading and clears the older attached balance.
        let confirmedZero = try #require(Self.dashboard(creditsRemaining: 0, at: now).toCreditsSnapshot())
        #expect(confirmedZero.balanceReadSucceeded)
        let cleared = try #require(
            CodexExtraUsageCost.resolving(liveCredits: confirmedZero, attached: attached))
        #expect(cleared.balance == nil)
    }

    @Test
    func `a cap-only oauth response leaves the purchased balance unread`() throws {
        // The monthly cap arrives without a `balance` field, so the mapper's `remaining: 0` is a
        // placeholder rather than a reading that the purchased credits are gone.
        let capOnly = try Self.oauthCredits(balanceJSON: nil)
        #expect(capOnly.remaining == 0)
        #expect(capOnly.balanceReadSucceeded == false)

        let explicitZero = try Self.oauthCredits(balanceJSON: "\"0\"")
        #expect(explicitZero.remaining == 0)
        #expect(explicitZero.balanceReadSucceeded)
    }

    private static func oauthCredits(balanceJSON: String?) throws -> CreditsSnapshot {
        let balanceEntry = balanceJSON.map { ",\n            \"balance\": \($0)" } ?? ""
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null,
            "individual_limit": {
              "limit": 100000,
              "used": 7761,
              "remaining_percent": 92.239,
              "resets_at": 1782864000
            }
          },
          "credits": {
            "has_credits": true,
            "unlimited": false\(balanceEntry)
          }
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let result = try CodexOAuthFetchStrategy._mapResultForTesting(Data(json.utf8), credentials: creds)
        return try #require(result.credits)
    }

    private static func dashboard(creditsRemaining: Double?, at date: Date) -> OpenAIDashboardSnapshot {
        OpenAIDashboardSnapshot(
            signedInEmail: nil,
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: creditsRemaining,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 300,
                limit: 400,
                remainingPercent: 25,
                resetsAt: nil,
                updatedAt: date),
            updatedAt: date)
    }

    @Test
    func `legacy credits snapshots treat a missing balance-read flag as succeeded`() throws {
        let original = CreditsSnapshot(
            remaining: 14.5,
            events: [],
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "balanceReadSucceeded")
        let decoded = try JSONDecoder().decode(
            CreditsSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.remaining == 14.5)
        #expect(decoded.balanceReadSucceeded)
    }

    @Test
    func `resolving keeps each side when the other is missing or foreign`() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let liveCredits = CreditsSnapshot(remaining: 14.5, events: [], updatedAt: now)
        let live = try #require(CodexExtraUsageCost.providerCost(from: liveCredits))
        let foreign = ProviderCostSnapshot(used: 4, limit: 50, currencyCode: "USD", updatedAt: now)

        #expect(CodexExtraUsageCost.resolving(liveCredits: nil, attached: foreign) == foreign)
        #expect(CodexExtraUsageCost.resolving(liveCredits: nil, attached: nil) == nil)
        #expect(CodexExtraUsageCost.resolving(liveCredits: liveCredits, attached: nil) == live)
        // Provider-specific by design: a non-credits cost never supplies the Codex monthly cap.
        #expect(CodexExtraUsageCost.resolving(liveCredits: liveCredits, attached: foreign) == live)
    }

    @Test
    func `oauth credits-only result attaches extra usage`() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null
          },
          "credits": {
            "has_credits": true,
            "unlimited": false,
            "balance": "14.5"
          }
        }
        """
        let creds = CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: nil,
            lastRefresh: Date())
        let result = try CodexOAuthFetchStrategy._mapResultForTesting(Data(json.utf8), credentials: creds)
        #expect(result.credits?.remaining == 14.5)
        #expect(result.usage.providerCost?.balance == 14.5)
        #expect(result.usage.providerCost?.currencyCode == CodexExtraUsageCost.currencyCode)
    }
}
