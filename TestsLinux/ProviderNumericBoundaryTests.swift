import Foundation
import Testing
@testable import CodexBarCore

struct ProviderNumericBoundaryTests {
    @Test(arguments: ["1e100", "\"1e100\"", "\"Infinity\"", "\"NaN\""])
    func `LongCat rejects unrepresentable response codes`(code: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data("{\"code\":\(code),\"data\":{}}".utf8))
        #expect {
            try LongCatEnvelope.unwrap(object)
        } throws: { error in
            guard case LongCatAPIError.parseFailed = error else { return false }
            return true
        }
    }

    @Test(arguments: ["0", "200", "\"2e2\"", "200.9"])
    func `LongCat preserves supported success codes`(code: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data("{\"code\":\(code),\"data\":{\"value\":1}}".utf8))
        let payload = try LongCatEnvelope.unwrap(object) as? [String: Any]
        #expect(payload?["value"] as? Int == 1)
    }

    @Test
    func `LongCat renders oversized token and fuel counts`() throws {
        let data = Data("""
        {"usage":{"totalToken":200000000000000000000,"usedToken":100000000000000000000},
         "fuel":{"totalQuota":200000000000000000000,"list":[{"availableToken":100000000000000000000}]}}
        """.utf8)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let usage = LongCatUsageFetcher.buildSnapshot(
            account: nil,
            tokenPackSummary: nil,
            tokenUsage: payload["usage"] as? [String: Any],
            pendingFuel: payload["fuel"] as? [String: Any]).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 50)
        #expect(usage.primary?.resetDescription == "100000000000000000000/200000000000000000000")
        #expect(usage.secondary?.usedPercent == 50)
        #expect(usage.secondary?.resetDescription == "Fuel pack: 100000000000000000000/200000000000000000000")
        _ = try JSONEncoder().encode(usage)
    }

    @Test
    func `LongCat truncates fractional counts and normalizes zero`() {
        let usage = LongCatUsageSnapshot(
            totalQuota: 10.9, usedQuota: 1.9, fuelPackTotal: 10.9, fuelPackRemaining: -0.25).toUsageSnapshot()
        #expect(usage.primary?.resetDescription == "1/10")
        #expect(usage.secondary?.resetDescription == "Fuel pack: 0/10")
    }

    @Test
    func `LongCat preserves the usable window when fuel totals overflow`() throws {
        let usage = LongCatUsageFetcher.buildSnapshot(
            account: nil,
            tokenPackSummary: nil,
            tokenUsage: ["totalToken": 100, "usedToken": 25],
            pendingFuel: ["totalQuota": 1e308, "list": [["availableToken": 1e308], ["availableToken": 1e308]]])
            .toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.secondary == nil)
        _ = try JSONEncoder().encode(usage)
    }

    @Test(arguments: [Double.infinity, -.infinity, .nan])
    func `LongCat omits nonfinite quota data`(invalid: Double) throws {
        let usage = LongCatUsageSnapshot(
            totalQuota: 100, usedQuota: invalid, fuelPackTotal: 100, fuelPackRemaining: invalid).toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        _ = try JSONEncoder().encode(usage)
    }

    @Test(arguments: [
        ("0", "300", "0/300 credits"),
        ("1.25", "10.5", "1.25/10.50 credits"),
        ("100000000000000000000", "200000000000000000000", "100000000000000000000/200000000000000000000 credits"),
    ])
    func `Kilo formats finite credit counts without integer overflow`(
        used: String, total: String, expected: String) throws
    {
        let data = Data("""
        [{"result":{"data":{"json":{"creditsUsed":\(used),"creditsTotal":\(total)}}}}]
        """.utf8)
        let usage = try KiloUsageFetcher._parseSnapshotForTesting(data).toUsageSnapshot()
        #expect(usage.primary?.resetDescription == expected)
        _ = try JSONEncoder().encode(usage)
    }

    @Test
    func `Kilo omits an overflowed credit total`() throws {
        let data = Data("""
        [{"result":{"data":{"json":{"creditsUsed":1e308,"creditsRemaining":1e308}}}}]
        """.utf8)
        let usage = try KiloUsageFetcher._parseSnapshotForTesting(data).toUsageSnapshot()
        #expect(usage.primary == nil)
        _ = try JSONEncoder().encode(usage)
    }

    @Test(arguments: ["0.000000000000000001", "0." + String(repeating: "0", count: 307) + "1"])
    func `Amp preserves free usage when replenishment durations overflow`(hourly: String) throws {
        let snapshot = try AmpUsageParser.parse(
            displayText: "Amp Free: $0.5/$1 remaining (replenishes +$\(hourly)/hour)")
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 50)
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.primary?.resetsAt == nil)
        _ = try JSONEncoder().encode(usage)
    }

    @Test(arguments: [Double.infinity, .nan, 1e100])
    func `Amp omits unrepresentable window minutes`(hours: Double) {
        let usage = AmpUsageSnapshot(
            freeQuota: 100, freeUsed: 20, hourlyReplenishment: 0, windowHours: hours, updatedAt: Date())
            .toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.windowMinutes == nil)
    }

    @Test(arguments: ["days", "months"])
    func `Amp preserves credits when subscription renewal overflows`(unit: String) throws {
        let snapshot = try AmpUsageParser.parse(displayText: """
        Subscription Pro: 50% other usage and 50% orb usage remaining - resets upon renewal in \(Int.max) \(unit)
        Individual credits: $12 remaining
        """)
        #expect(snapshot.subscription == nil)
        #expect(snapshot.individualCredits == 12)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        _ = try JSONEncoder().encode(usage)
    }

    @Test(arguments: [String(Int.max), String(repeating: "9", count: 30)], ["days", "months"])
    func `Amp uses explicit tier dates even when renewal counts overflow`(renewal: String, unit: String) throws {
        let snapshot = try AmpUsageParser.parse(displayText: """
        Amp Example Tier: agent usage $10 of $20 remaining - \
        period 2026-02-13 to 2026-03-13, resets upon renewal in \(renewal) \(unit)
        """)
        let usage = snapshot.toUsageSnapshot()
        #expect(snapshot.subscription?.agentRemaining == 10)
        #expect(usage.primary?.usedPercent == 50)
        #expect(usage.primary?.windowMinutes == 28 * 24 * 60)
        #expect(usage.primary?.resetsAt == ISO8601DateFormatter().date(from: "2026-03-13T00:00:00Z"))
        _ = try JSONEncoder().encode(usage)
    }

    @Test
    func `monthly pacing retains its original window when inferred minutes overflow`() {
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: Date(timeIntervalSince1970: 8e23),
            resetDescription: nil)
        let resolved = ProviderPaceCapability.calendarMonthResetWindow.resolvedResetWindowForPace(window)
        #expect(resolved.windowMinutes == window.windowMinutes)
        #expect(resolved.usedPercent == 50)
    }

    @Test(arguments: [1e30, -1e30, Double.infinity, -.infinity, .nan])
    func `shared date formatting handles unrepresentable timestamps`(seconds: Double) {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let date = Date(timeIntervalSince1970: seconds)
        #expect(UsageFormatter.resetCountdownDescription(from: date, now: now) == "Unknown")
        #expect(UsageFormatter.updatedString(from: date, now: now) == "Updated Unknown")
        let window = RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: date, resetDescription: nil)
        #expect(UsageFormatter.resetLine(for: window, style: .countdown, now: now) == nil)
        #expect(UsageFormatter.resetLine(for: window, style: .absolute, now: now) == nil)
    }

    @Test
    func `oversized LongCat expiry retains quota details without a reset countdown`() throws {
        let usage = LongCatUsageFetcher.buildSnapshot(
            account: nil,
            tokenPackSummary: nil,
            tokenUsage: nil,
            pendingFuel: ["totalQuota": 1000, "list": [["availableToken": 500, "expireTime": 1e24]]])
            .toUsageSnapshot()
        let window = try #require(usage.secondary)
        #expect(window.usedPercent == 50)
        #expect(window.resetDescription == "Fuel pack: 500/1000")
        #expect(UsageFormatter.resetLine(for: window, style: .countdown) == "Resets Fuel pack: 500/1000")
    }
}
