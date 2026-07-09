import CodexBarCore
import Foundation
import Testing

struct CodexCustomUsageMapperTests {
    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static func date(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test
    func `daily only response maps credits and omits weekly window`() throws {
        let json = """
        {
          "remaining": 104.52,
          "unit": "USD",
          "is_valid": true,
          "plan_name": "Pro Daily",
          "subscription": {
            "daily_limit_usd": 200,
            "daily_usage_usd": 95.48,
            "weekly_limit_usd": 0,
            "weekly_usage_usd": 0,
            "expires_at": "2026-07-09T00:00:00Z"
          }
        }
        """

        let snapshot = try CodexCustomUsageMapper.map(
            data: Data(json.utf8),
            updatedAt: self.updatedAt)

        #expect(snapshot.credits.remaining == 104.52)
        let limit = try #require(snapshot.credits.codexCreditLimit)
        #expect(limit.title == "Daily limit")
        #expect(limit.used == 95.48)
        #expect(limit.limit == 200)
        #expect(limit.remaining == 104.52)
        // 95.48 / 200 = 47.74% used → 52.26% remaining
        #expect(abs(limit.remainingPercent - 52.26) < 0.01)
        #expect(limit.resetsAt == Self.date(year: 2026, month: 7, day: 9))

        #expect(snapshot.usage.primary == nil)
        #expect(snapshot.usage.secondary == nil)
        #expect(snapshot.usage.extraRateWindows == nil)
        #expect(snapshot.usage.identity?.providerID == .codex)
        #expect(snapshot.usage.identity?.accountOrganization == "Pro Daily")
    }

    @Test
    func `daily and weekly response produces a weekly window with proportional usage`() throws {
        let json = """
        {
          "remaining": 50,
          "unit": "USD",
          "is_valid": true,
          "subscription": {
            "daily_limit_usd": 100,
            "daily_usage_usd": 50,
            "weekly_limit_usd": 500,
            "weekly_usage_usd": 125,
            "expires_at": "2026-07-09T00:00:00Z"
          }
        }
        """

        let snapshot = try CodexCustomUsageMapper.map(
            data: Data(json.utf8),
            updatedAt: self.updatedAt)

        let weekly = try #require(snapshot.usage.extraRateWindows?.first)
        #expect(weekly.id == CodexCustomUsageMapper.weeklyWindowID)
        #expect(weekly.title == CodexCustomUsageMapper.weeklyWindowTitle)
        #expect(weekly.window.windowMinutes == 10080)
        // 125 / 500 = 25% used
        #expect(abs(weekly.window.usedPercent - 25) < 0.001)
        // No primary/secondary window — the menu bar stays on the balance.
        #expect(snapshot.usage.primary == nil)
        #expect(snapshot.usage.secondary == nil)
    }

    @Test
    func `weekly limit zero produces no weekly window`() throws {
        let json = """
        {
          "remaining": 50,
          "unit": "USD",
          "is_valid": true,
          "subscription": {
            "daily_limit_usd": 100,
            "daily_usage_usd": 50,
            "weekly_limit_usd": 0,
            "weekly_usage_usd": 0
          }
        }
        """

        let snapshot = try CodexCustomUsageMapper.map(
            data: Data(json.utf8),
            updatedAt: self.updatedAt)

        #expect(snapshot.usage.extraRateWindows == nil)
    }

    @Test
    func `weekly limit absent produces no weekly window`() throws {
        let json = """
        {
          "remaining": 50,
          "is_valid": true,
          "subscription": {
            "daily_limit_usd": 100,
            "daily_usage_usd": 50
          }
        }
        """

        let snapshot = try CodexCustomUsageMapper.map(
            data: Data(json.utf8),
            updatedAt: self.updatedAt)

        #expect(snapshot.usage.extraRateWindows == nil)
    }

    @Test
    func `remaining zero preserves exhausted state`() throws {
        let json = """
        {
          "remaining": 0,
          "is_valid": true,
          "subscription": {
            "daily_limit_usd": 100,
            "daily_usage_usd": 100
          }
        }
        """

        let snapshot = try CodexCustomUsageMapper.map(
            data: Data(json.utf8),
            updatedAt: self.updatedAt)

        #expect(snapshot.credits.remaining == 0)
        let limit = try #require(snapshot.credits.codexCreditLimit)
        #expect(limit.remaining == 0)
        #expect(limit.remainingPercent == 0)
    }

    @Test
    func `is valid false throws instead of returning a partial snapshot`() {
        let json = """
        {
          "remaining": 50,
          "is_valid": false,
          "subscription": {
            "daily_limit_usd": 100,
            "daily_usage_usd": 50
          }
        }
        """

        #expect(throws: CodexCustomUsageError.self) {
            try CodexCustomUsageMapper.map(data: Data(json.utf8), updatedAt: self.updatedAt)
        }
    }

    @Test
    func `camelCase top level keys are also accepted`() throws {
        // The PRD records top-level keys as camelCase (`isValid`, `planName`).
        let json = """
        {
          "remaining": 10,
          "unit": "USD",
          "isValid": true,
          "planName": "Starter",
          "subscription": {
            "daily_limit_usd": 20,
            "daily_usage_usd": 10
          }
        }
        """

        let snapshot = try CodexCustomUsageMapper.map(
            data: Data(json.utf8),
            updatedAt: self.updatedAt)

        #expect(snapshot.credits.remaining == 10)
        #expect(snapshot.usage.identity?.accountOrganization == "Starter")
    }

    @Test
    func `plan name is scoped to codex identity`() throws {
        let json = """
        {
          "remaining": 10,
          "is_valid": true,
          "plan_name": "Team Plan",
          "subscription": {
            "daily_limit_usd": 20,
            "daily_usage_usd": 10
          }
        }
        """

        let snapshot = try CodexCustomUsageMapper.map(
            data: Data(json.utf8),
            updatedAt: self.updatedAt)

        // Plan name surfaces as the Codex provider's organization label only.
        #expect(snapshot.usage.identity?.providerID == .codex)
        #expect(snapshot.usage.identity?.accountOrganization == "Team Plan")
    }

    @Test
    func `no daily limit omits codex credit limit but keeps remaining`() throws {
        let json = """
        {
          "remaining": 42,
          "is_valid": true,
          "subscription": {
            "weekly_limit_usd": 500,
            "weekly_usage_usd": 100
          }
        }
        """

        let snapshot = try CodexCustomUsageMapper.map(
            data: Data(json.utf8),
            updatedAt: self.updatedAt)

        #expect(snapshot.credits.remaining == 42)
        #expect(snapshot.credits.codexCreditLimit == nil)
        // Weekly window still renders from its own limit.
        #expect(snapshot.usage.extraRateWindows?.count == 1)
    }

    @Test
    func `invalid JSON throws parse failed`() {
        #expect(throws: CodexCustomUsageError.self) {
            try CodexCustomUsageMapper.map(data: Data("not json".utf8), updatedAt: self.updatedAt)
        }
    }
}
