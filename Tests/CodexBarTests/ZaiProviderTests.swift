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
