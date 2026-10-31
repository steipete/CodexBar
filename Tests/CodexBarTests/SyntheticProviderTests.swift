import Foundation
import Testing
@testable import CodexBarCore

struct SyntheticSettingsReaderTests {
    @Test
    func `api key reads from environment`() {
        let token = SyntheticSettingsReader.apiKey(environment: ["SYNTHETIC_API_KEY": "abc123"])
        #expect(token == "abc123")
    }

    @Test
    func `api key strips quotes`() {
        let token = SyntheticSettingsReader.apiKey(environment: ["SYNTHETIC_API_KEY": "\"token-xyz\""])
        #expect(token == "token-xyz")
    }
}

struct SyntheticPluginGoldenTests {
    @Test(arguments: [false, true])
    func `plan weekly quota ignores retired subscription and preserves search`(wrapped: Bool) async throws {
        let body = """
        {
          "subscription": { "limit": 500, "requests": 0, "renewsAt": "2026-10-31T15:15:05.743Z" },
          "search": {
            "hourly": { "limit": 250, "requests": 0, "renewsAt": "2026-10-31T11:15:05.743Z" }
          },
          "planWeeklyLimit": {
            "nextRegenAt": "2026-10-31T12:14:13.000Z",
            "percentRemaining": 99.47981765714286,
            "nextRegenPercent": 2
          }
        }
        """
        let snapshot = try await Self.fetch(wrapped ? "{\"data\":\(body)}" : body)

        #expect(snapshot.primary == nil)
        let weekly = try #require(snapshot.secondary)
        #expect(abs(weekly.usedPercent - 0.52018234285714) < 0.000001)
        #expect(weekly.resetsAt == ISO8601DateFormatter().date(from: "2026-10-31T12:14:13Z"))
        #expect(weekly.nextRegenPercent == 2)
        #expect(snapshot.tertiary?.usedPercent == 0)
        #expect(snapshot.providerCost == nil)
    }

    @Test(arguments: [0.0, 0.5, 1.0, 100.0])
    func `plan weekly percentages use percentage points even near exhaustion`(remaining: Double) async throws {
        let snapshot = try await Self.fetch("""
        {
          "planWeeklyLimit": {
            "percentRemaining": \(remaining),
            "nextRegenPercent": 0.5
          }
        }
        """)

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 100 - remaining)
        #expect(snapshot.secondary?.nextRegenPercent == 0.5)
        #expect(snapshot.tertiary == nil)
    }

    @Test
    func `legacy rolling and weekly quotas retain fractional percentages`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "rollingFiveHourLimit": { "percentRemaining": 0.75, "tickPercent": 0.02 },
          "weeklyTokenLimit": { "percentRemaining": 0.98 },
          "search": { "hourly": { "limit": 250, "requests": 5 } }
        }
        """)

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.nextRegenPercent == 2)
        #expect(snapshot.secondary?.usedPercent == 2)
        #expect(snapshot.tertiary?.usedPercent == 2)
    }

    @Test
    func `generic quota fixture matches the production golden`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "plan": "Starter",
          "quotas": [
            { "name": "Monthly", "limit": 1000, "used": 250, "reset_at": "2025-01-01T00:00:00Z" },
            { "name": "Daily", "max": 200, "remaining": 50, "window_minutes": 1440 }
          ]
        }
        """)

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_735_689_600))
        #expect(snapshot.secondary?.usedPercent == 75)
        #expect(snapshot.secondary?.windowMinutes == 1440)
        #expect(snapshot.identity?.loginMethod == "Starter")
    }

    @Test
    func `missing rolling lane keeps weekly and search slots`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "weeklyTokenLimit": {
            "nextRegenAt": "2026-04-17T05:19:30.000Z",
            "percentRemaining": 98.0,
            "maxCredits": "$36.00",
            "remainingCredits": "$35.30",
            "nextRegenCredits": "$0.72"
          },
          "search": {
            "hourly": {
              "limit": 250,
              "requests": 2,
              "renewsAt": "2026-04-17T04:30:01.494Z"
            }
          }
        }
        """)

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.usedPercent == 2)
        #expect(snapshot.tertiary?.usedPercent == 0.8)
        #expect(snapshot.providerCost?.limit == 36)
        #expect(snapshot.providerCost?.used == 0.7000000000000028)
    }

    private static func fetch(_ body: String) async throws -> UsageSnapshot {
        let transport = ProviderHTTPTransportHandler { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
        return try await ProviderPluginRuntime(bundledPlugin: "synthetic", transport: transport)
            .fetchUsage(secrets: ["SYNTHETIC_API_KEY": "fixture-key"])
    }
}
