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

    @Test
    func `plan weekly limit keeps credits and drops the legacy request counter`() async throws {
        let snapshot = try await Self.fetch("""
        {
          "subscription": { "limit": 500, "requests": 0, "renewsAt": "2026-11-01T09:33:15.773Z" },
          "search": {
            "hourly": { "limit": 250, "requests": 3, "renewsAt": "2026-11-01T05:32:57.774Z" }
          },
          "planWeeklyLimit": {
            "nextRegenAt": "2026-11-01T07:41:28.000Z",
            "percentRemaining": 99.60392845714286,
            "nextRegenPercent": 2
          }
        }
        """)

        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost == nil)
        #expect(snapshot.secondary?.nextRegenPercent == 2)
        #expect(abs((snapshot.secondary?.usedPercent ?? -1) - (100 - 99.60392845714286)) < 0.000_000_1)
        #expect(abs((snapshot.tertiary?.usedPercent ?? -1) - 1.2) < 0.000_000_1)
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
