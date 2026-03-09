import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct ZaiSettingsReaderTests {
    @Test
    func apiTokenReadsFromEnvironment() {
        let token = ZaiSettingsReader.apiToken(environment: ["Z_AI_API_KEY": "abc123"])
        #expect(token == "abc123")
    }

    @Test
    func apiTokenStripsQuotes() {
        let token = ZaiSettingsReader.apiToken(environment: ["Z_AI_API_KEY": "\"token-xyz\""])
        #expect(token == "token-xyz")
    }

    @Test
    func apiHostReadsFromEnvironment() {
        let host = ZaiSettingsReader.apiHost(environment: [ZaiSettingsReader.apiHostKey: " open.bigmodel.cn "])
        #expect(host == "open.bigmodel.cn")
    }

    @Test
    func quotaURLInfersScheme() {
        let url = ZaiSettingsReader
            .quotaURL(environment: [ZaiSettingsReader.quotaURLKey: "open.bigmodel.cn/api/coding"])
        #expect(url?.absoluteString == "https://open.bigmodel.cn/api/coding")
    }
}

@Suite
struct ZaiUsageSnapshotTests {
    @Test
    func mapsUsageSnapshotWindows() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: 100,
            currentValue: 20,
            remaining: 80,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let timeLimit = ZaiLimitEntry(
            type: .timeLimit,
            unit: .days,
            number: 30,
            usage: 200,
            currentValue: 40,
            remaining: 160,
            percentage: 50,
            usageDetails: [],
            nextResetTime: nil)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: timeLimit,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == reset)
        #expect(usage.primary?.resetDescription == "5 hours window")
        #expect(usage.secondary?.usedPercent == 20)
        #expect(usage.secondary?.resetDescription == "30 days window")
        #expect(usage.zaiUsage?.tokenLimit?.usage == 100)
    }

    @Test
    func mapsUsageSnapshotWindowsWithMissingFields() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: nil,
            currentValue: nil,
            remaining: nil,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: nil,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == reset)
        #expect(usage.primary?.resetDescription == "5 hours window")
        #expect(usage.zaiUsage?.tokenLimit?.usage == nil)
    }

    @Test
    func mapsUsageSnapshotWindowsWithMissingRemainingUsesCurrentValue() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: 100,
            currentValue: 20,
            remaining: nil,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: nil,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
    }

    @Test
    func mapsUsageSnapshotWindowsWithMissingCurrentValueUsesRemaining() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: 100,
            currentValue: nil,
            remaining: 80,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: nil,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 20)
    }

    @Test
    func mapsUsageSnapshotWindowsWithMissingRemainingAndCurrentValueFallsBackToPercentage() {
        let reset = Date(timeIntervalSince1970: 123)
        let tokenLimit = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .hours,
            number: 5,
            usage: 100,
            currentValue: nil,
            remaining: nil,
            percentage: 25,
            usageDetails: [],
            nextResetTime: reset)
        let snapshot = ZaiUsageSnapshot(
            tokenLimit: tokenLimit,
            timeLimit: nil,
            planName: nil,
            updatedAt: reset)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
    }
}

@Suite
struct ZaiUsageParsingTests {
    @Test
    func emptyBodyReturnsParseFailed() {
        #expect {
            _ = try ZaiUsageFetcher.parseUsageSnapshot(from: Data())
        } throws: { error in
            guard case let ZaiUsageError.parseFailed(message) = error else { return false }
            return message == "Empty response body"
        }
    }

    @Test
    func parsesUsageResponse() throws {
        let json = """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": {
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 100,
                "currentValue": 102,
                "remaining": 0,
                "percentage": 100,
                "usageDetails": [
                  { "modelCode": "search-prime", "usage": 95 }
                ]
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "usage": 40000000,
                "currentValue": 13628365,
                "remaining": 26371635,
                "percentage": 34,
                "nextResetTime": 1768507567547
              }
            ],
            "planName": "Pro"
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.tokenLimit?.usage == 40_000_000)
        #expect(snapshot.timeLimit?.usageDetails.first?.modelCode == "search-prime")
        #expect(snapshot.tokenLimit?.percentage == 34.0)
    }

    @Test
    func missingDataReturnsApiError() {
        let json = """
        { "code": 1001, "msg": "Authorization Token Missing", "success": false }
        """

        #expect {
            _ = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        } throws: { error in
            guard case let ZaiUsageError.apiError(message) = error else { return false }
            return message == "Authorization Token Missing"
        }
    }

    @Test
    func successWithoutDataReturnsParseFailed() {
        let json = """
        { "code": 200, "msg": "Operation successful", "success": true }
        """

        #expect {
            _ = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        } throws: { error in
            guard case let ZaiUsageError.parseFailed(message) = error else { return false }
            return message == "Missing data"
        }
    }

    @Test
    func successWithoutLimitsParsesEmptyUsage() throws {
        let json = """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": { "planName": "Pro" },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.tokenLimit == nil)
        #expect(snapshot.timeLimit == nil)
    }

    @Test
    func parsesNewSchemaWithMissingTokenLimitFields() throws {
        let json = """
        {
          "code": 200,
          "msg": "Operation successful",
          "data": {
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 100,
                "currentValue": 0,
                "remaining": 100,
                "percentage": 0,
                "usageDetails": [
                  { "modelCode": "search-prime", "usage": 0 },
                  { "modelCode": "web-reader", "usage": 1 },
                  { "modelCode": "zread", "usage": 0 }
                ]
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 1,
                "nextResetTime": 1770724088678
              }
            ]
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.tokenLimit?.percentage == 1.0)
        #expect(snapshot.tokenLimit?.usage == nil)
        #expect(snapshot.tokenLimit?.currentValue == nil)
        #expect(snapshot.tokenLimit?.remaining == nil)
        #expect(snapshot.tokenLimit?.usedPercent == 1.0)
        #expect(snapshot.tokenLimit?.windowMinutes == 300)
        #expect(snapshot.timeLimit?.usage == 100)
    }
}

@Suite
struct ZaiAPIRegionTests {
    @Test
    func defaultsToGlobalEndpoint() {
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .global, environment: [:])
        #expect(url.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
    }

    @Test
    func usesBigModelRegionWhenSelected() {
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .bigmodelCN, environment: [:])
        #expect(url.absoluteString == "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
    }

    @Test
    func quotaUrlEnvironmentOverrideWins() {
        let env = [ZaiSettingsReader.quotaURLKey: "https://open.bigmodel.cn/api/coding/paas/v4"]
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .global, environment: env)
        #expect(url.absoluteString == "https://open.bigmodel.cn/api/coding/paas/v4")
    }

    @Test
    func apiHostEnvironmentAppendsQuotaPath() {
        let env = [ZaiSettingsReader.apiHostKey: "open.bigmodel.cn"]
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .global, environment: env)
        #expect(url.absoluteString == "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
    }
}
