import Foundation
import Testing
@testable import CodexBarCore

/// Personal/Solo Token Plans now report a single monthly window
/// (`per1MonthPercentage` / `per1MonthResetTime`) instead of 5-hour + weekly.
struct AlibabaTokenPlanMonthlyWindowLinuxTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// Shape of `bl console call --api zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage --output json`.
    private static let consoleCallEnvelope = #"""
    {
      "code": "200",
      "data": {
        "DataV2": {
          "ret": ["SUCCESS::接口调用成功"],
          "data": {
            "msg": "Success.",
            "code": "SUCCESS",
            "data": {
              "per1MonthPercentage": 0.25,
              "per1MonthResetTime": 1791043200000
            },
            "success": true
          }
        },
        "success": true,
        "httpStatus": 200,
        "api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
      },
      "httpStatusCode": "200",
      "successResponse": true
    }
    """#

    @Test
    func `CLI parser accepts a monthly-only flat payload`() throws {
        let snapshot = try AlibabaTokenPlanCLIUsageParser.parse(
            Data(#"{"per1MonthPercentage":0.25,"per1MonthResetTime":1791043200000}"#.utf8),
            now: Self.now)

        #expect(snapshot.fiveHourUsedPercent == nil)
        #expect(snapshot.weeklyUsedPercent == nil)
        #expect(snapshot.monthlyUsedPercent == 25)
        #expect(snapshot.monthlyResetsAt == Date(timeIntervalSince1970: 1_791_043_200))
    }

    @Test
    func `CLI parser unwraps the console call envelope`() throws {
        let snapshot = try AlibabaTokenPlanCLIUsageParser.parse(
            Data(Self.consoleCallEnvelope.utf8),
            now: Self.now)

        #expect(snapshot.monthlyUsedPercent == 25)
        #expect(snapshot.monthlyResetsAt == Date(timeIntervalSince1970: 1_791_043_200))
        #expect(snapshot.updatedAt == Self.now)
    }

    @Test
    func `monthly-only usage becomes the primary monthly window`() throws {
        let usage = try AlibabaTokenPlanCLIUsageParser.parse(
            Data(Self.consoleCallEnvelope.utf8),
            now: Self.now).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.windowMinutes == 30 * 24 * 60)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_791_043_200))
        #expect(usage.secondary == nil)
        #expect(usage.tertiary == nil)
    }

    @Test
    func `monthly window is tertiary when rolling windows are also present`() throws {
        let usage = try AlibabaTokenPlanCLIUsageParser.parse(Data(#"""
        {
            "per5HourPercentage": 0.10,
            "per1WeekPercentage": 0.20,
            "per1MonthPercentage": 0.30
        }
        """#.utf8), now: Self.now).toUsageSnapshot()

        #expect(usage.primary?.windowMinutes == 5 * 60)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(usage.tertiary?.usedPercent == 30)
        #expect(usage.tertiary?.windowMinutes == 30 * 24 * 60)
    }

    @Test
    func `CLI parser still rejects payloads without any valid window`() {
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
            try AlibabaTokenPlanCLIUsageParser.parse(Data(#"{}"#.utf8), now: Self.now)
        }
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
            try AlibabaTokenPlanCLIUsageParser.parse(
                Data(#"{"per1MonthPercentage":1.5}"#.utf8),
                now: Self.now)
        }
    }

    @Test
    func `CLI route reads the raw personal usage API`() {
        #expect(AlibabaTokenPlanCLIUsageFetcher.arguments(region: .internationalPersonal) == [
            "console", "call",
            "--api", "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
            "--data", "{}",
            "--console-region", "ap-southeast-1",
            "--console-site", "international",
            "--output", "json",
        ])
    }

    @Test
    func `personal web parser reads the monthly window and its quota total`() throws {
        let subscription = Data(#"""
        {"data":{"DataV2":{"data":{"data":{"specCode":"standard","status":"VALID"}}}}}
        """#.utf8)
        let quotaConfig = Data(#"""
        {"data":{"DataV2":{"data":{"data":{
            "lite":{"five_hour":700,"monthly":11500},
            "standard":{"five_hour":3000,"monthly":45000}
        }}}}}
        """#.utf8)

        let snapshot = try AlibabaTokenPlanPersonalUsageParser.parse(
            from: Data(Self.consoleCallEnvelope.utf8),
            subscriptionData: subscription,
            quotaConfigData: quotaConfig,
            now: Self.now)

        #expect(snapshot.planName == "Standard")
        #expect(snapshot.monthlyUsedPercent == 25)
        #expect(snapshot.monthlyTotalQuota == 45000)
        #expect(snapshot.monthlyResetsAt == Date(timeIntervalSince1970: 1_791_043_200))
        #expect(snapshot.toUsageSnapshot().primary?.resetDescription == "11,250 / 45,000 credits used")
    }
}
