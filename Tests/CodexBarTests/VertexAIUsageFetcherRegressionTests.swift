import Foundation
import Testing
@testable import CodexBarCore

struct VertexAIUsageFetcherRegressionTests {
    @Test
    func `fetchUsageSnapshot matches encoded Service Usage limit identifiers and retains Monitoring fallback`()
        async throws
    {
        let rateMetric = "aiplatform.googleapis.com/generate_content_requests_per_minute_per_project_per_base_model"
        let prefix = "projects/p/services/aiplatform.googleapis.com/consumerQuotaMetrics/\(rateMetric)"
        let encodedServiceUsageJSON = """
        {
          "metrics": [
            {
              "metric": "\(rateMetric)",
              "displayName": "Generate content requests",
              "consumerQuotaLimits": [
                {
                  "name": "\(prefix)/limits/%2Fmin%2Fproject%2Fregion",
                  "unit": "1/min/{project}/{region}",
                  "quotaBuckets": [
                    {"effectiveLimit": "100", "dimensions": {"region": "us-central1"}}
                  ]
                },
                {
                  "name": "\(prefix)/limits/%2Fd%2Fproject%2Fregion",
                  "unit": "1/d/{project}/{region}",
                  "quotaBuckets": [
                    {"effectiveLimit": "1000", "dimensions": {"region": "us-central1"}}
                  ]
                }
              ]
            }
          ]
        }
        """

        // 1. Monitoring RequestsPerMinute matches opaque Service Usage /limits/%2Fmin%2Fproject%2Fregion.
        let encodedMatchTransport = Self.routerTransport { url, filter in
            if url.host == "serviceusage.googleapis.com" {
                return (200, encodedServiceUsageJSON)
            }
            if filter.contains("quota/rate/net_usage") {
                return (200, """
                {"timeSeries":[
                  {"metric":{"labels":{"quota_metric":"\(rateMetric)","limit_name":"RequestsPerMinute"}},
                   "resource":{"labels":{"location":"us-central1"}},
                   "points":[{"interval":{"startTime":"2026-11-26T00:10:00Z"},"value":{"int64Value":"40"}}]}
                ]}
                """)
            }
            if filter.contains("quota/limit") {
                return (200, """
                {"timeSeries":[
                  {"metric":{"labels":{"quota_metric":"\(rateMetric)","limit_name":"RequestsPerMinute"}},
                   "resource":{"labels":{"location":"us-central1"}},
                   "points":[{"value":{"doubleValue":200}}]}
                ]}
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }

        let now = Date(timeIntervalSince1970: 1_795_653_000)
        let matched = try await VertexAIUsageFetcher.fetchUsageSnapshot(
            accessToken: "token",
            projectId: "proj-1",
            options: VertexAIQueryOptions(locationFilter: "us-central1"),
            now: now,
            transport: encodedMatchTransport)
        #expect(matched.rateQuotas.count == 1)
        let rpm = try #require(matched.rateQuotas.first)
        #expect(rpm.cadence == .perMinute)
        #expect(rpm.limitName == "RequestsPerMinute")
        #expect(rpm.usage == 40)
        #expect(rpm.limit == 200)
        #expect(rpm.usedPercent == 20)
        #expect(rpm.displayName == "Generate content requests")

        // 2. When no Service Usage candidate is compatible, Monitoring usage/limit fallback is retained.
        let fallbackTransport = Self.routerTransport { url, filter in
            if url.host == "serviceusage.googleapis.com" {
                return (200, encodedServiceUsageJSON)
            }
            if filter.contains("quota/rate/net_usage") {
                return (200, """
                {"timeSeries":[
                  {"metric":{"labels":{"quota_metric":"\(rateMetric)","limit_name":"CustomBurstLimit"}},
                   "resource":{"labels":{"location":"us-central1"}},
                   "points":[{"interval":{"startTime":"2026-11-26T00:10:00Z"},"value":{"int64Value":"25"}}]}
                ]}
                """)
            }
            if filter.contains("quota/limit") {
                return (200, """
                {"timeSeries":[
                  {"metric":{"labels":{"quota_metric":"\(rateMetric)","limit_name":"CustomBurstLimit"}},
                   "resource":{"labels":{"location":"us-central1"}},
                   "points":[{"value":{"doubleValue":100}}]}
                ]}
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }

        let fallback = try await VertexAIUsageFetcher.fetchUsageSnapshot(
            accessToken: "token",
            projectId: "proj-1",
            options: VertexAIQueryOptions(locationFilter: "us-central1"),
            now: now,
            transport: fallbackTransport)
        #expect(fallback.rateQuotas.count == 1)
        let custom = try #require(fallback.rateQuotas.first)
        #expect(custom.limitName == "CustomBurstLimit")
        #expect(custom.usage == 25)
        #expect(custom.limit == 100)
        #expect(custom.usedPercent == 25)
    }

    @Test
    func `fetchOnlineServingReport preserves regional identity until token coverage is reconciled`() async throws {
        let formatter = ISO8601DateFormatter()
        let hour10 = try #require(formatter.date(from: "2026-11-25T10:00:00Z"))
        let centralLabels = #""location":"us-central1","publisher":"google","model_user_id":"gemini-2.5-pro""#
        let eastLabels = #""location":"us-east5","publisher":"google","model_user_id":"gemini-2.5-pro""#
        let transport = Self.routerTransport { _, filter in
            if filter.contains("online_serving/token_count") {
                return (200, """
                {"timeSeries":[
                  {"metric":{"labels":{"type":"input","request_type":"shared"}},
                   "resource":{"labels":{\(centralLabels)}},
                   "points":[{"interval":{"startTime":"2026-11-25T10:00:00Z"},"value":{"int64Value":"1000"}}]}
                ]}
                """)
            }
            if filter.contains("online_serving/model_invocation_count") {
                return (200, """
                {"timeSeries":[
                  {"metric":{"labels":{"request_type":"shared"}},
                   "resource":{"labels":{\(centralLabels)}},
                   "points":[{"interval":{"startTime":"2026-11-25T10:00:00Z"},"value":{"int64Value":"5"}}]},
                  {"metric":{"labels":{"request_type":"shared"}},
                   "resource":{"labels":{\(eastLabels)}},
                   "points":[{"interval":{"startTime":"2026-11-25T10:00:00Z"},"value":{"int64Value":"12"}}]}
                ]}
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }

        let resolver = CostUsagePricing.ClaudeResolver(catalog: ModelsDevCatalog(providers: [:]))
        let outcome = try await VertexAIUsageFetcher.fetchOnlineServingReport(
            accessToken: "token",
            projectId: "proj-1",
            config: VertexAIUsageFetcher.OnlineServingReportConfig(
                since: hour10,
                until: hour10.addingTimeInterval(3600),
                calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC"),
                options: VertexAIQueryOptions(estimateServingCost: false),
                estimateCost: false),
            pricingResolver: resolver,
            transport: transport)
        guard case let .report(report, isPartial) = outcome else {
            Issue.record("Expected partial online serving report outcome")
            return
        }
        #expect(isPartial)
        #expect(report.hourly.count == 1)
        let hourly = try #require(report.hourly.first)
        #expect(hourly.totalTokens == 1000)
        #expect(!hourly.tokensAreComplete)
        #expect(report.data.first?.requestCount == 17)
    }

    @Test
    func `fetchUsageSnapshot preserves failed invocation query as unavailable counts`() async throws {
        let labels = #""location":"us-central1","publisher":"google","model_user_id":"gemini-2.5-pro""#
        let transport = Self.routerTransport { _, filter in
            if filter.contains("online_serving/model_invocation_count") {
                return (503, #"{"error":{"code":503}}"#)
            }
            if filter.contains("online_serving/token_count") {
                return (200, """
                {"timeSeries":[
                  {"metric":{"labels":{"type":"input","request_type":"shared"}},
                   "resource":{"labels":{\(labels)}},
                   "points":[{"value":{"int64Value":"1000"}}]}
                ]}
                """)
            }
            return (200, #"{"timeSeries":[]}"#)
        }

        let response = try await VertexAIUsageFetcher.fetchUsageSnapshot(
            accessToken: "token",
            projectId: "proj-1",
            options: VertexAIQueryOptions(includeOnlineServing: true, estimateServingCost: false),
            transport: transport)
        let summary = try #require(response.onlineServingSummary)
        #expect(!summary.invocationsAreComplete)
        #expect(summary.tokensAreComplete)
        #expect(summary.totalTokens == 1000)
        let model = try #require(summary.models.first)
        #expect(!model.invocationsAreComplete)
        #expect(model.tokensAreComplete)

        let credentials = VertexAIOAuthCredentials(
            accessToken: "token",
            refreshToken: "refresh",
            clientId: "client",
            clientSecret: "secret",
            projectId: "proj-1",
            email: "dev@example.com",
            expiryDate: Date().addingTimeInterval(3600))
        let snapshot = VertexAIOAuthFetchStrategy.mapUsage(response, credentials: credentials)
        let section = try #require(snapshot.details.first { $0.title == "Online serving (24h)" })
        let invocationsRow = try #require(section.rows.first { $0.label == "Invocations" })
        #expect(invocationsRow.value == "Unavailable")
        #expect(invocationsRow.value != "0")
        #expect(invocationsRow.secondaryValue == nil)
        let totalTokensRow = try #require(section.rows.first { $0.label == "Total tokens" })
        #expect(totalTokensRow.value == UsageFormatter.tokenCountString(1000))
        let modelRow = try #require(section.rows.first { $0.label == "gemini-2.5-pro" })
        #expect(modelRow.secondaryValue?.contains("Req: Unavailable") == true)
        #expect(modelRow.secondaryValue?.contains("0 req") != true)
    }

    private static func routerTransport(
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
}
