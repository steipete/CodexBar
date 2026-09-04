import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct ZaiPluginResetTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test(arguments: ["TOKENS_LIMIT", "CREDIT_LIMIT"])
    func `five hour windows omit impossible resets and preserve quota`(type: String) async throws {
        for offset in [TimeInterval(36000), 18060.001] {
            let snapshot = try await Self.fetch(type: type, resetOffset: offset)
            #expect(snapshot.primary?.resetsAt == nil)
            #expect(snapshot.primary?.usedPercent == 25)
            #expect(snapshot.primary?.windowMinutes == 300)
            #expect(snapshot.primary?.resetDescription == "5-hour")
            #expect(snapshot.secondary?.resetsAt == Self.now.addingTimeInterval(6 * 86400))
            #expect(snapshot.extraRateWindows?.first?.window.resetsAt == Self.now.addingTimeInterval(20 * 86400))
        }
    }

    @Test(arguments: [TimeInterval(-60), 0, 3600, 18000, 18060])
    func `valid five hour resets retain their exact timestamp`(offset: TimeInterval) async throws {
        let snapshot = try await Self.fetch(type: "TOKENS_LIMIT", resetOffset: offset)
        #expect(snapshot.primary?.resetsAt == Self.now.addingTimeInterval(offset))
    }

    @Test(arguments: [TimeInterval(3600), 18060, 18061, 36000])
    func `refresh cannot restore an impossible cached five hour reset`(offset: TimeInterval) async throws {
        let snapshot = try await Self.fetch(type: "CREDIT_LIMIT", resetOffset: 36000)
        let cached = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: Self.now.addingTimeInterval(offset),
                resetDescription: "5-hour"),
            secondary: nil,
            updatedAt: Self.now.addingTimeInterval(-60),
            identity: snapshot.identity)

        let published = snapshot.backfillingResetTimes(from: cached, now: Self.now)
        #expect(published.primary?.resetsAt == (offset <= 18060 ? Self.now.addingTimeInterval(offset) : nil))
        #expect(published.primary?.usedPercent == 25)
    }

    @Test
    func `five hour backfill rejects unrelated window evidence in every quota slot`() {
        let identity = Self.identity(.zai)
        let current = RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: "5-hour")
        let snapshot = UsageSnapshot(
            primary: current, secondary: current, tertiary: current, updatedAt: Self.now, identity: identity)
        let reset = Self.now.addingTimeInterval(3600)
        for (duration, label, provider) in [
            (Optional(10080), "1 week window", UsageProvider.zai),
            (nil, "5-hour", .zai),
            (300, "MCP", .zai),
            (300, "5-hour", .claude),
        ] {
            let candidate = RateWindow(
                usedPercent: 10, windowMinutes: duration, resetsAt: reset, resetDescription: label)
            let cached = UsageSnapshot(
                primary: candidate, secondary: candidate, tertiary: candidate,
                updatedAt: Self.now, identity: Self.identity(provider))
            let published = snapshot.backfillingResetTimes(from: cached, now: Self.now)
            #expect(published.primary?.resetsAt == nil)
            #expect(published.secondary?.resetsAt == nil)
            #expect(published.tertiary?.resetsAt == nil)
        }
    }

    @Test
    func `five hour mitigation preserves MCP and other provider backfill`() {
        let reset = Self.now.addingTimeInterval(36000)
        for (provider, label) in [(UsageProvider.zai, "MCP"), (.claude, "5-hour")] {
            let identity = Self.identity(provider)
            let snapshot = UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: label),
                secondary: nil, updatedAt: Self.now, identity: identity)
            let cached = UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: reset, resetDescription: label),
                secondary: nil, updatedAt: Self.now, identity: identity)
            #expect(snapshot.backfillingResetTimes(from: cached, now: Self.now).primary?.resetsAt == reset)
        }
    }

    private static func identity(_ provider: UsageProvider) -> ProviderIdentitySnapshot {
        ProviderIdentitySnapshot(
            providerID: provider.instanceID, accountEmail: nil, accountOrganization: nil, loginMethod: nil)
    }

    private static func fetch(type: String, resetOffset: TimeInterval) async throws -> UsageSnapshot {
        let resetMillis = Int64(Self.now.addingTimeInterval(resetOffset).timeIntervalSince1970 * 1000)
        let weeklyMillis = Int64(Self.now.addingTimeInterval(6 * 86400).timeIntervalSince1970 * 1000)
        let mcpMillis = Int64(Self.now.addingTimeInterval(20 * 86400).timeIntervalSince1970 * 1000)
        let body = """
        {"code":200,"success":true,"data":{"limits":[
          {"type":"\(type)","unit":3,"number":5,"percentage":25,"nextResetTime":\(resetMillis)},
          {"type":"\(type)","unit":6,"number":1,"percentage":9,"nextResetTime":\(weeklyMillis)},
          {"type":"TIME_LIMIT","unit":5,"number":1,"percentage":22,"nextResetTime":\(mcpMillis)}
        ]}}
        """
        let runtime = try ProviderPluginRuntime(
            bundledPlugin: "zai",
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                let isQuota = url.path.hasSuffix("/quota/limit")
                let response = try #require(HTTPURLResponse(
                    url: url,
                    statusCode: isQuota ? 200 : 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                return (Data((isQuota ? body : "{}").utf8), response)
            })
        return try await runtime.fetchUsage(
            settings: ["Z_AI_REGION": "global", "Z_AI_USAGE_SCOPE": "personal"],
            secrets: ["Z_AI_API_KEY": "fixture-key"],
            now: Self.now)
    }
}
