import Foundation
import Testing
@testable import CodexBarCore

/// Covers the additive schema-v1 display fields the adapter previously dropped:
/// pay-as-you-go spend, the `disabled` marker, measurement freshness, the
/// `lastGoodUsage` fallback, and the `foreign_credential` status sentinel.
struct ClaudeSwapRichUsageParsingTests {
    private func parse(_ json: String) throws -> ClaudeSwapAccountList {
        try ClaudeSwapListParser.parse(Data(json.utf8))
    }

    private func singleAccountPayload(_ row: String) -> String {
        """
        {"schemaVersion": 1, "activeAccountNumber": null, "accounts": [\(row)]}
        """
    }

    @Test
    func `parses the pay as you go spend window`() throws {
        let list = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "ok",
         "usage": {"fiveHour": {"pct": 10},
                   "spend": {"used": 12.5, "limit": 50, "pct": 25, "currency": "USD",
                             "resetsAt": "2026-06-26T17:59:59Z"}}}
        """))

        let spend = try #require(list.accounts.first?.spend)
        #expect(spend.used == 12.5)
        #expect(spend.limit == 50)
        #expect(spend.usedPercent == 25)
        #expect(spend.currencyCode == "USD")
        #expect(spend.resetsAt == Date(timeIntervalSince1970: 1_782_496_799))
    }

    @Test
    func `defaults the spend currency and drops an unusable spend window`() throws {
        let noCurrency = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "ok",
         "usage": {"spend": {"used": 1, "limit": 10, "pct": 10}}}
        """))
        #expect(noCurrency.accounts.first?.spend?.currencyCode == "USD")

        // A zero limit cannot render as a budget; the row's other windows must survive.
        let zeroLimit = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "ok",
         "usage": {"fiveHour": {"pct": 40}, "spend": {"used": 1, "limit": 0, "pct": 0, "currency": "USD"}}}
        """))
        #expect(zeroLimit.accounts.first?.spend == nil)
        #expect(zeroLimit.accounts.first?.fiveHour?.usedPercent == 40)
    }

    @Test
    func `parses the disabled marker and defaults it to false`() throws {
        let disabled = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "ok",
         "usage": {"fiveHour": {"pct": 5}}, "disabled": true}
        """))
        #expect(disabled.accounts.first?.isDisabled == true)

        let absent = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "ok", "usage": {"fiveHour": {"pct": 5}}}
        """))
        #expect(absent.accounts.first?.isDisabled == false)
    }

    @Test
    func `parses how old the served measurement is`() throws {
        let list = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "ok",
         "usage": {"fiveHour": {"pct": 5}},
         "usageFetchedAt": "2026-06-22T20:00:00Z", "usageAgeSeconds": 362.4}
        """))

        let fetchedAt = try #require(list.accounts.first?.usageFetchedAt)
        #expect(fetchedAt == Date(timeIntervalSince1970: 1_782_158_400))
    }

    @Test
    func `parses the last good usage fallback for a row with no live usage`() throws {
        let list = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "token_expired", "usage": null,
         "lastGoodUsage": {"fiveHour": {"pct": 62}, "sevenDay": {"pct": 41},
                           "scoped": [{"pct": 20, "name": "Fable"}],
                           "spend": {"used": 3, "limit": 30, "pct": 10, "currency": "USD"}},
         "lastGoodFetchedAt": "2026-06-22T20:00:00Z", "lastGoodAgeSeconds": 900}
        """))

        let row = try #require(list.accounts.first)
        #expect(row.usageStatus == .tokenExpired)
        #expect(row.fiveHour == nil)
        let lastGood = try #require(row.lastGoodUsage)
        #expect(lastGood.measurement.fiveHour?.usedPercent == 62)
        #expect(lastGood.measurement.sevenDay?.usedPercent == 41)
        #expect(lastGood.measurement.scoped.map(\.name) == ["Fable"])
        #expect(lastGood.measurement.spend?.used == 3)
        #expect(lastGood.fetchedAt == Date(timeIntervalSince1970: 1_782_158_400))
    }

    @Test
    func `drops a last good fallback that carries no windows or no timestamp`() throws {
        let emptyMeasurement = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "token_expired", "usage": null,
         "lastGoodUsage": {}, "lastGoodFetchedAt": "2026-06-22T20:00:00Z"}
        """))
        #expect(emptyMeasurement.accounts.first?.lastGoodUsage == nil)

        // Without a fetch time the numbers cannot be labelled with their age,
        // so they must not be presented as if they were current.
        let noTimestamp = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "token_expired", "usage": null,
         "lastGoodUsage": {"fiveHour": {"pct": 62}}}
        """))
        #expect(noTimestamp.accounts.first?.lastGoodUsage == nil)
    }

    @Test
    func `a malformed last good fallback never fails the account row`() throws {
        let list = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "token_expired", "usage": null,
         "lastGoodUsage": {"fiveHour": {"pct": "nope"}, "sevenDay": {"pct": 41}},
         "lastGoodFetchedAt": "2026-06-22T20:00:00Z"}
        """))

        let lastGood = try #require(list.accounts.first?.lastGoodUsage)
        #expect(lastGood.measurement.fiveHour == nil)
        #expect(lastGood.measurement.sevenDay?.usedPercent == 41)
    }

    /// cswap 0.26 emits `resetsAt` with six fractional digits and an explicit
    /// `+00:00` offset rather than `Z`. A window timestamp that fails to parse
    /// throws, which would reject the whole account list, so pin the real shape.
    @Test
    func `parses reset timestamps in the shape cswap actually emits`() throws {
        let list = try self.parse(self.singleAccountPayload("""
        {"number": 1, "email": "a@b.c", "active": false, "usageStatus": "ok",
         "usage": {"fiveHour": {"pct": 2.0, "resetsAt": "2026-09-06T22:49:59.906176+00:00"},
                   "sevenDay": {"pct": 66.0, "resetsAt": "2026-09-07T03:59:59.906198+00:00"},
                   "scoped": [{"pct": 100.0, "resetsAt": "2026-09-07T03:59:59.906388+00:00", "name": "Fable"}]},
         "usageFetchedAt": "2026-09-06T18:06:23Z", "usageAgeSeconds": 2.3}
        """))

        let row = try #require(list.accounts.first)
        // Fractional seconds are preserved, so compare within a millisecond.
        let fiveHour = try #require(row.fiveHour?.resetsAt)
        #expect(abs(fiveHour.timeIntervalSince1970 - 1_788_734_999.906176) < 0.001)
        let sevenDay = try #require(row.sevenDay?.resetsAt)
        #expect(abs(sevenDay.timeIntervalSince1970 - 1_788_753_599.906198) < 0.001)
        #expect(row.scoped.first?.resetsAt != nil)
        #expect(row.usageFetchedAt != nil)
    }

    @Test
    func `recognizes the foreign credential status sentinel`() throws {
        let list = try self.parse("""
        {"schemaVersion": 1, "activeAccountNumber": 1, "accounts": [
          {"number": 1, "email": "a@b.c", "active": true, "usageStatus": "foreign_credential", "usage": null}
        ]}
        """)

        #expect(list.accounts.first?.usageStatus == .foreignCredential)
    }
}
