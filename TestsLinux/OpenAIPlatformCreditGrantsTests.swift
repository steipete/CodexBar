import Foundation
import Testing
@testable import CodexBarCore

struct OpenAIPlatformCreditGrantsTests {
    private static let now = Date(timeIntervalSince1970: 1_794_139_200) // 2026-11-08 12:00 UTC
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static func grant(
        _ id: String,
        granted: Double,
        used: Double,
        expiresAt: Int,
        effectiveAt: Int = 1_794_047_545,
        scheduled: Bool = false) -> String
    {
        """
        {"object":"credit_summary","id":"\(id)","grant_amount":\(granted),"used_amount":\(used),
         "effective_at":\(effectiveAt),"expires_at":\(expiresAt),"is_scheduled":\(scheduled),
         "is_held_for_prepaid_transition":false}
        """
    }

    private static func snapshot(
        grants: [String]?,
        totals: String = #""total_granted":124,"total_used":0.834548,"#
            + #""total_available":123.165452"#) throws -> UsageSnapshot
    {
        let grantsJSON = grants.map { #","grants":{"object":"list","data":[\#($0.joined(separator: ","))]}"# } ?? ""
        return try OpenAIPlatformCreditGrants.snapshot(
            from: Data("{\(totals)\(grantsJSON)}".utf8),
            now: Self.now,
            calendar: Self.calendar)
    }

    @Test
    func `subscription grant becomes the credit lane with balance and expiry`() throws {
        let usage = try Self.snapshot(grants: [Self.grant(
            "chatgpt_api_credits_promo_fixture",
            granted: 124,
            used: 0.834548,
            expiresAt: 1_795_712_905)])
        let primary = try #require(usage.primary)
        #expect(primary.resetDescription == "$123.17 of $124.00 left · Expires Nov 26")
        #expect(abs(primary.usedPercent - 0.673) < 0.001)
        #expect(primary.resetsAt == nil)
        #expect(usage.details.isEmpty)
        let cost = try #require(usage.providerCost)
        #expect(cost.used == 123.165452 && cost.balance == 123.165452 && cost.limit == 0)
        #expect(cost.resetsAt == Date(timeIntervalSince1970: 1_795_712_905))
        #expect(cost.currencyCode == "USD" && cost.period == "Prepaid credits")
        #expect(usage.identity?.loginMethod == "Platform session")
    }

    @Test
    func `soonest expiring subscription grant with credit wins`() throws {
        let usage = try Self.snapshot(grants: [
            Self.grant("chatgpt_api_credits_promo_later", granted: 200, used: 0, expiresAt: 1_799_150_400),
            Self.grant("chatgpt_api_credits_promo_sooner", granted: 124, used: 24, expiresAt: 1_795_712_905),
        ])
        #expect(usage.primary?.resetDescription == "$100.00 of $124.00 left · Expires Nov 26")
        let rows = try #require(usage.details.first?.rows)
        #expect(usage.details.first?.title == "Other credit grants")
        #expect(rows.map(\.label) == ["ChatGPT subscription credit"])
        #expect(rows.first?.value == "$200.00 of $200.00 left")
        #expect(rows.first?.secondaryValue == "Expires Jan 5, 2027")
        #expect(rows.first?.progress?.usedPercent == 0)
    }

    @Test
    func `exhausted subscription grant leaves no lane and lists every grant`() throws {
        let usage = try Self.snapshot(grants: [
            Self.grant("chatgpt_api_credits_promo_fixture", granted: 124, used: 130, expiresAt: 1_795_712_905),
            Self.grant("credit_grant_purchased", granted: 50, used: 10, expiresAt: 1_796_904_000),
        ])
        #expect(usage.primary == nil)
        let rows = try #require(usage.details.first?.rows)
        #expect(rows.map(\.label) == ["ChatGPT subscription credit", "Credit grant"])
        #expect(rows.map(\.value) == ["$0.00 of $124.00 left", "$40.00 of $50.00 left"])
        #expect(rows.first?.progress?.usedPercent == 100)
    }

    @Test
    func `expired empty and amountless grants are dropped`() throws {
        let usage = try Self.snapshot(grants: [
            Self.grant("chatgpt_api_credits_promo_old", granted: 200, used: 0, expiresAt: 1_793_534_400),
            Self.grant("credit_grant_empty", granted: 0, used: 0, expiresAt: 1_796_904_000),
            #"{"id":"credit_grant_bare","expires_at":1796904000}"#,
        ])
        #expect(usage.primary == nil)
        #expect(usage.details.isEmpty)
    }

    @Test
    func `scheduled grants never become the lane`() throws {
        let usage = try Self.snapshot(grants: [
            Self.grant(
                "chatgpt_api_credits_promo_next",
                granted: 200,
                used: 0,
                expiresAt: 1_796_904_000,
                scheduled: true),
            Self.grant(
                "chatgpt_api_credits_promo_future",
                granted: 200,
                used: 0,
                expiresAt: 1_799_150_400,
                effectiveAt: 1_796_904_000),
        ])
        #expect(usage.primary == nil)
        #expect(usage.details.first?.rows.map(\.label) == ["Scheduled credit", "Scheduled credit"])
    }

    @Test
    func `missing grants keep the totals as the balance`() throws {
        let usage = try Self.snapshot(grants: nil)
        #expect(usage.primary == nil)
        #expect(usage.details.isEmpty)
        #expect(usage.providerCost?.balance == 123.165452)
    }

    @Test
    func `non numeric balance is a parse failure`() {
        #expect(throws: ProviderFetchClassifiedError(
            kind: .parseFailure,
            message: "Could not parse OpenAI credit grants. The response format may have changed."))
        {
            try Self.snapshot(grants: nil, totals: #""total_available":"124""#)
        }
    }
}
