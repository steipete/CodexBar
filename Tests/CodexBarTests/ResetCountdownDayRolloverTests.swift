import Foundation
import Testing
@testable import CodexBarCore

struct ResetCountdownDayRolloverTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(hoursFromNow hours: Double) -> Date {
        Self.now.addingTimeInterval(hours * 3600)
    }

    @Test
    func `Windsurf web reset at exactly 24h rolls over to a day`() {
        // Was "Resets in 24h 0m"; the day form must be reachable at the 24h boundary.
        #expect(
            UsageFormatter.compactResetDescription(self.at(hoursFromNow: 24), now: Self.now)
                == "Resets in 1d 0h")
    }

    @Test
    func `Windsurf web reset above 24h shows day and hour`() {
        #expect(
            UsageFormatter.compactResetDescription(self.at(hoursFromNow: 25), now: Self.now)
                == "Resets in 1d 1h")
    }

    @Test
    func `Windsurf web reset below 24h stays in hours`() {
        #expect(
            UsageFormatter.compactResetDescription(self.at(hoursFromNow: 23), now: Self.now)
                == "Resets in 23h 0m")
    }

    @Test
    func `Windsurf cached reset at exactly 24h rolls over to a day`() {
        #expect(
            UsageFormatter.compactResetDescription(self.at(hoursFromNow: 24), now: Self.now)
                == "Resets in 1d 0h")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Zed cycle at exactly 24h rolls over to a day`(engine: ProviderPluginEngineKind) async throws {
        // Was "Cycle ends in 24h 0m".
        let runtime = try BundledPluginTestSupport.runtime(
            "zed",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let data = ZedStatusProbeTests.fixture(
                    plan: "zed_pro",
                    used: 0,
                    limit: "\"unlimited\"")
                let body = try #require(String(data: data, encoding: .utf8))
                return try ZedPluginTests.response(request, body: body)
            })
        let now = try #require(ISO8601DateParser.parse("2026-06-12T00:00:00Z"))
        let snapshot = try await runtime.fetchUsage(
            settings: ["API_URL": ZedStatusProbe.cloudAPIURL.absoluteString],
            secrets: ["EDITOR_AUTH": "4242 fixture-token"],
            now: now,
            sourceMode: .api)
        #expect(snapshot.secondary?.resetDescription == "Cycle ends in 1d 0h")
    }

    @Test
    func `JetBrains reset at exactly 24h rolls over to a day`() {
        #expect(
            UsageFormatter.compactResetDescription(self.at(hoursFromNow: 24), now: Self.now)
                == "Resets in 1d 0h")
    }
}
