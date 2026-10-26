import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct KimiMonthlyBreakdownTests {
    @Test
    func `Code API month pools split Total usage into Kimi Code and other features`() throws {
        let usage = try Self.parse("""
        {"usages": {
          "limit_5h": {"used_ratio": 0.0021, "reset_time": "2026-10-12T14:08:39Z"},
          "limit_month_total": {"used_ratio": 0.5761, "reset_time": "2026-10-16T21:08:39Z"},
          "limit_month_code": {"used_ratio": 0.0426, "reset_time": "2026-10-16T21:08:39Z"}
        }}
        """)
        #expect(usage.extraRateWindows?.map(\.id) == ["kimi-monthly"])
        let rows = try Self.breakdownRows(usage)
        #expect(rows.map(\.value) == ["4% used", "53% used"])
        Self.expectProgress(rows, code: 0.0426, other: 0.5335)
    }

    @Test(arguments: [false, true])
    func `web membership ratios split Total usage through web and API enrichment`(api: Bool) async throws {
        let usage = try await KimiGiftBalanceTests.fetch(api: api, stats: """
        {"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION",
          "amountUsedRatio":0.5761,"kimiCodeUsedRatio":0.0426,"expireTime":"2026-10-22T00:00:00Z"}}
        """)
        #expect(usage.extraRateWindows?.map(\.id) == ["kimi-monthly"])
        let rows = try Self.breakdownRows(usage)
        #expect(rows.map(\.value) == ["4% used", "53% used"])
        Self.expectProgress(rows, code: 0.0426, other: 0.5335)
    }

    @Test
    func `Code share is never borrowed from a different source than Total usage`() async throws {
        // The Code API owns Total usage here, so the web Code ratio describes another reading of the pool.
        let usage = try await KimiGiftBalanceTests.fetch(
            api: true,
            stats: #"{"subscriptionBalance":{"amountUsedRatio":0.5761,"kimiCodeUsedRatio":0.0426}}"#,
            codeAPI: #"{"usages":{"limit_month_total":{"used_ratio":0.42}}}"#)
        #expect(usage.extraRateWindows?.first?.window.usedPercent == 42)
        #expect(usage.details.isEmpty)
    }

    @Test(arguments: [
        #""limit_month_total":{"used_ratio":0.5}"#,
        #""limit_month_total":{"used_ratio":0.5},"limit_month_code":{"used_ratio":-0.1}"#,
        #""limit_month_total":{"used_ratio":0.5},"limit_month_code":{"reset_time":"2026-10-17T00:00:00Z"}"#,
        #""limit_month_total":{"used_ratio":-1},"limit_month_code":{"used_ratio":0.1}"#,
    ])
    func `missing or invalid ratios leave Total usage without a breakdown`(monthPools: String) throws {
        let usage = try Self.parse(#"{"usages":{"limit_5h":{"used_ratio":0},"# + monthPools + "}}")
        #expect(usage.secondary?.usedPercent == 0)
        #expect(usage.details.isEmpty)
    }

    @Test
    func `Code share above the reported total floors other features at zero`() throws {
        let usage = try Self.parse(
            #"{"usages":{"limit_month_total":{"used_ratio":0.2},"limit_month_code":{"used_ratio":0.25}}}"#)
        let rows = try Self.breakdownRows(usage)
        #expect(rows.map(\.value) == ["25% used", "0% used"])
        Self.expectProgress(rows, code: 0.25, other: 0)
    }

    @Test
    func `exhausted pool keeps its breakdown beside bonus credits without new quota metrics`() async throws {
        let usage = try await KimiGiftBalanceTests.fetch(api: false, stats: """
        {"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION",
          "amountUsedRatio":1,"kimiCodeUsedRatio":0.2854,"expireTime":"2026-10-22T00:00:00Z"},
         "giftBalances":[{"feature":"FEATURE_OMNI","type":"GIFT","amountUsedRatio":0.2524,
          "expireTime":"2026-12-31T15:59:59Z","displayName":"Invite to Earn Credit"}]}
        """)
        #expect(usage.details.map(\.title) == ["Total usage", "Bonus credits"])
        #expect(usage.extraRateWindows?.map(\.id) == ["kimi-monthly"])
        #expect(try Self.breakdownRows(usage).map(\.value) == ["29% used", "71% used"])

        let model = try KimiMonthlyBlockingTests.model(usage)
        #expect(model.metrics.first { $0.id == "primary" }?.statusText == "Blocked by monthly limit")
        #expect(!model.metrics.contains { $0.title == "Kimi Code" || $0.title == "Other features" })
        let displayed = model.providerDetails.flatMap(\.rows)
        #expect(displayed.compactMap(\.id) == ["kimi-monthly-code", "kimi-monthly-other"])
        #expect(displayed.map(\.label).contains("Invite to Earn Credit"))
    }

    @Test
    func `breakdown rows encode with stable identifiers for CLI JSON`() throws {
        let usage = try Self.parse("""
        {"usages":{"limit_month_total":{"used_ratio":0.5761},"limit_month_code":{"used_ratio":0.0426}}}
        """)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)) as? [String: Any]
        let sections = try #require(object?["details"] as? [[String: Any]])
        #expect(sections.map { $0["title"] as? String } == ["Total usage"])
        let rows = try #require(sections.first?["rows"] as? [[String: Any]])
        #expect(rows.map { $0["id"] as? String } == ["kimi-monthly-code", "kimi-monthly-other"])
        #expect(rows.map { $0["value"] as? String } == ["4% used", "53% used"])
    }

    @Test
    func `malformed optional Code share preserves the valid monthly quota`() throws {
        let usage = try Self.parse("""
        {"usages":{"limit_5h":{"used_ratio":0.25},
          "limit_month_total":{"used_ratio":0.5},"limit_month_code":{"used_ratio":"malformed"}}}
        """)
        #expect(usage.secondary?.usedPercent == 25)
        #expect(usage.extraRateWindows?.first?.window.usedPercent == 50)
        #expect(usage.details.isEmpty)
    }

    @Test
    func `monthly breakdown uses the app language while CLI values stay canonical`() throws {
        let usage = try Self.parse("""
        {"usages":{"limit_month_total":{"used_ratio":0.5761},"limit_month_code":{"used_ratio":0.0426}}}
        """)
        try CodexBarLocalizationOverride.$appLanguage.withValue("fr") {
            let model = try KimiMonthlyBlockingTests.model(usage)
            let rows = try #require(model.providerDetails.first).rows
            let expected = [L("%@ used", "4%"), L("%@ used", "53%")]
            #expect(expected != ["4% used", "53% used"])
            #expect(rows.map(\.value) == expected)
        }
        #expect(try Self.breakdownRows(usage).map(\.value) == ["4% used", "53% used"])
    }

    private static func parse(_ json: String) throws -> UsageSnapshot {
        try KimiUsageFetcher.parseCodeAPIUsage(from: Data(json.utf8)).toUsageSnapshot()
    }

    private static func breakdownRows(_ usage: UsageSnapshot) throws -> [ProviderDetailSection.Row] {
        let section = try #require(usage.details.first { $0.title == "Total usage" })
        #expect(section.rows.map(\.id) == ["kimi-monthly-code", "kimi-monthly-other"])
        #expect(section.rows.map(\.label) == ["Kimi Code", "Other features"])
        #expect(section.rows.allSatisfy { $0.progress?.total == 1 })
        return section.rows
    }

    private static func expectProgress(_ rows: [ProviderDetailSection.Row], code: Double, other: Double) {
        let used = rows.map { $0.progress?.used ?? -1 }
        #expect(used.count == 2)
        #expect(abs(used.first.map { $0 - code } ?? 1) < 0.000001)
        #expect(abs(used.last.map { $0 - other } ?? 1) < 0.000001)
    }
}
