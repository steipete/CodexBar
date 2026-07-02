import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct LiteLLMMenuCardModelTests {
    @Test
    func `litellm budget rows show spend detail with reset time`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let metadata = try #require(ProviderDefaults.metadata[.litellm])
        let json = """
        {
          "user_id": "user-123",
          "user_info": {
            "user_id": "user-123",
            "max_budget": 900.0,
            "spend": 403.99,
            "budget_reset_at": "1970-01-07T00:00:00Z"
          },
          "teams": [
            {
              "team_alias": "Platform",
              "team_id": "team-123",
              "max_budget": 1000.0,
              "spend": 70.0,
              "budget_duration": "30d",
              "budget_reset_at": "1970-01-07T00:00:00Z"
            }
          ]
        }
        """
        let snapshot = try LiteLLMUsageFetcher._parseUserInfoForTesting(
            Data(json.utf8),
            keyInfo: LiteLLMKeyInfoSnapshot(
                userID: "user-123",
                teamID: "team-123",
                keyName: nil,
                spendUSD: 403.99,
                expiresAt: nil),
            updatedAt: now)
            .toUsageSnapshot()

        let model = UsageMenuCardView.Model.make(.init(
            provider: .litellm,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let personal = try #require(model.metrics.first { $0.id == "primary" })
        #expect(personal.title == "Personal budget")
        #expect(personal.percentLabel == "55% left")
        #expect(personal.resetText?.hasPrefix("Resets") == true)
        #expect(personal.detailText == "$403.99 / $900.00")

        let team = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(team.title == "Team budget")
        #expect(team.percentLabel == "93% left")
        #expect(team.resetText?.hasPrefix("Resets") == true)
        #expect(team.detailText == "Team Platform: $70.00 / $1,000.00")

        #expect(model.providerCost == nil)
    }

    @Test
    func `litellm budget row details redact team aliases when hiding personal info`() throws {
        let teamAlias = "Private Workspace"
        let model = try self.redactedTeamAliasModel(teamAlias)

        let team = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(team.detailText == "Team: $70.00 / $1,000.00")
        #expect(team.detailText?.contains(teamAlias) == false)
    }

    @Test
    func `litellm budget row details redact email team aliases when hiding personal info`() throws {
        let teamAlias = "workspace@example.com"
        let model = try self.redactedTeamAliasModel(teamAlias)

        let team = try #require(model.metrics.first { $0.id == "secondary" })
        #expect(team.detailText == "Team: $70.00 / $1,000.00")
        #expect(team.detailText?.contains(teamAlias) == false)
        #expect(team.detailText?.contains("Hidden") == false)
    }

    @Test
    func `litellm team-only budget stays on the team row`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let metadata = try #require(ProviderDefaults.metadata[.litellm])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: RateWindow(
                usedPercent: 25,
                windowMinutes: nil,
                resetsAt: now.addingTimeInterval(7 * 24 * 60 * 60),
                resetDescription: "Team Platform: $250.00 / $1,000.00"),
            providerCost: ProviderCostSnapshot(
                used: 250,
                limit: 1000,
                currencyCode: "USD",
                period: "Team budget",
                updatedAt: now),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .litellm,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.metrics.map(\.id) == ["secondary"])
        #expect(model.metrics.first?.detailText == "Team Platform: $250.00 / $1,000.00")
        #expect(model.providerCost == nil)
    }

    @Test
    func `litellm spend without budget remains visible`() throws {
        let now = Date()
        let metadata = try #require(ProviderDefaults.metadata[.litellm])
        let snapshot = UsageSnapshot(
            primary: nil,
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 12.5,
                limit: 0,
                currencyCode: "USD",
                period: "Personal spend",
                updatedAt: now),
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .litellm,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.providerCost?.title == "API spend")
        #expect(model.providerCost?.spendLine == "Personal spend: $12.50")
        #expect(model.providerCost?.percentUsed == nil)
    }

    private func redactedTeamAliasModel(_ teamAlias: String) throws -> UsageMenuCardView.Model {
        let now = Date(timeIntervalSince1970: 0)
        let metadata = try #require(ProviderDefaults.metadata[.litellm])
        let json = """
        {
          "user_id": "user-123",
          "user_info": {
            "user_id": "user-123",
            "max_budget": 900.0,
            "spend": 403.99
          },
          "teams": [
            {
              "team_alias": "\(teamAlias)",
              "team_id": "team-123",
              "max_budget": 1000.0,
              "spend": 70.0
            }
          ]
        }
        """
        let snapshot = try LiteLLMUsageFetcher._parseUserInfoForTesting(
            Data(json.utf8),
            keyInfo: LiteLLMKeyInfoSnapshot(
                userID: "user-123",
                teamID: "team-123",
                keyName: nil,
                spendUSD: 403.99,
                expiresAt: nil),
            updatedAt: now)
            .toUsageSnapshot()

        return UsageMenuCardView.Model.make(.init(
            provider: .litellm,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            now: now))
    }
}
