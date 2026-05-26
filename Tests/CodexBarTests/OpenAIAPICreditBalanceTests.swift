import Foundation
import Testing
@testable import CodexBarCore

struct OpenAIAPICreditBalanceTests {
    private func makeContext(apiKey: String = "sk-test", historyDays: Int = 30) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let env = ["OPENAI_API_KEY": apiKey]
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: nil,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            costUsageHistoryDays: historyDays)
    }

    @Test
    func `prefers admin key environment variable`() {
        let token = OpenAIAPISettingsReader.apiKey(environment: [
            "OPENAI_API_KEY": "sk-project",
            "OPENAI_ADMIN_KEY": "sk-admin",
        ])

        #expect(token == "sk-admin")
    }

    @Test
    func `parses credit grants balance`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "object": "credit_summary",
          "total_granted": 25.5,
          "total_used": 7.25,
          "total_available": 18.25,
          "grants": {
            "object": "list",
            "data": [
              {
                "grant_amount": 10.0,
                "used_amount": 1.0,
                "effective_at": 1690000000,
                "expires_at": 1800000000
              }
            ]
          }
        }
        """

        let snapshot = try OpenAIAPICreditBalanceFetcher._parseSnapshotForTesting(Data(json.utf8), now: now)

        #expect(snapshot.totalGranted == 25.5)
        #expect(snapshot.totalUsed == 7.25)
        #expect(snapshot.totalAvailable == 18.25)
        #expect(snapshot.nextGrantExpiry == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test
    func `maps balance to usage snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let balance = OpenAIAPICreditBalanceSnapshot(
            totalGranted: 100,
            totalUsed: 40,
            totalAvailable: 60,
            nextGrantExpiry: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: now)

        let usage = balance.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 40)
        #expect(usage.primary?.resetDescription == "$60.00 available")
        #expect(usage.providerCost?.used == 40)
        #expect(usage.providerCost?.limit == 100)
        #expect(usage.identity?.providerID == .openai)
        #expect(usage.identity?.loginMethod == "API balance: $60.00")
    }

    @Test
    func `falls back to legacy billing when admin usage rejects credentials`() async throws {
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { _, _ in
                throw OpenAIAPIUsageError.apiError(endpoint: "costs", statusCode: 403)
            },
            balanceFetcher: { _ in
                OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(self.makeContext())

        #expect(result.sourceLabel == "billing-api")
        #expect(result.usage.identity?.loginMethod == "API balance: $75.00")
    }

    @Test
    func `preserves admin usage error when legacy fallback also fails`() async {
        let usageFailure = OpenAIAPIUsageError.parseFailed(endpoint: "costs", message: "changed")
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { _, _ in throw usageFailure },
            balanceFetcher: { _ in throw OpenAIAPICreditBalanceError.forbidden })

        do {
            _ = try await strategy.fetch(self.makeContext())
            Issue.record("Expected admin usage failure")
        } catch let error as OpenAIAPIUsageError {
            #expect(error == usageFailure)
        } catch {
            Issue.record("Expected OpenAIAPIUsageError, got \(error)")
        }
    }

    @Test
    func `parses admin costs and completions usage into daily summaries`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let costs = """
        {
          "object": "page",
          "data": [
            {
              "object": "bucket",
              "start_time": 1700000000,
              "end_time": 1700086400,
              "results": [
                {
                  "object": "organization.costs.result",
                  "amount": { "value": 12.50, "currency": "usd" },
                  "line_item": "Text tokens"
                },
                {
                  "object": "organization.costs.result",
                  "amount": { "value": "2.25", "currency": "usd" },
                  "line_item": "Web search tool calls"
                }
              ]
            },
            {
              "object": "bucket",
              "start_time": 1700086400,
              "end_time": 1700172800,
              "results": [
                {
                  "object": "organization.costs.result",
                  "amount": { "value": 4.00, "currency": "usd" },
                  "line_item": "Text tokens"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """
        let completions = """
        {
          "object": "page",
          "data": [
            {
              "object": "bucket",
              "start_time": 1700000000,
              "end_time": 1700086400,
              "results": [
                {
                  "object": "organization.usage.completions.result",
                  "input_tokens": 1000,
                  "input_cached_tokens": 250,
                  "output_tokens": 500,
                  "num_model_requests": 7,
                  "model": "gpt-5.2"
                },
                {
                  "object": "organization.usage.completions.result",
                  "input_tokens": 300,
                  "output_tokens": 200,
                  "num_model_requests": 3,
                  "model": "gpt-5.2-codex"
                }
              ]
            },
            {
              "object": "bucket",
              "start_time": 1700086400,
              "end_time": 1700172800,
              "results": [
                {
                  "object": "organization.usage.completions.result",
                  "input_tokens": 200,
                  "output_tokens": 100,
                  "num_model_requests": 2,
                  "model": "gpt-5.2"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """

        let snapshot = try OpenAIAPIUsageFetcher._parseSnapshotForTesting(
            costs: Data(costs.utf8),
            completions: Data(completions.utf8),
            now: now,
            historyDays: 90)

        #expect(snapshot.historyDays == 90)
        #expect(snapshot.historyWindowLabel == "90d")
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily[0].costUSD == 14.75)
        #expect(snapshot.daily[0].requests == 10)
        #expect(snapshot.daily[0].totalTokens == 2000)
        #expect(snapshot.daily[0].cachedInputTokens == 250)
        #expect(snapshot.daily[0].lineItems.first?.name == "Text tokens")
        #expect(snapshot.last30Days.costUSD == 18.75)
        #expect(snapshot.last30Days.requests == 12)
        #expect(snapshot.last30Days.totalTokens == 2300)
        #expect(snapshot.topModels.first?.name == "gpt-5.2")
        #expect(snapshot.topModels.first?.totalTokens == 1800)
    }

    @Test
    func `admin usage fetch pages long history within endpoint bucket limit`() async throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let emptyPage = Data(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#.utf8)
        let transport = ProviderHTTPTransportStub { request in
            let response = try HTTPURLResponse(
                url: #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil)!
            return (emptyPage, response)
        }

        let snapshot = try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: "sk-test",
            costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
            completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
            session: transport,
            now: now,
            historyDays: 90)

        let requests = await transport.requests()
        let limits = requests.compactMap { request -> Int? in
            guard let url = request.url,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let raw = components.queryItems?.first(where: { $0.name == "limit" })?.value
            else { return nil }
            return Int(raw)
        }

        #expect(snapshot.historyDays == 90)
        #expect(requests.count == 6)
        #expect(limits == [31, 31, 28, 31, 31, 28])
        #expect(limits.allSatisfy { $0 <= 31 })
    }

    @Test
    func `admin usage retries transient completions failure once`() async throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let emptyPage = Data(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#.utf8)
        let completions = Data("""
        {
          "object": "page",
          "data": [
            {
              "object": "bucket",
              "start_time": 1700000000,
              "end_time": 1700086400,
              "results": [
                {
                  "object": "organization.usage.completions.result",
                  "input_tokens": 10,
                  "output_tokens": 5,
                  "num_model_requests": 1,
                  "model": "gpt-5.2"
                }
              ]
            }
          ],
          "has_more": false,
          "next_page": null
        }
        """.utf8)
        let transport = OpenAIAdminUsageRetryScript(costs: emptyPage, completions: completions)

        let snapshot = try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: "sk-test",
            costsURL: #require(URL(string: "https://api.openai.test/v1/organization/costs")),
            completionsURL: #require(URL(string: "https://api.openai.test/v1/organization/usage/completions")),
            session: transport,
            now: now,
            historyDays: 1,
            retryPolicy: ProviderHTTPRetryPolicy(maxRetries: 1, baseDelaySeconds: 0, maxDelaySeconds: 0))

        #expect(snapshot.latestDay.totalTokens == 15)
        #expect(snapshot.latestDay.requests == 1)
        #expect(await transport.completionsRequestCount() == 2)
    }

    @Test
    func `maps admin usage to openai usage snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let apiUsage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: now,
                    endTime: now.addingTimeInterval(86400),
                    costUSD: 8.5,
                    requests: 42,
                    inputTokens: 1000,
                    cachedInputTokens: 400,
                    outputTokens: 250,
                    totalTokens: 1250,
                    lineItems: [],
                    models: []),
            ],
            updatedAt: now)

        let usage = apiUsage.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.providerCost?.used == 8.5)
        #expect(usage.providerCost?.limit == 0)
        #expect(usage.providerCost?.period == "Last 30 days")
        #expect(usage.openAIAPIUsage?.last30Days.requests == 42)
        #expect(usage.identity?.loginMethod == "Admin API")
    }

    @Test
    func `maps admin usage to cost token snapshot`() {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let apiUsage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-13",
                    startTime: now.addingTimeInterval(-86400),
                    endTime: now,
                    costUSD: 2.25,
                    requests: 3,
                    inputTokens: 300,
                    cachedInputTokens: 100,
                    outputTokens: 200,
                    totalTokens: 500,
                    lineItems: [],
                    models: [
                        OpenAIAPIUsageSnapshot.ModelBreakdown(
                            name: "gpt-5.2",
                            requests: 3,
                            inputTokens: 300,
                            cachedInputTokens: 100,
                            outputTokens: 200,
                            totalTokens: 500),
                    ]),
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: now,
                    endTime: now.addingTimeInterval(86400),
                    costUSD: 8.5,
                    requests: 42,
                    inputTokens: 1000,
                    cachedInputTokens: 400,
                    outputTokens: 250,
                    totalTokens: 1250,
                    lineItems: [],
                    models: [
                        OpenAIAPIUsageSnapshot.ModelBreakdown(
                            name: "gpt-5.2-codex",
                            requests: 42,
                            inputTokens: 1000,
                            cachedInputTokens: 400,
                            outputTokens: 250,
                            totalTokens: 1250),
                    ]),
            ],
            updatedAt: now,
            historyDays: 7)

        let snapshot = apiUsage.toCostUsageTokenSnapshot()

        #expect(snapshot.historyDays == 7)
        #expect(snapshot.sessionCostUSD == 8.5)
        #expect(snapshot.sessionTokens == 1250)
        #expect(snapshot.sessionRequests == 42)
        #expect(snapshot.last30DaysCostUSD == 10.75)
        #expect(snapshot.last30DaysTokens == 1750)
        #expect(snapshot.last30DaysRequests == 45)
        #expect(snapshot.daily.count == 2)
        #expect(snapshot.daily[1].cacheReadTokens == 400)
        #expect(snapshot.daily[1].requestCount == 42)
        #expect(snapshot.daily[1].modelBreakdowns?.first?.requestCount == 42)
        #expect(snapshot.daily[1].modelBreakdowns?.first?.modelName == "gpt-5.2-codex")
    }

    @Test
    func `falls back to credit balance when admin usage endpoint is unavailable`() async throws {
        let strategy = OpenAIAPIBalanceFetchStrategy(
            usageFetcher: { apiKey, historyDays in
                #expect(apiKey == "sk-test")
                #expect(historyDays == 90)
                throw OpenAIAPIUsageError.apiError(endpoint: "costs", statusCode: 500)
            },
            balanceFetcher: { apiKey in
                #expect(apiKey == "sk-test")
                return OpenAIAPICreditBalanceSnapshot(
                    totalGranted: 100,
                    totalUsed: 25,
                    totalAvailable: 75,
                    nextGrantExpiry: nil,
                    updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
            })

        let result = try await strategy.fetch(self.makeContext(historyDays: 90))

        #expect(result.sourceLabel == "billing-api")
        #expect(result.usage.providerCost?.used == 25)
        #expect(result.usage.providerCost?.limit == 100)
    }
}

private actor OpenAIAdminUsageRetryScript: ProviderHTTPTransport {
    private let costs: Data
    private let completions: Data
    private var completionsRequests = 0

    init(costs: Data, completions: Data) {
        self.costs = costs
        self.completions = completions
    }

    func completionsRequestCount() -> Int {
        self.completionsRequests
    }

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://api.openai.test")!
        if url.path.contains("/usage/completions") {
            self.completionsRequests += 1
            if self.completionsRequests == 1 {
                return (Data(), HTTPURLResponse(
                    url: url,
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil)!)
            }
            return (self.completions, HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil)!)
        }

        return (self.costs, HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!)
    }
}
