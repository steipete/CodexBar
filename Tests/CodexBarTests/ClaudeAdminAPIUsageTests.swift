import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ClaudeAdminAPIUsageTests {
    private func makeContext(
        apiKey: String = "sk-ant-admin-test",
        sourceMode: ProviderSourceMode = .api,
        workspaceSpendEnabled: Bool = false) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let env = [
            ClaudeAdminAPISettingsReader.adminAPIKeyEnvironmentKey: apiKey,
            ClaudeAdminAPISettingsReader.workspaceSpendEnvironmentKey: String(workspaceSpendEnabled),
        ]
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
        #expect(usage.detailRow(label: "30d tokens")?.value == "1,950")
        #expect(usage.identity?.providerID == .claude)
        #expect(usage.identity?.loginMethod == "Admin API")
    }

    @Test
    func `current day summary is zero when Claude admin history is stale`() throws {
        let now = try Self.localNoon(year: 2023, month: 11, day: 17)
        let bucketDay = try Self.localNoon(year: 2023, month: 11, day: 14)
        let apiUsage = ClaudeAdminAPIUsageSnapshot(
            daily: [
                ClaudeAdminAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: bucketDay,
                    endTime: bucketDay.addingTimeInterval(86400),
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

        #expect(apiUsage.currentDay.costUSD == 0)
        #expect(apiUsage.currentDay.totalTokens == 0)
        #expect(apiUsage.latestDay.costUSD == 8.5)
        #expect(apiUsage.latestDay.totalTokens == 1950)
    }

    @Test(arguments: [false, true])
    func `fetch strategy reports admin api source label`(enabled: Bool) async throws {
        let strategy = ClaudeAdminAPIFetchStrategy(usageFetcher: { apiKey, workspaceSpendEnabled in
            #expect(workspaceSpendEnabled == enabled)
            #expect(apiKey == "sk-ant-admin-test")
            return ClaudeAdminAPIUsageSnapshot(daily: [], updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        })

        let result = try await strategy.fetch(self.makeContext(workspaceSpendEnabled: enabled))

        #expect(result.sourceLabel == "admin-api")
        #expect(result.usage.identity?.loginMethod == "Admin API")
    }

    @Test
    func `workspace details preserve organization totals and default workspace cents`() throws {
        let costs = """
        {"data":[
          {"starting_at":"2026-09-23T00:00:00Z","ending_at":"2026-09-24T00:00:00Z","results":[
            {"currency":"USD","amount":"1250","description":"Input tokens","workspace_id":"wrk_fixture"},
            {"currency":"USD","amount":"250","description":"Output tokens","workspace_id":"wrk_fixture"},
            {"currency":"USD","amount":"50","description":"Input tokens","workspace_id":null}]},
          {"starting_at":"2026-09-24T00:00:00Z","ending_at":"2026-09-25T00:00:00Z","results":[
            {"currency":"USD","amount":"75","description":"Input tokens","workspace_id":null}]}]}
        """
        let now = try #require(ISO8601DateParser.parse("2026-09-24T12:00:00Z"))
        for enabled in [false, true] {
            let snapshot = try ClaudeAdminAPIUsageFetcher._parseSnapshotForTesting(
                costs: Data(costs.utf8),
                messages: Data(#"{"data":[]}"#.utf8),
                now: now,
                workspaceSpendEnabled: enabled)
            let usage = snapshot.toUsageSnapshot()
            #expect(usage.providerCost?.used == 16.25)
            #expect(snapshot.topCostItems.first?.costUSD == 13.75)
            let section = usage.details.first { $0.title == "Workspace spend · 30d" }
            if enabled {
                let rows = try #require(section?.rows)
                #expect(rows.map(\.label) == ["wrk_fixture", "Default"])
                #expect(rows.map(\.value) == ["$15.00", "$1.25"])
            } else {
                #expect(section == nil)
            }
        }
    }

    @Test(arguments: [false, true])
    func `workspace option groups the existing cost request only`(enabled: Bool) async throws {
        let calls = LockIsolated(0)
        let transport = ProviderHTTPTransportHandler { request in
            calls.setValue(calls.value + 1)
            let url = try #require(request.url)
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let groups = items.filter { $0.name == "group_by[]" }.compactMap(\.value)
            if url.path.hasSuffix("cost_report") {
                #expect(groups == (enabled ? ["description", "workspace_id"] : ["description"]))
            } else {
                #expect(url.path.hasSuffix("usage_report/messages"))
                #expect(groups == ["model"])
            }
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "fixture-admin-key")
            return (Data(#"{"data":[]}"#.utf8), HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let snapshot = try await ClaudeAdminAPIUsageFetcher.fetchUsage(
            apiKey: "fixture-admin-key", workspaceSpendEnabled: enabled, session: transport)
        #expect(calls.value == 2)
        #expect(snapshot.toUsageSnapshot().details.allSatisfy { $0.title != "Workspace spend · 30d" })
    }

    @Test
    func `workspace rows are bounded and single workspace retains the organization view`() throws {
        let now = try #require(ISO8601DateParser.parse("2026-09-24T12:00:00Z"))
        for count in [1, 25] {
            let rows = (0..<count).map {
                #"{"amount":"\#($0 * 100)","workspace_id":"wrk_fixture_\#($0)"}"#
            }.joined(separator: ",")
            let costs = """
            {"data":[{"starting_at":"2026-09-24T00:00:00Z","ending_at":"2026-09-25T00:00:00Z",
            "results":[\(rows)]}]}
            """
            let snapshot = try ClaudeAdminAPIUsageFetcher._parseSnapshotForTesting(
                costs: Data(costs.utf8),
                messages: Data(#"{"data":[]}"#.utf8),
                now: now,
                workspaceSpendEnabled: true)
            let usage = snapshot.toUsageSnapshot()
            let section = usage.details.first { $0.title == "Workspace spend · 30d" }
            #expect(usage.providerCost?.used == Double(count * (count - 1) / 2))
            #expect(section?.rows.count == (count == 1 ? nil : 20))
            if count > 1 {
                #expect(section?.rows.first?.label == "wrk_fixture_24")
                #expect(section?.rows.last?.label == "wrk_fixture_5")
            }
        }
    }

    @Test
    func `workspace totals use the same last thirty buckets as organization spend`() throws {
        let now = try #require(ISO8601DateParser.parse("2026-09-24T12:00:00Z"))
        let buckets = (0..<31).map { offset in
            let start = now.addingTimeInterval(Double(-offset) * 86400)
            let end = start.addingTimeInterval(86400)
            let amount = offset == 30 ? 10000 : 100
            return """
            {"starting_at":"\(ISO8601DateFormatter().string(from: start))",
             "ending_at":"\(ISO8601DateFormatter().string(from: end))",
             "results":[{"amount":"\(amount)","workspace_id":"wrk_fixture_\(offset % 2)"}]}
            """
        }.joined(separator: ",")
        let snapshot = try ClaudeAdminAPIUsageFetcher._parseSnapshotForTesting(
            costs: Data("{\"data\":[\(buckets)]}".utf8),
            messages: Data(#"{"data":[]}"#.utf8),
            now: now,
            workspaceSpendEnabled: true)
        #expect(snapshot.last30Days.costUSD == 30)
        #expect(snapshot.workspaceCosts?.map(\.costUSD) == [15, 15])
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(ClaudeAdminAPIUsageSnapshot.self, from: data) == snapshot)
    }

    private static func localNoon(year: Int, month: Int, day: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }
}
