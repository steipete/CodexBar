import Foundation
import Testing
@testable import CodexBarCore

struct ClaudeAdminAPIUsageTests {
    private func makeContext(
        apiKey: String = "sk-ant-admin-test",
        sourceMode: ProviderSourceMode = .api) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let env = [ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: apiKey]
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func `prefers primary Anthropic admin key environment variable`() {
        let token = ClaudeAdminAPISettingsReader.apiKey(environment: [
            ClaudeAdminAPISettingsReader.alternateAdminAPIKeyEnvironmentKey: "sk-ant-admin-alt",
            ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: "sk-ant-admin-primary",
        ])

        #expect(token == "sk-ant-admin-primary")
    }

    @Test
    func `routes Claude token account admin keys into admin api environment`() {
        let env = TokenAccountSupportCatalog.envOverride(for: .claude, token: "Bearer sk-ant-admin-token")

        #expect(env?[ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey] == "sk-ant-admin-token")
    }

    @Test
    func `auto source uses configured admin api key`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let context = self.makeContext(sourceMode: .auto)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["claude.admin-api"])
    }

    @Test
    func `parses Anthropic admin cost and messages usage into daily summaries`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let costs = """
        {
          "data": [
            {
              "starting_at": "2023-11-14T00:00:00Z",
              "ending_at": "2023-11-15T00:00:00Z",
              "results": [
                {
                  "currency": "USD",
                  "amount": "12345.00",
                  "description": "Claude Sonnet 4 Usage - Input Tokens",
                  "cost_type": "tokens"
                },
                {
                  "currency": "USD",
                  "amount": "2500.00",
                  "description": "Web Search Usage",
                  "cost_type": "web_search"
                }
              ]
            },
            {
              "starting_at": "2023-11-15T00:00:00Z",
              "ending_at": "2023-11-16T00:00:00Z",
              "results": [
                {
                  "currency": "USD",
                  "amount": "5000",
                  "description": "Claude Haiku Usage - Output Tokens",
                  "cost_type": "tokens"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """
        let messages = """
        {
          "data": [
            {
              "starting_at": "2023-11-14T00:00:00Z",
              "ending_at": "2023-11-15T00:00:00Z",
              "results": [
                {
                  "uncached_input_tokens": 1500,
                  "cache_creation": {
                    "ephemeral_1h_input_tokens": 1000,
                    "ephemeral_5m_input_tokens": 500
                  },
                  "cache_read_input_tokens": 200,
                  "output_tokens": 500,
                  "model": "claude-sonnet-4-20250514"
                },
                {
                  "uncached_input_tokens": 100,
                  "output_tokens": 50,
                  "model": "claude-opus-4-20250514"
                }
              ]
            },
            {
              "starting_at": "2023-11-15T00:00:00Z",
              "ending_at": "2023-11-16T00:00:00Z",
              "results": [
                {
                  "uncached_input_tokens": 200,
                  "cache_read_input_tokens": 300,
                  "output_tokens": 100,
                  "model": "claude-sonnet-4-20250514"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """

        let snapshot = try ClaudeAdminAPIUsageFetcher._parseSnapshotForTesting(
            costs: Data(costs.utf8),
            messages: Data(messages.utf8),
            now: now)

        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily[0].costUSD == 148.45)
        #expect(snapshot.daily[0].inputTokens == 1600)
        #expect(snapshot.daily[0].cacheCreationInputTokens == 1500)
        #expect(snapshot.daily[0].cacheReadInputTokens == 200)
        #expect(snapshot.daily[0].outputTokens == 550)
        #expect(snapshot.daily[0].totalTokens == 3850)
        #expect(snapshot.last30Days.costUSD == 198.45)
        #expect(snapshot.last30Days.totalTokens == 4450)
        #expect(snapshot.topModels.first?.name == "claude-sonnet-4-20250514")
        #expect(snapshot.topModels.first?.totalTokens == 4300)
    }

    @Test
    func `maps Anthropic admin usage to Claude usage snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let apiUsage = ClaudeAdminAPIUsageSnapshot(
            daily: [
                ClaudeAdminAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: now,
                    endTime: now.addingTimeInterval(86400),
                    costUSD: 8.5,
                    inputTokens: 1000,
                    cacheCreationInputTokens: 400,
                    cacheReadInputTokens: 300,
                    outputTokens: 250,
                    totalTokens: 1950,
                    costItems: [],
                    models: []),
            ],
            updatedAt: now)

        let usage = apiUsage.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 8.5)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.period == "Last 30 days")
        #expect(usage.claudeAdminAPIUsage?.last30Days.totalTokens == 1950)
        #expect(usage.identity?.providerID == .claude)
        #expect(usage.identity?.loginMethod == "Admin API")
    }

    @Test
    func `fetch strategy reports admin api source label`() async throws {
        let strategy = ClaudeAdminAPIFetchStrategy(usageFetcher: { apiKey in
            #expect(apiKey == "sk-ant-admin-test")
            return ClaudeAdminAPIUsageSnapshot(daily: [], updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        })

        let result = try await strategy.fetch(self.makeContext())

        #expect(result.sourceLabel == "admin-api")
        #expect(result.usage.identity?.loginMethod == "Admin API")
    }
}
