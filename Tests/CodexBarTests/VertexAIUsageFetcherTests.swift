import Foundation
import Testing
@testable import CodexBarCore

struct VertexAIUsageFetcherTests {
    @Test
    func `usage without limit name matches the regional named limit`() throws {
        let response = try VertexAIUsageFetcher.parseQuotaUsage(
            usageData: Self.fixture("issue-2958-usage-without-limit-name"),
            limitData: Self.fixture("issue-2958-regional-and-global-limits"))

        #expect(response.requestsUsedPercent == 1)
    }

    @Test
    func `existing exact limit name match remains authoritative`() throws {
        let response = try VertexAIUsageFetcher.parseQuotaUsage(
            usageData: Self.fixture("exact-named-usage"),
            limitData: Self.fixture("exact-named-limits"))

        #expect(response.requestsUsedPercent == 25)
    }

    @Test
    func `unnamed usage does not guess between limits in the same region`() throws {
        #expect(throws: VertexAIFetchError.self) {
            try VertexAIUsageFetcher.parseQuotaUsage(
                usageData: Self.fixture("issue-2958-usage-without-limit-name"),
                limitData: Self.fixture("ambiguous-regional-limits"))
        }
    }

    @Test(arguments: [[nil], [""], ["page-2", nil], ["page-2", "page-2"], [
        "page-2",
        "page-3",
        "page-2",
    ]] as [[String?]])
    func `pagination retains each distinct page once for usage and limits`(nextTokens: [String?]) async {
        let pages = Pages(nextTokens: nextTokens)
        let response = try? await VertexAIUsageFetcher.fetchUsage(
            accessToken: "fixture-token", projectId: "fixture-project", transport: pages)
        let expectedTokens: [String?] = [nil] + nextTokens.dropLast()
        #expect(await pages.tokens == expectedTokens + expectedTokens)
        #expect(response?.requestsUsedPercent == 25 * pow(3, Double(nextTokens.count - 1)) / Double(nextTokens.count))
    }

    @Test
    func `unique page tokens cannot exceed the per-query page budget`() async throws {
        let pages = Pages(nextTokens: (1...101).map { "page-\($0)" })
        await #expect {
            _ = try await VertexAIUsageFetcher.fetchUsage(
                accessToken: "fixture-token", projectId: "fixture-project", transport: pages)
        } throws: { error in
            guard case let .invalidResponse(message) = error as? VertexAIFetchError else { return false }
            return message == "Monitoring page limit exceeded"
        }
        #expect(await pages.tokens.count == 100)
    }

    @Test
    func `a final page at the page budget still succeeds`() async throws {
        let pages = Pages(nextTokens: (1..<100).map { "page-\($0)" } + [nil])
        _ = try await VertexAIUsageFetcher.fetchUsage(
            accessToken: "fixture-token", projectId: "fixture-project", transport: pages)
        #expect(await pages.tokens.count == 200)
    }

    @Test
    func `fetchUsageSnapshot sums rate net_usage across methods and disambiguates PerMinute vs Pacific PerDay`()
        async throws
    {
        // 2026-11-26T00:30:00Z = 2026-11-25T16:30:00-08:00 (Pacific)
        let now = Date(timeIntervalSince1970: 1_795_653_000)
        let transport = Self.makeRateAndServingTransport()

        let response = try await VertexAIUsageFetcher.fetchUsageSnapshot(
            accessToken: "token",
            projectId: "proj-1",
            options: VertexAIQueryOptions(locationFilter: "us-central1", baseModelFilter: "gemini-2.5-pro"),
            now: now,
            transport: transport)

        // Peak 60s sum across GenerateContent (40) + StreamGenerateContent (20) = 60 / 100 = 60%
        let perMinute = try #require(response.rateQuotas.first { $0.cadence == .perMinute })
        #expect(perMinute.usage == 60)
        #expect(perMinute.limit == 100)
        #expect(perMinute.usedPercent == 60)
        #expect(perMinute.exceededCount == 3)
        #expect(perMinute.resetsAt == nil)
        #expect(perMinute.baseModel == "gemini-2.5-pro")

        // Pacific day sum excludes 2026-11-25T07:00:00Z (yesterday in Pacific time), keeping 40 + 20 = 60 / 1000 = 6%
        let perDay = try #require(response.rateQuotas.first { $0.cadence == .perDay })
        #expect(perDay.usage == 60)
        #expect(perDay.limit == 1000)
        #expect(perDay.usedPercent == 6)
        #expect(perDay.resetsAt == VertexAIUsageFetcher.nextPacificMidnight(after: now))

        // Filtered online serving retains only us-central1 / gemini-2.5-pro
        let serving = try #require(response.onlineServingSummary)
        #expect(serving.totalInvocations == 12)
        #expect(serving.inputTokens == 1000)
        #expect(serving.outputTokens == 250)
        #expect(serving.sharedInvocations == 12)
        #expect(serving.dedicatedInvocations == 0)
        #expect(serving.models.count == 1)
    }

    @Test
    func `fetchUsageSnapshot degrades gracefully on optional 403 and 404 endpoints`() async throws {
        let transport = Self.routerTransport { url, filter in
            if url.host == "serviceusage.googleapis.com" {
                return (403, #"{"error":{"code":403,"message":"missing serviceusage.quotas.get"}}"#)
            }
            if filter.contains("quota/exceeded") || filter.contains("online_serving/") {
                return (404, #"{"error":{"code":404,"message":"not found"}}"#)
            }
            if filter.contains("quota/allocation/usage") {
                return (200, """
                {"timeSeries":[{"metric":{"labels":{"quota_metric":"alloc-m","limit_name":"L1"}},
                "resource":{"labels":{"location":"global"}},"points":[{"value":{"doubleValue":30}}]}]}
                """)
            }
            if filter.contains("quota/limit") {
                return (200, """
                {"timeSeries":[{"metric":{"labels":{"quota_metric":"alloc-m","limit_name":"L1"}},
                "resource":{"labels":{"location":"global"}},"points":[{"value":{"doubleValue":100}}]}]}
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }

        let response = try await VertexAIUsageFetcher.fetchUsageSnapshot(
            accessToken: "token",
            projectId: "proj-1",
            transport: transport)
        #expect(response.highestAllocationQuota?.usedPercent == 30)
        #expect(response.onlineServingSummary == nil)
        #expect(response.requestsUsedPercent == 30)
    }

    @Test
    func `fetchUsageSnapshot propagates 401 and 403 on primary quota endpoints and throws noData when all empty`()
        async throws
    {
        let unauthorizedTransport = Self.routerTransport { _, _ in (401, #"{"error":"unauthorized"}"#) }
        await #expect(throws: VertexAIFetchError.unauthorized) {
            _ = try await VertexAIUsageFetcher.fetchUsageSnapshot(
                accessToken: "bad", projectId: "proj-1", transport: unauthorizedTransport)
        }

        let forbiddenTransport = Self.routerTransport { _, _ in (403, #"{"error":"forbidden"}"#) }
        await #expect(throws: VertexAIFetchError.forbidden) {
            _ = try await VertexAIUsageFetcher.fetchUsageSnapshot(
                accessToken: "bad", projectId: "proj-1", transport: forbiddenTransport)
        }

        let emptyTransport = Self.routerTransport { _, _ in (200, #"{"timeSeries":[]}"#) }
        await #expect(throws: VertexAIFetchError.noData) {
            _ = try await VertexAIUsageFetcher.fetchUsageSnapshot(
                accessToken: "ok", projectId: "proj-1", transport: emptyTransport)
        }
    }

    @Test
    func `fetchOnlineServingReport builds daily and hourly entries with opt-in shared pricing and dedup`()
        async throws
    {
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let since = Date(timeIntervalSince1970: 1_795_564_800) // 2026-11-25T00:00:00Z
        let until = Date(timeIntervalSince1970: 1_795_651_199)
        let transport = Self.makeOnlineServingReportTransport()

        let unpricedReport = try #require(await VertexAIUsageFetcher.fetchOnlineServingReport(
            accessToken: "token",
            projectId: "proj-1",
            config: VertexAIUsageFetcher.OnlineServingReportConfig(
                since: since,
                until: until,
                calendar: calendar,
                options: VertexAIQueryOptions(),
                estimateCost: false,
                excludeAnthropicPublisher: false),
            pricingResolver: CostUsagePricing.ClaudeResolver(catalog: ModelsDevCatalog(providers: [:])),
            transport: transport))
        #expect(unpricedReport.summary?.totalTokens == 1_105_000)
        #expect(unpricedReport.summary?.totalCostUSD == nil)
        #expect(unpricedReport.hourly.count == 2)

        let pricedReport = try #require(await VertexAIUsageFetcher.fetchOnlineServingReport(
            accessToken: "token",
            projectId: "proj-1",
            config: VertexAIUsageFetcher.OnlineServingReportConfig(
                since: since,
                until: until,
                calendar: calendar,
                options: VertexAIQueryOptions(),
                estimateCost: true,
                excludeAnthropicPublisher: false),
            pricingResolver: CostUsagePricing.ClaudeResolver(catalog: ModelsDevCatalog(providers: [:])),
            transport: transport))
        // Dedicated gemini-2.5-pro has costUSD == nil while shared claude-sonnet-4-6 has priced USD.
        let pricedEntry = try #require(pricedReport.data.first)
        #expect(pricedEntry.unpricedRequestCount == 2)
        #expect(pricedEntry.estimatedRequestCount == 10)
        #expect((pricedEntry.modelBreakdowns?.first { $0.modelName == "claude-sonnet-4-6" }?.costUSD ?? 0) > 0)
        #expect(pricedEntry.modelBreakdowns?.first { $0.modelName == "gemini-2.5-pro" }?.costUSD == nil)

        // Excluding anthropic publisher leaves only gemini-2.5-pro
        let dedupedReport = try #require(await VertexAIUsageFetcher.fetchOnlineServingReport(
            accessToken: "token",
            projectId: "proj-1",
            config: VertexAIUsageFetcher.OnlineServingReportConfig(
                since: since,
                until: until,
                calendar: calendar,
                options: VertexAIQueryOptions(),
                estimateCost: true,
                excludeAnthropicPublisher: true),
            pricingResolver: CostUsagePricing.ClaudeResolver(catalog: ModelsDevCatalog(providers: [:])),
            transport: transport))
        #expect(dedupedReport.summary?.totalTokens == 5000)
        #expect(dedupedReport.data.first?.modelsUsed == ["gemini-2.5-pro"])
    }

    private static func makeConsumerQuotaJSON(rateMetric: String) -> String {
        let prefix = "projects/p/services/aiplatform.googleapis.com/consumerQuotaMetrics/\(rateMetric)"
        return """
        {
          "metrics": [
            {
              "metric": "\(rateMetric)",
              "displayName": "Generate content requests",
              "consumerQuotaLimits": [
                {
                  "name": "\(prefix)/limits/PerMinute",
                  "unit": "1/min/{project}",
                  "quotaBuckets": [
                    {
                      "effectiveLimit": "100",
                      "dimensions": {"region": "us-central1", "base_model": "gemini-2.5-pro"}
                    },
                    {
                      "effectiveLimit": "50",
                      "dimensions": {"region": "us-east5", "base_model": "claude-sonnet-4-6"}
                    }
                  ]
                },
                {
                  "name": "\(prefix)/limits/PerDay",
                  "unit": "1/d/{project}",
                  "quotaBuckets": [
                    {
                      "effectiveLimit": "1000",
                      "dimensions": {"region": "us-central1", "base_model": "gemini-2.5-pro"}
                    }
                  ]
                }
              ]
            }
          ]
        }
        """
    }

    private static func makeRateAndServingTransport() -> ProviderHTTPTransportStub {
        let rateMetric = "aiplatform.googleapis.com/generate_content_requests_per_minute_per_project_per_base_model"
        return Self.routerTransport { url, filter in
            if url.host == "serviceusage.googleapis.com" {
                return (200, Self.makeConsumerQuotaJSON(rateMetric: rateMetric))
            }
            if filter.contains("quota/rate/net_usage") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"quota_metric": "\(rateMetric)", "method": "GenerateContent"}},
                      "resource": {"labels": {"location": "us-central1"}},
                      "points": [
                        {"interval": {"startTime": "2026-11-26T00:10:00Z"}, "value": {"int64Value": "40"}},
                        {"interval": {"startTime": "2026-11-25T07:00:00Z"}, "value": {"int64Value": "50"}}
                      ]
                    },
                    {
                      "metric": {"labels": {"quota_metric": "\(rateMetric)", "method": "StreamGenerateContent"}},
                      "resource": {"labels": {"location": "us-central1"}},
                      "points": [
                        {"interval": {"startTime": "2026-11-26T00:10:00Z"}, "value": {"int64Value": "20"}}
                      ]
                    }
                  ]
                }
                """)
            }
            if filter.contains("quota/exceeded") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"quota_metric": "\(rateMetric)", "limit_name": "PerMinute"}},
                      "resource": {"labels": {"location": "us-central1"}},
                      "points": [{"value": {"boolValue": true}}, {"value": {"int64Value": "2"}}]
                    }
                  ]
                }
                """)
            }
            if filter.contains("quota/allocation/usage") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"quota_metric": "alloc-metric", "limit_name": "Concurrent"}},
                      "resource": {"labels": {"location": "us-central1"}},
                      "points": [{"value": {"doubleValue": 5}}]
                    }
                  ]
                }
                """)
            }
            if filter.contains("quota/limit") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"quota_metric": "alloc-metric", "limit_name": "Concurrent"}},
                      "resource": {"labels": {"location": "us-central1"}},
                      "points": [{"value": {"doubleValue": 20}}]
                    }
                  ]
                }
                """)
            }
            if filter.contains("online_serving/model_invocation_count") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"request_type": "shared"}},
                      "resource": {
                        "labels": {
                          "location": "us-central1",
                          "publisher": "google",
                          "model_user_id": "gemini-2.5-pro"
                        }
                      },
                      "points": [{"value": {"int64Value": "12"}}]
                    },
                    {
                      "metric": {"labels": {"request_type": "dedicated"}},
                      "resource": {
                        "labels": {
                          "location": "us-east5",
                          "publisher": "anthropic",
                          "model_user_id": "claude-sonnet-4-6@20250514"
                        }
                      },
                      "points": [{"value": {"int64Value": "4"}}]
                    }
                  ]
                }
                """)
            }
            if filter.contains("online_serving/token_count") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"type": "input", "request_type": "shared"}},
                      "resource": {
                        "labels": {
                          "location": "us-central1",
                          "publisher": "google",
                          "model_user_id": "gemini-2.5-pro"
                        }
                      },
                      "points": [{"value": {"int64Value": "1000"}}]
                    },
                    {
                      "metric": {"labels": {"type": "output", "request_type": "shared"}},
                      "resource": {
                        "labels": {
                          "location": "us-central1",
                          "publisher": "google",
                          "model_user_id": "gemini-2.5-pro"
                        }
                      },
                      "points": [{"value": {"int64Value": "250"}}]
                    }
                  ]
                }
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }
    }

    private static func makeOnlineServingReportTransport() -> ProviderHTTPTransportStub {
        self.routerTransport { _, filter in
            if filter.contains("online_serving/token_count") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"type": "input", "request_type": "shared"}},
                      "resource": {
                        "labels": {
                          "location": "us-east5",
                          "publisher": "anthropic",
                          "model_user_id": "claude-sonnet-4-6@20250514"
                        }
                      },
                      "points": [
                        {"interval": {"startTime": "2026-11-25T10:00:00Z"}, "value": {"int64Value": "1000000"}}
                      ]
                    },
                    {
                      "metric": {"labels": {"type": "output", "request_type": "shared"}},
                      "resource": {
                        "labels": {
                          "location": "us-east5",
                          "publisher": "anthropic",
                          "model_user_id": "claude-sonnet-4-6@20250514"
                        }
                      },
                      "points": [
                        {"interval": {"startTime": "2026-11-25T10:00:00Z"}, "value": {"int64Value": "100000"}}
                      ]
                    },
                    {
                      "metric": {"labels": {"type": "input", "request_type": "dedicated"}},
                      "resource": {
                        "labels": {
                          "location": "us-central1",
                          "publisher": "google",
                          "model_user_id": "gemini-2.5-pro"
                        }
                      },
                      "points": [
                        {"interval": {"startTime": "2026-11-25T11:00:00Z"}, "value": {"int64Value": "5000"}}
                      ]
                    }
                  ]
                }
                """)
            }
            if filter.contains("online_serving/model_invocation_count") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"request_type": "shared"}},
                      "resource": {
                        "labels": {
                          "location": "us-east5",
                          "publisher": "anthropic",
                          "model_user_id": "claude-sonnet-4-6@20250514"
                        }
                      },
                      "points": [
                        {"interval": {"startTime": "2026-11-25T10:00:00Z"}, "value": {"int64Value": "10"}}
                      ]
                    },
                    {
                      "metric": {"labels": {"request_type": "dedicated"}},
                      "resource": {
                        "labels": {
                          "location": "us-central1",
                          "publisher": "google",
                          "model_user_id": "gemini-2.5-pro"
                        }
                      },
                      "points": [
                        {"interval": {"startTime": "2026-11-25T11:00:00Z"}, "value": {"int64Value": "2"}}
                      ]
                    }
                  ]
                }
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }
    }

    fileprivate static func routerTransport(
        handler: @escaping @Sendable (URL, String) -> (Int, String)) -> ProviderHTTPTransportStub
    {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "filter" }?.value ?? ""
            let (statusCode, body) = handler(url, filter)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil))
            return (Data(body.utf8), response)
        }
    }

    private actor Pages: ProviderHTTPTransport {
        let nextTokens: [String?]
        private(set) var tokens: [String?] = []

        init(nextTokens: [String?]) {
            self.nextTokens = nextTokens
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let token = query.first { $0.name == "pageToken" }?.value
            let isLimit = query.first { $0.name == "filter" }?.value?.contains("quota/limit") == true
            let index = self.tokens.count - (isLimit ? self.nextTokens.count : 0)
            self.tokens.append(token)
            // Bound the broken implementation by request count, never by elapsed time.
            guard self.nextTokens.indices.contains(index) else { throw URLError(.badServerResponse) }
            let value = isLimit ? 100 * Double(index + 1) : 25 * pow(3, Double(index))
            let next = self.nextTokens[index].map { #", "nextPageToken":"\#($0)""# } ?? ""
            let body = #"""
            {"timeSeries":[{"metric":{"labels":{"quota_metric":"fixture-quota"}},"resource":{},
            "points":[{"value":{"doubleValue":\#(value)}}]}]\#(next)}
            """#
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }

    private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Providers/VertexAI")))
    }
}

struct VertexAIUsageSnapshotEdgeCaseTests {
    @Test
    func `makeSnapshotUsageResponse sorts 24 tied zero-percent buckets deterministically`() throws {
        var allocationSeries: [VertexAIUsageFetcher.MonitoringTimeSeries] = []
        var limitSeries: [VertexAIUsageFetcher.MonitoringTimeSeries] = []
        let zeroPoint = VertexAIUsageFetcher.MonitoringPoint(
            interval: nil,
            value: VertexAIUsageFetcher.MonitoringValue(doubleValue: 0, int64Value: nil, boolValue: nil))
        let limitPoint = VertexAIUsageFetcher.MonitoringPoint(
            interval: nil,
            value: VertexAIUsageFetcher.MonitoringValue(doubleValue: 100, int64Value: nil, boolValue: nil))

        for idx in 0..<24 {
            let metric = "aiplatform.googleapis.com/quota_metric_\(idx % 3)"
            let limitName = "Limit_\(idx % 4)"
            let location = "region-\(idx % 2)-\(idx)"
            let seriesMetric = VertexAIUsageFetcher.MonitoringMetric(
                type: nil,
                labels: ["quota_metric": metric, "limit_name": limitName])
            let seriesResource = VertexAIUsageFetcher.MonitoringResource(
                type: nil,
                labels: ["location": location])
            allocationSeries.append(.init(metric: seriesMetric, resource: seriesResource, points: [zeroPoint]))
            limitSeries.append(.init(metric: seriesMetric, resource: seriesResource, points: [limitPoint]))
        }

        let forward = try VertexAIUsageFetcher.makeSnapshotUsageResponse(.init(
            allocationSeries: allocationSeries,
            rateSeries: [],
            limitSeries: limitSeries,
            exceededSeries: [],
            consumerMetrics: [],
            onlineServingSummary: nil,
            options: VertexAIQueryOptions(),
            now: Date(timeIntervalSince1970: 1_795_653_000)))
        let reversed = try VertexAIUsageFetcher.makeSnapshotUsageResponse(.init(
            allocationSeries: allocationSeries.reversed(),
            rateSeries: [],
            limitSeries: limitSeries.reversed(),
            exceededSeries: [],
            consumerMetrics: [],
            onlineServingSummary: nil,
            options: VertexAIQueryOptions(),
            now: Date(timeIntervalSince1970: 1_795_653_000)))

        #expect(forward.allocationQuotas.count == 24)
        #expect(forward.allocationQuotas == reversed.allocationQuotas)
        #expect(forward.allocationQuotas.first == forward.highestAllocationQuota)
    }

    @Test
    func `fetchUsageSnapshot merges multi-page consumerQuotaMetrics entries for the same metric`() async throws {
        let rateMetric = "aiplatform.googleapis.com/generate_content_requests_per_minute_per_project_per_base_model"
        let prefix = "projects/p/services/aiplatform.googleapis.com/consumerQuotaMetrics/\(rateMetric)"
        let transport = VertexAIUsageFetcherTests.routerTransport { url, filter in
            if url.host == "serviceusage.googleapis.com" {
                let pageToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "pageToken" }?.value
                if pageToken == nil {
                    return (200, """
                    {
                      "metrics": [
                        {
                          "metric": "\(rateMetric)",
                          "displayName": "Generate content requests",
                          "consumerQuotaLimits": [
                            {
                              "name": "\(prefix)/limits/PerMinute",
                              "unit": "1/min/{project}",
                              "quotaBuckets": [
                                {"effectiveLimit": "40", "dimensions": {"region": "us-central1"}}
                              ]
                            }
                          ]
                        }
                      ],
                      "nextPageToken": "page-2"
                    }
                    """)
                }
                return (200, """
                {
                  "metrics": [
                    {
                      "metric": "\(rateMetric)",
                      "displayName": "",
                      "consumerQuotaLimits": [
                        {
                          "name": "\(prefix)/limits/PerDay",
                          "unit": "1/d/{project}",
                          "quotaBuckets": [
                            {"effectiveLimit": "1000", "dimensions": {"region": "us-central1"}}
                          ]
                        }
                      ]
                    }
                  ]
                }
                """)
            }
            if filter.contains("quota/rate/net_usage") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"quota_metric": "\(rateMetric)", "method": "GenerateContent"}},
                      "resource": {"labels": {"location": "us-central1"}},
                      "points": [
                        {"interval": {"startTime": "2026-11-26T00:10:00Z"}, "value": {"int64Value": "20"}}
                      ]
                    }
                  ]
                }
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }

        let now = Date(timeIntervalSince1970: 1_795_653_000)
        let response = try await VertexAIUsageFetcher.fetchUsageSnapshot(
            accessToken: "token",
            projectId: "proj-1",
            options: VertexAIQueryOptions(locationFilter: "us-central1"),
            now: now,
            transport: transport)
        let perMinute = try #require(response.rateQuotas.first { $0.cadence == .perMinute })
        let perDay = try #require(response.rateQuotas.first { $0.cadence == .perDay })
        #expect(response.rateQuotas.count == 2)
        #expect(perMinute.limit == 40)
        #expect(perMinute.usedPercent == 50)
        #expect(perMinute.displayName == "Generate content requests")
        #expect(perDay.limit == 1000)
        #expect(perDay.usedPercent == 2)
        #expect(perDay.displayName == "Generate content requests")
    }

    @Test
    func `fetchUsageSnapshot degrades gracefully when rate net_usage returns malformed JSON`() async throws {
        let transport = VertexAIUsageFetcherTests.routerTransport { _, filter in
            if filter.contains("quota/rate/net_usage") {
                return (200, "{ not valid json !!!")
            }
            if filter.contains("quota/allocation/usage") {
                return (200, """
                {"timeSeries":[{"metric":{"labels":{"quota_metric":"alloc-m","limit_name":"L1"}},
                "resource":{"labels":{"location":"global"}},"points":[{"value":{"doubleValue":30}}]}]}
                """)
            }
            if filter.contains("quota/limit") {
                return (200, """
                {"timeSeries":[{"metric":{"labels":{"quota_metric":"alloc-m","limit_name":"L1"}},
                "resource":{"labels":{"location":"global"}},"points":[{"value":{"doubleValue":100}}]}]}
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }

        let response = try await VertexAIUsageFetcher.fetchUsageSnapshot(
            accessToken: "token",
            projectId: "proj-1",
            transport: transport)
        #expect(response.rateQuotas.isEmpty)
        #expect(response.highestAllocationQuota?.usedPercent == 30)
        #expect(response.requestsUsedPercent == 30)
    }

    @Test
    func `fetchUsageSnapshot prefers non-model bucket when baseModelFilter is nil`() async throws {
        let allocMetric = "aiplatform.googleapis.com/regional_alloc"
        let rateMetric = "aiplatform.googleapis.com/regional_rate"
        let allocPrefix = "projects/p/services/aiplatform.googleapis.com/consumerQuotaMetrics/\(allocMetric)"
        let ratePrefix = "projects/p/services/aiplatform.googleapis.com/consumerQuotaMetrics/\(rateMetric)"

        let transport = VertexAIUsageFetcherTests.routerTransport { url, filter in
            if url.host == "serviceusage.googleapis.com" {
                return (200, """
                {
                  "metrics": [
                    {
                      "metric": "\(allocMetric)",
                      "displayName": "Regional allocation",
                      "consumerQuotaLimits": [
                        {
                          "name": "\(allocPrefix)/limits/Alloc",
                          "quotaBuckets": [
                            {"effectiveLimit": "500", "dimensions": {"region": "us-central1"}},
                            {
                              "effectiveLimit": "100",
                              "dimensions": {"region": "us-central1", "base_model": "gemini-2.5-pro"}
                            }
                          ]
                        }
                      ]
                    },
                    {
                      "metric": "\(rateMetric)",
                      "displayName": "Regional rate",
                      "consumerQuotaLimits": [
                        {
                          "name": "\(ratePrefix)/limits/PerMinute",
                          "unit": "1/min/{project}",
                          "quotaBuckets": [
                            {"effectiveLimit": "500", "dimensions": {"region": "us-central1"}},
                            {
                              "effectiveLimit": "100",
                              "dimensions": {"region": "us-central1", "base_model": "gemini-2.5-pro"}
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
                """)
            }
            if filter.contains("quota/allocation/usage") {
                return (200, """
                {"timeSeries":[{"metric":{"labels":{"quota_metric":"\(allocMetric)","limit_name":"Alloc"}},
                "resource":{"labels":{"location":"us-central1"}},"points":[{"value":{"doubleValue":50}}]}]}
                """)
            }
            if filter.contains("quota/limit") {
                return (200, """
                {"timeSeries":[{"metric":{"labels":{"quota_metric":"\(allocMetric)","limit_name":"Alloc"}},
                "resource":{"labels":{"location":"us-central1"}},"points":[{"value":{"doubleValue":500}}]}]}
                """)
            }
            if filter.contains("quota/rate/net_usage") {
                return (200, """
                {"timeSeries":[{"metric":{"labels":{"quota_metric":"\(rateMetric)","method":"GenerateContent"}},
                "resource":{"labels":{"location":"us-central1"}},
                "points":[{"interval":{"startTime":"2026-11-26T00:10:00Z"},"value":{"int64Value":"50"}}]}]}
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }

        let now = Date(timeIntervalSince1970: 1_795_653_000)
        let response = try await VertexAIUsageFetcher.fetchUsageSnapshot(
            accessToken: "token",
            projectId: "proj-1",
            options: VertexAIQueryOptions(locationFilter: "us-central1", baseModelFilter: nil),
            now: now,
            transport: transport)

        let alloc = try #require(response.allocationQuotas.first)
        #expect(alloc.limit == 500)
        #expect(alloc.usedPercent == 10)
        #expect(alloc.baseModel == nil)

        #expect(response.rateQuotas.count == 1)
        let rate = try #require(response.rateQuotas.first)
        #expect(rate.limit == 500)
        #expect(rate.usedPercent == 10)
        #expect(rate.baseModel == nil)
    }

    @Test
    func `fetchUsageSnapshot scopes totalExceededCount by locationFilter and isolates rate limit_name`()
        async throws
    {
        let rateMetric = "aiplatform.googleapis.com/generate_content_requests"
        let prefix = "projects/p/services/aiplatform.googleapis.com/consumerQuotaMetrics/\(rateMetric)"
        let transport = VertexAIUsageFetcherTests.routerTransport { url, filter in
            if url.host == "serviceusage.googleapis.com" {
                return (200, """
                {
                  "metrics": [
                    {
                      "metric": "\(rateMetric)",
                      "displayName": "Requests",
                      "consumerQuotaLimits": [
                        {
                          "name": "\(prefix)/limits/PerMinute",
                          "unit": "1/min/{project}",
                          "quotaBuckets": [
                            {"effectiveLimit": "100", "dimensions": {"region": "us-central1"}}
                          ]
                        },
                        {
                          "name": "\(prefix)/limits/PerDay",
                          "unit": "1/d/{project}",
                          "quotaBuckets": [
                            {"effectiveLimit": "1000", "dimensions": {"region": "us-central1"}}
                          ]
                        }
                      ]
                    }
                  ]
                }
                """)
            }
            if filter.contains("quota/rate/net_usage") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"quota_metric": "\(rateMetric)", "limit_name": "PerMinute"}},
                      "resource": {"labels": {"location": "us-central1"}},
                      "points": [
                        {"interval": {"startTime": "2026-11-26T00:10:00Z"}, "value": {"int64Value": "40"}}
                      ]
                    },
                    {
                      "metric": {"labels": {"quota_metric": "\(rateMetric)", "limit_name": "PerDay"}},
                      "resource": {"labels": {"location": "us-central1"}},
                      "points": [
                        {"interval": {"startTime": "2026-11-26T00:10:00Z"}, "value": {"int64Value": "40"}}
                      ]
                    }
                  ]
                }
                """)
            }
            if filter.contains("quota/exceeded") {
                return (200, """
                {
                  "timeSeries": [
                    {
                      "metric": {"labels": {"quota_metric": "\(rateMetric)", "limit_name": "PerMinute"}},
                      "resource": {"labels": {"location": "us-central1"}},
                      "points": [{"value": {"int64Value": "1"}}]
                    },
                    {
                      "metric": {"labels": {"quota_metric": "\(rateMetric)", "limit_name": "PerMinute"}},
                      "resource": {"labels": {"location": "us-east5"}},
                      "points": [{"value": {"int64Value": "7"}}]
                    }
                  ]
                }
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }

        let now = Date(timeIntervalSince1970: 1_795_653_000)
        let response = try await VertexAIUsageFetcher.fetchUsageSnapshot(
            accessToken: "token",
            projectId: "proj-1",
            options: VertexAIQueryOptions(locationFilter: "us-central1"),
            now: now,
            transport: transport)

        #expect(response.totalExceededCount == 1)
        let perMinute = try #require(response.rateQuotas.first { $0.cadence == .perMinute })
        let perDay = try #require(response.rateQuotas.first { $0.cadence == .perDay })
        #expect(perMinute.usage == 40)
        #expect(perDay.usage == 40)
    }
}

extension VertexAIFetchError: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized),
             (.forbidden, .forbidden),
             (.noProject, .noProject),
             (.noData, .noData):
            true
        case let (.invalidResponse(lMsg), .invalidResponse(rMsg)):
            lMsg == rMsg
        default:
            false
        }
    }
}
