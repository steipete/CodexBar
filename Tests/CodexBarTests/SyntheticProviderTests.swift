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

struct SyntheticUsageSnapshotTests {
    @Test
    func `maps usage snapshot windows`() throws {
        let json = """
        {
          "plan": "Starter",
          "quotas": [
            { "name": "Monthly", "limit": 1000, "used": 250, "reset_at": "2025-01-01T00:00:00Z" },
            { "name": "Daily", "max": 200, "remaining": 50, "window_minutes": 1440 }
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let snapshot = try SyntheticUsageParser.parse(data: data, now: Date(timeIntervalSince1970: 123))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.secondary?.usedPercent == 75)
        #expect(usage.secondary?.windowMinutes == 1440)
        #expect(usage.loginMethod(for: .synthetic) == "Starter")
    }

    @Test
    func `parses subscription quota`() throws {
        let json = """
        {
          "subscription": {
            "limit": 1350,
            "requests": 73.8,
            "renewsAt": "2026-01-11T11:23:38.600Z"
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let snapshot = try SyntheticUsageParser.parse(data: data, now: Date(timeIntervalSince1970: 123))
        let usage = snapshot.toUsageSnapshot()
        let expected = (73.8 / 1350.0) * 100
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedReset = try #require(formatter.date(from: "2026-01-11T11:23:38.600Z"))

        #expect(abs((usage.primary?.usedPercent ?? 0) - expected) < 0.01)
        #expect(usage.primary?.resetsAt == expectedReset)
        #expect(usage.loginMethod(for: .synthetic) == nil)
    }

    @Test
    func `parses nested subscription pack quota`() throws {
        let json = """
        {
          "subscription": {
            "packs": 2,
            "rateLimit": {
              "messages": 1000,
              "requests": 250,
              "period": "5hr",
              "resetsAt": "2026-04-16T18:00:00Z"
            }
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let snapshot = try SyntheticUsageParser.parse(data: data, now: Date(timeIntervalSince1970: 123))
        let usage = snapshot.toUsageSnapshot()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let expectedReset = try #require(formatter.date(from: "2026-04-16T18:00:00Z"))

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == expectedReset)
    }

    @Test
    func `parses live root level rolling and weekly quotas`() throws {
        let json = """
        {
          "subscription": {
            "limit": 750,
            "requests": 0,
            "renewsAt": "2026-04-17T08:35:49.493Z"
          },
          "weeklyTokenLimit": {
            "nextRegenAt": "2026-04-17T05:19:30.000Z",
            "percentRemaining": 98.05884722222223,
            "maxCredits": "$36.00",
            "remainingCredits": "$35.30",
            "nextRegenCredits": "$0.72"
          },
          "rollingFiveHourLimit": {
            "nextTickAt": "2026-04-17T03:44:11.000Z",
            "tickPercent": 0.05,
            "remaining": 750,
            "max": 750,
            "limited": false
          },
          "search": {
            "hourly": {
              "limit": 250,
              "requests": 2,
              "renewsAt": "2026-04-17T04:30:01.494Z"
            }
          }
        }
        """
        let data = try #require(json.data(using: .utf8))
        let snapshot = try SyntheticUsageParser.parse(data: data, now: Date(timeIntervalSince1970: 123))
        let usage = snapshot.toUsageSnapshot()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedPrimaryReset = try #require(formatter.date(from: "2026-04-17T03:44:11Z"))
        let expectedSecondaryReset = try #require(formatter.date(from: "2026-04-17T05:19:30Z"))
        let expectedTertiaryReset = try #require(fractionalFormatter.date(from: "2026-04-17T04:30:01.494Z"))

        #expect(usage.primary?.usedPercent == 0)
        #expect(usage.primary?.resetsAt == expectedPrimaryReset)
        #expect(usage.primary?.resetDescription == nil)
        #expect(abs((usage.secondary?.usedPercent ?? 0) - 1.9411527777777715) < 0.001)
        #expect(usage.secondary?.resetsAt == expectedSecondaryReset)
        #expect(usage.secondary?.resetDescription == nil)
        #expect(usage.tertiary?.usedPercent == 0.8)
        #expect(usage.tertiary?.resetsAt == expectedTertiaryReset)
        #expect(usage.providerCost?.limit == 36)
        #expect(abs((usage.providerCost?.used ?? 0) - 0.7) < 0.0001)
        #expect(usage.providerCost?.nextRegenAmount == 0.72)
    }

    @Test
    func `preserves slot identity when rolling lane is missing`() throws {
        let json = """
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
        """
        let data = try #require(json.data(using: .utf8))
        let snapshot = try SyntheticUsageParser.parse(data: data, now: Date(timeIntervalSince1970: 123))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(abs((usage.secondary?.usedPercent ?? 0) - 2.0) < 0.001)
        #expect(usage.tertiary?.usedPercent == 0.8)
        #expect(usage.providerCost?.limit == 36)
    }
}
