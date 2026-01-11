import Foundation
import Testing
@testable import CodexBarCore

@Suite
struct SyntheticSettingsReaderTests {
    @Test
    func apiKeyReadsFromEnvironment() {
        let token = SyntheticSettingsReader.apiKey(environment: ["SYNTHETIC_API_KEY": "abc123"])
        #expect(token == "abc123")
    }

    @Test
    func apiKeyStripsQuotes() {
        let token = SyntheticSettingsReader.apiKey(environment: ["SYNTHETIC_API_KEY": "\"token-xyz\""])
        #expect(token == "token-xyz")
    }
}

@Suite
struct SyntheticUsageSnapshotTests {
    @Test
    func mapsUsageSnapshotWindows() throws {
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
    func parsesSubscriptionQuota() throws {
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
}
