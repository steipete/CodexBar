import Foundation
import Testing
@testable import CodexBarCore

struct ZaiSettingsReaderTests {
    @Test
    func `api token reads from environment`() {
        let token = ZaiSettingsReader.apiToken(environment: ["Z_AI_API_KEY": "abc123"])
        #expect(token == "abc123")
    }

    @Test
    func `api token strips quotes`() {
        let token = ZaiSettingsReader.apiToken(environment: ["Z_AI_API_KEY": "\"token-xyz\""])
        #expect(token == "token-xyz")
    }

    @Test
    func `api host reads from environment`() {
        let host = ZaiSettingsReader.apiHost(environment: [ZaiSettingsReader.apiHostKey: " open.bigmodel.cn "])
        #expect(host == "open.bigmodel.cn")
    }

    @Test
    func `quota URL infers scheme`() {
        let url = ZaiSettingsReader
            .quotaURL(environment: [ZaiSettingsReader.quotaURLKey: "open.bigmodel.cn/api/coding"])
        #expect(url?.absoluteString == "https://open.bigmodel.cn/api/coding")
    }
}

struct ZaiUsageSnapshotTests {
    @Test
    func `maps usage snapshot windows`() {
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
        #expect(usage.tertiary == nil)
        #expect(usage.zaiUsage?.tokenLimit?.usage == 100)
        #expect(usage.zaiUsage?.sessionTokenLimit == nil)
    }

    @Test
    func `maps usage snapshot windows with missing fields`() {
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
    func `maps usage snapshot windows with missing remaining uses current value`() {
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
    func `maps usage snapshot windows with missing current value uses remaining`() {
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
    func `maps usage snapshot windows with missing remaining and current value falls back to percentage`() {
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

struct ZaiUsageParsingTests {
    @Test
    func `empty body returns parse failed`() {
        #expect {
            _ = try ZaiUsageFetcher.parseUsageSnapshot(from: Data())
        } throws: { error in
            guard case let ZaiUsageError.parseFailed(message) = error else { return false }
            return message == "Empty response body"
        }
    }

    @Test
    func `parses usage response`() throws {
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
    func `missing data returns api error`() {
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
    func `success without data returns parse failed`() {
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
    func `success without limits parses empty usage`() throws {
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
    func `parses new schema with missing token limit fields`() throws {
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

struct ZaiThreeLimitTests {
    @Test
    func `parses three limit entries into session weekly and mcp slots`() throws {
        let json = """
        {
          "code": 200,
          "msg": "操作成功",
          "data": {
            "limits": [
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 25,
                "nextResetTime": 1775020168897
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "number": 1,
                "percentage": 9,
                "nextResetTime": 1775588029998
              },
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "usage": 1000,
                "currentValue": 224,
                "remaining": 776,
                "percentage": 22,
                "nextResetTime": 1777575229998,
                "usageDetails": [
                  { "modelCode": "search-prime", "usage": 210 },
                  { "modelCode": "web-reader", "usage": 14 }
                ]
              }
            ],
            "level": "pro"
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        // Weekly token limit (unit:6=weeks, longer window) → tokenLimit (primary)
        #expect(snapshot.tokenLimit?.unit == .weeks)
        #expect(snapshot.tokenLimit?.number == 1)
        #expect(snapshot.tokenLimit?.percentage == 9.0)
        #expect(snapshot.tokenLimit?.windowMinutes == 10080)

        // 5-hour token limit (unit:3=hours, number:5 → 300 min) → sessionTokenLimit (tertiary)
        #expect(snapshot.sessionTokenLimit?.unit == .hours)
        #expect(snapshot.sessionTokenLimit?.number == 5)
        #expect(snapshot.sessionTokenLimit?.percentage == 25.0)
        #expect(snapshot.sessionTokenLimit?.windowMinutes == 300)

        // MCP time limit → timeLimit (secondary)
        #expect(snapshot.timeLimit?.usage == 1000)
        #expect(snapshot.timeLimit?.usageDetails.first?.modelCode == "search-prime")

        // UsageSnapshot slot mapping
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 9.0)
        #expect(usage.primary?.windowMinutes == 10080)
        #expect(usage.secondary != nil)    // MCP
        #expect(usage.tertiary?.usedPercent == 25.0)
        #expect(usage.tertiary?.windowMinutes == 300)
    }

    @Test
    func `unit 6 maps to weeks with correct window minutes`() {
        let entry = ZaiLimitEntry(
            type: .tokensLimit,
            unit: .weeks,
            number: 1,
            usage: nil,
            currentValue: nil,
            remaining: nil,
            percentage: 9,
            usageDetails: [],
            nextResetTime: nil)
        #expect(entry.windowMinutes == 10080)
        #expect(entry.windowDescription == "1 week")
        #expect(entry.windowLabel == "1 week window")
    }

    @Test
    func `two limit entries remain backward compatible`() throws {
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
                "currentValue": 50,
                "remaining": 50,
                "percentage": 50,
                "usageDetails": []
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "percentage": 34,
                "nextResetTime": 1768507567547
              }
            ]
          },
          "success": true
        }
        """

        let snapshot = try ZaiUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.tokenLimit != nil)
        #expect(snapshot.sessionTokenLimit == nil)
        #expect(snapshot.timeLimit != nil)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary != nil)
        #expect(usage.secondary != nil)
        #expect(usage.tertiary == nil)
    }
}

struct ZaiAPIRegionTests {
    @Test
    func `defaults to global endpoint`() {
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .global, environment: [:])
        #expect(url.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
    }

    @Test
    func `uses big model region when selected`() {
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .bigmodelCN, environment: [:])
        #expect(url.absoluteString == "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
    }

    @Test
    func `quota url environment override wins`() {
        let env = [ZaiSettingsReader.quotaURLKey: "https://open.bigmodel.cn/api/coding/paas/v4"]
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .global, environment: env)
        #expect(url.absoluteString == "https://open.bigmodel.cn/api/coding/paas/v4")
    }

    @Test
    func `api host environment appends quota path`() {
        let env = [ZaiSettingsReader.apiHostKey: "open.bigmodel.cn"]
        let url = ZaiUsageFetcher.resolveQuotaURL(region: .global, environment: env)
        #expect(url.absoluteString == "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
    }
}
