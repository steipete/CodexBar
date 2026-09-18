import Foundation
import Testing
@testable import CodexBarCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct KimiRatioPoolTests {
    @Test
    func `reported ratio pools retain missing weekly quota and monthly identity`() throws {
        let usage = try Self.parse("""
        {
          "limits": [{
            "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
            "detail": {"limit": "100", "used": "25", "remaining": "75"}
          }],
          "usages": {
            "limit_5h": {"used_ratio": 0, "reset_time": "2026-09-16T20:15:44Z"},
            "limit_month_total": {"used_ratio": 0.0056, "reset_time": "2026-10-17T00:00:00Z"},
            "limit_month_code": {"used_ratio": 0, "reset_time": "2026-10-17T00:00:00Z"}
          }
        }
        """)
        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 0)
        #expect(usage.secondary?.windowMinutes == 300)
        #expect(usage.secondary?.resetsAt == ISO8601DateParser.parse("2026-09-16T20:15:44Z"))
        #expect(usage.secondary?.resetDescription == nil)
        let monthly = try #require(usage.extraRateWindows?.first)
        #expect(monthly.id == "kimi-monthly")
        #expect(monthly.title == "Total usage")
        #expect(abs(monthly.window.usedPercent - 0.56) < 0.00001)
        #expect(monthly.window.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(monthly.window.resetsAt == ISO8601DateParser.parse("2026-10-17T00:00:00Z"))
        #expect(usage.loginMethod(for: .kimi) == nil)
    }

    @Test
    func `ratio weekly and session retain established lane ordering`() throws {
        let usage = try Self.parse("""
        {"usages": {
          "limit_7d": {"used_ratio": 0.125, "reset_time": "2026-09-20T00:00:00Z"},
          "limit_5h": {"used_ratio": 0.625}
        }}
        """)
        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.windowMinutes == 10080)
        #expect(usage.secondary?.usedPercent == 62.5)
        #expect(usage.secondary?.windowMinutes == 300)
        #expect(usage.extraRateWindows == nil)
    }

    @Test
    func `count rate window remains usable without legacy weekly usage`() throws {
        let usage = try Self.parse("""
        {"limits": [{
          "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
          "detail": {"limit": "100", "used": "25", "remaining": "75"}
        }]}
        """)
        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 25)
        #expect(usage.secondary?.resetDescription == "Rate: 25/100 per 5 hours")
    }

    @Test
    func `monthly only response does not invent code windows`() throws {
        let usage = try Self.parse("""
        {"usages": {"limit_month_total": {"used_ratio": 1.05}}}
        """)
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.extraRateWindows?.first?.window.usedPercent == 100)
    }

    @Test
    func `invalid ratio cannot suppress usable legacy counts`() throws {
        let usage = try Self.parse("""
        {"usage": {"limit": "100", "used": "25"},
         "usages": {"limit_7d": {"used_ratio": -0.5}}}
        """)
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetDescription == "25/100 requests")
    }

    @Test(arguments: [200, 503])
    func `web enrichment preserves authoritative API pools`(_ webStatus: Int) async throws {
        let transport = ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let json: String
            let responseStatus: Int
            if url.path.hasSuffix("/usages") {
                json = """
                {"usages": {"limit_5h": {"used_ratio": 0.1},
                            "limit_month_total": {"used_ratio": 0.42}}}
                """
                responseStatus = 200
            } else {
                #expect(url.path.hasSuffix("/GetSubscriptionStats") || url.path.hasSuffix("/GetSubscription"))
                json = """
                {"subscriptionBalance": {"amountUsedRatio": 0.99}}
                """
                responseStatus = webStatus
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: responseStatus,
                httpVersion: nil,
                headerFields: nil))
            return (Data(json.utf8), response)
        }
        let snapshot = try await KimiUsageFetcher.fetchCodeAPIUsage(
            apiKey: "fixture-api-key",
            webAuthToken: "fixture-web-token",
            transport: transport)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 10)
        #expect(usage.extraRateWindows?.first?.window.usedPercent == 42)
    }

    @Test(arguments: ["{}", "{\"usages\":{}}", "{\"usages\":{\"limit_5h\":{}}}"])
    func `unrecognized or empty quotas do not succeed as unused`(_ json: String) {
        #expect(throws: DecodingError.self) {
            try Self.parse(json)
        }
    }

    private static func parse(_ json: String) throws -> UsageSnapshot {
        try KimiUsageFetcher._parseCodeAPIUsageForTesting(Data(json.utf8)).toUsageSnapshot()
    }
}
