import CodexBarCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct LLMProxyResetPluginTests {
    // 2023-11-14T22:13:20Z — the snapshot time treated as "now".
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func nextReset(resetTimes: [String]) async throws -> Date? {
        let groups = resetTimes
            .map { "{ \"remaining_percent\": 50, \"reset_time\": \"\($0)\" }" }
            .joined(separator: ", ")
        let json = "{ \"providers\": { \"p\": { \"quota_groups\": [ \(groups) ] } } }"
        let transport = ProviderHTTPTransportHandler { request in
            (Data(json.utf8), HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!)
        }
        return try await ProviderPluginRuntime(bundledPlugin: "llmproxy", transport: transport)
            .fetchUsage(
                settings: ["LLM_PROXY_BASE_URL": "https://proxy.example.com"],
                secrets: ["LLM_PROXY_API_KEY": "fixture-key"],
                now: Self.now)
            .primary?.resetsAt
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) throws -> Date {
        try #require(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year, month: month, day: day, hour: 0, minute: 0, second: 0).date)
    }

    @Test
    func `next reset skips already-elapsed reset times`() async throws {
        // A past reset (stale until the API refreshes) must not be chosen over the soonest upcoming one.
        let reset = try await self.nextReset(resetTimes: [
            "2023-11-01T00:00:00Z", // past (before now)
            "2023-11-20T00:00:00Z", // soonest future
            "2023-12-25T00:00:00Z", // later future
        ])
        #expect(try abs(#require(reset).timeIntervalSince(self.date(2023, 11, 20))) < 0.001)
    }

    @Test
    func `all-past reset times yield no next reset`() async throws {
        let reset = try await self.nextReset(resetTimes: [
            "2023-11-01T00:00:00Z",
            "2023-10-15T00:00:00Z",
        ])
        #expect(reset == nil)
    }

    @Test
    func `future reset time is preserved`() async throws {
        let reset = try await self.nextReset(resetTimes: ["2023-11-20T00:00:00Z"])
        #expect(try abs(#require(reset).timeIntervalSince(self.date(2023, 11, 20))) < 0.001)
    }
}
