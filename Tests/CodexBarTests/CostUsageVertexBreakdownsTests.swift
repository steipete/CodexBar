import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageVertexBreakdownsTests {
    @Test
    func `vertexai emits projects and sessions breakdowns and keeps vertexAIOnly isolation strict`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 11, day: 25)
        let iso = "2026-11-25T12:00:00Z"

        let nativeLine = """
        {"type":"assistant","sessionId":"sess-native-1","cwd":"/tmp/native-app","timestamp":"\(iso)",\
        "requestId":"req_native_1","metadata":{"provider":"anthropic"},\
        "message":{"id":"msg_native_1","model":"claude-sonnet-4-6",\
        "usage":{"input_tokens":100,"output_tokens":50}}}
        """
        let vertexLine = """
        {"type":"assistant","sessionId":"sess-vertex-1","cwd":"/tmp/vertex-app","timestamp":"\(iso)",\
        "requestId":"req_vrtx_1","metadata":{"provider":"vertex"},\
        "message":{"id":"msg_vrtx_1","model":"claude-sonnet-4-6",\
        "usage":{"input_tokens":400,"output_tokens":100}}}
        """

        // 1. When only native Claude logs exist and allowClaudeFallback is false, Vertex stays strictly empty.
        let nativeFile = try env.writeClaudeProjectFile(
            relativePath: "native-proj/sess-native-1.jsonl",
            contents: nativeLine + "\n")
        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)

        let strictEmpty = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            vertexAISettings: VertexAIProviderSettings(
                telemetryCostSource: .localClaudeLogsOnly,
                allowClaudeFallback: false),
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot
        #expect(strictEmpty.daily.isEmpty)
        #expect(strictEmpty.projects.isEmpty)
        #expect(strictEmpty.sessions.isEmpty)
        #expect(strictEmpty.detailsAreComplete)

        // 2. Explicit allowClaudeFallback == true surfaces native logs AND their projects/sessions.
        let fallbackIncluded = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            vertexAISettings: VertexAIProviderSettings(
                telemetryCostSource: .localClaudeLogsOnly,
                allowClaudeFallback: true),
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot
        #expect(fallbackIncluded.last30DaysTokens == 150)
        #expect(fallbackIncluded.projects.count == 1)
        #expect(fallbackIncluded.projects.first?.path == "/tmp/native-app")
        #expect(fallbackIncluded.sessions.count == 1)
        #expect(fallbackIncluded.sessions.first?.sessionID == "sess-native-1")
        #expect(fallbackIncluded.detailsAreComplete)

        // 3. With a Vertex log alongside a native log, strict mode isolates only Vertex projects & sessions.
        #expect(FileManager.default.fileExists(atPath: nativeFile.path))
        _ = try env.writeClaudeProjectFile(
            relativePath: "vertex-proj/sess-vertex-1.jsonl",
            contents: vertexLine + "\n")
        let strictVertex = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            vertexAISettings: VertexAIProviderSettings(
                telemetryCostSource: .localClaudeLogsOnly,
                allowClaudeFallback: false),
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot
        #expect(strictVertex.last30DaysTokens == 500)
        #expect(strictVertex.projects.map(\.path) == ["/tmp/vertex-app"])
        #expect(strictVertex.sessions.map(\.sessionID) == ["sess-vertex-1"])
        #expect(strictVertex.detailsAreComplete)
    }

    @Test
    func `auto telemetry mode preserves anthropic cloud totals while keeping local breakdowns separate`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 11, day: 25)
        let iso = "2026-11-25T12:00:00Z"

        let gcloudDir = env.root.appendingPathComponent("gcloud", isDirectory: true)
        try FileManager.default.createDirectory(at: gcloudDir, withIntermediateDirectories: true)
        try """
        {
          "client_id": "cid",
          "client_secret": "csecret",
          "refresh_token": "rtoken",
          "access_token": "valid-token",
          "token_expiry": "2099-01-01T00:00:00Z"
        }
        """.write(
            to: gcloudDir.appendingPathComponent("application_default_credentials.json"),
            atomically: true,
            encoding: .utf8)

        let vertexLine = """
        {"type":"assistant","sessionId":"sess-vertex-2","cwd":"/tmp/vertex-dedup","timestamp":"\(iso)",\
        "requestId":"req_vrtx_2","metadata":{"provider":"vertex"},\
        "message":{"id":"msg_vrtx_2","model":"claude-sonnet-4-6",\
        "usage":{"input_tokens":400,"output_tokens":100}}}
        """
        _ = try env.writeClaudeProjectFile(
            relativePath: "vertex-dedup/sess-vertex-2.jsonl",
            contents: vertexLine + "\n")

        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "filter" }?.value ?? ""
            let body = if filter.contains("online_serving/token_count") {
                """
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
                        {"interval": {"startTime": "2026-11-25T12:00:00Z"}, "value": {"int64Value": "99999"}}
                      ]
                    },
                    {
                      "metric": {"labels": {"type": "input", "request_type": "shared"}},
                      "resource": {
                        "labels": {
                          "location": "us-central1",
                          "publisher": "google",
                          "model_user_id": "gemini-2.5-pro"
                        }
                      },
                      "points": [
                        {"interval": {"startTime": "2026-11-25T13:00:00Z"}, "value": {"int64Value": "1000"}}
                      ]
                    }
                  ]
                }
                """
            } else {
                #"{"timeSeries":[]}"#
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }

        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let testEnv = [
            "CLOUDSDK_CONFIG": gcloudDir.path,
            "GOOGLE_CLOUD_PROJECT": "vertex-dedup-proj",
        ]

        // Auto mode: Cloud Monitoring totals are authoritative across all publishers (99,999 Anthropic + 1,000 Gemini
        // = 100,999 tokens) so a 500-token local session never drops cloud traffic from other sessions, machines, or
        // days. Local project/session breakdowns stay attached separately.
        let autoSnapshot = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: testEnv,
            vertexAISettings: VertexAIProviderSettings(
                telemetryCostSource: .auto,
                allowClaudeFallback: false,
                estimateCloudCost: false),
            vertexAITransport: transport,
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot
        #expect(autoSnapshot.last30DaysTokens == 100_999)
        #expect(autoSnapshot.projects.map(\.path) == ["/tmp/vertex-dedup"])
        #expect(autoSnapshot.sessions.map(\.sessionID) == ["sess-vertex-2"])

        // CloudMonitoringOnly mode with estimateCloudCost == false keeps costUSD nil and provenance unknown.
        let cloudTokensOnly = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: testEnv,
            vertexAISettings: VertexAIProviderSettings(
                telemetryCostSource: .cloudMonitoringOnly,
                estimateCloudCost: false),
            vertexAITransport: transport,
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot
        #expect(cloudTokensOnly.last30DaysTokens == 100_999)
        #expect(cloudTokensOnly.last30DaysCostUSD == nil)
        #expect(cloudTokensOnly.costProvenance == .unknown)
        #expect(cloudTokensOnly.projects.isEmpty)

        // CloudMonitoringOnly mode with estimateCloudCost == true computes estimated USD cost and sets historyLabel.
        let cloudEstimated = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: testEnv,
            vertexAISettings: VertexAIProviderSettings(
                telemetryCostSource: .cloudMonitoringOnly,
                estimateCloudCost: true),
            vertexAITransport: transport,
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot
        #expect((cloudEstimated.last30DaysCostUSD ?? 0) > 0)
        #expect(cloudEstimated.costProvenance == .listPriceEstimate)
        #expect(cloudEstimated.historyLabel == "Last 30 days (Cloud est.)")
    }

    @Test
    func `vertexai online serving summary and cost snapshot surface per-model tokens costs and totals`() async throws {
        let now = Date(timeIntervalSince1970: 1_795_653_000)
        let isoNow = ISO8601DateFormatter().string(from: now)

        let claudeLabels =
            #""location":"us-east5","publisher":"anthropic","model_user_id":"claude-sonnet-4-5@20250929""#
        let geminiLabels = #""location":"us-central1","publisher":"google","model_user_id":"gemini-2.5-pro""#
        let invocationJSON = """
        {"timeSeries":[
          {"metric":{"labels":{"request_type":"shared"}},
           "resource":{"labels":{\(claudeLabels)}},
           "points":[{"interval":{"endTime":"\(isoNow)"},"value":{"int64Value":"10"}}]},
          {"metric":{"labels":{"request_type":"dedicated"}},
           "resource":{"labels":{\(geminiLabels)}},
           "points":[{"interval":{"endTime":"\(isoNow)"},"value":{"int64Value":"4"}}]}
        ]}
        """
        let tokenJSON = """
        {"timeSeries":[
          {"metric":{"labels":{"type":"input","request_type":"shared"}},
           "resource":{"labels":{\(claudeLabels)}},
           "points":[{"interval":{"endTime":"\(isoNow)"},"value":{"int64Value":"100000"}}]},
          {"metric":{"labels":{"type":"output","request_type":"shared"}},
           "resource":{"labels":{\(claudeLabels)}},
           "points":[{"interval":{"endTime":"\(isoNow)"},"value":{"int64Value":"20000"}}]},
          {"metric":{"labels":{"type":"input","request_type":"dedicated"}},
           "resource":{"labels":{\(geminiLabels)}},
           "points":[{"interval":{"endTime":"\(isoNow)"},"value":{"int64Value":"50000"}}]}
        ]}
        """

        let decoder = JSONDecoder()
        let invocationSeries = try decoder.decode(
            VertexAIUsageFetcher.MonitoringTimeSeriesResponse.self,
            from: Data(invocationJSON.utf8)).timeSeries ?? []
        let tokenSeries = try decoder.decode(
            VertexAIUsageFetcher.MonitoringTimeSeriesResponse.self,
            from: Data(tokenJSON.utf8)).timeSeries ?? []

        let summary = try #require(VertexAIUsageFetcher.makeOnlineServingSummary(
            invocationSeries: invocationSeries,
            tokenSeries: tokenSeries,
            options: VertexAIQueryOptions(estimateServingCost: true),
            pricingDate: now))
        #expect(summary.totalTokens == 170_000)
        #expect(summary.sharedTokens == 120_000)
        #expect(summary.dedicatedTokens == 50000)
        #expect(summary.hasUnpricedTokens)
        let totalCost = try #require(summary.estimatedCostUSD)
        #expect(totalCost > 0)

        let claudeModel = try #require(summary.models.first { $0.modelUserID.contains("claude-sonnet-4-5") })
        #expect(claudeModel.totalTokens == 120_000)
        #expect(claudeModel.estimatedCostUSD == totalCost)

        let dedicatedModel = try #require(summary.models.first { $0.modelUserID == "gemini-2.5-pro" })
        #expect(dedicatedModel.totalTokens == 50000)
        #expect(dedicatedModel.estimatedCostUSD == nil)

        // Verify CostUsageTokenSnapshot daily modelBreakdowns and CLI breakdown rendering.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vertex-per-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let adcURL = dir.appendingPathComponent("application_default_credentials.json")
        try """
        {
          "client_id": "cid",
          "client_secret": "csecret",
          "refresh_token": "rtoken",
          "access_token": "tok",
          "token_expiry": "2099-01-01T00:00:00Z"
        }
        """.write(to: adcURL, atomically: true, encoding: .utf8)

        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "filter" })?.value ?? ""
            let body = if filter.contains("online_serving/token_count") {
                tokenJSON
            } else if filter.contains("online_serving/model_invocation_count") {
                invocationJSON
            } else {
                #"{"timeSeries":[]}"#
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }

        var options = CostUsageScanner.Options()
        options.claudeProjectsRoots = [dir.appendingPathComponent("empty-projects", isDirectory: true)]
        options.cacheRoot = dir.appendingPathComponent("cache", isDirectory: true)
        options.calendar = Calendar(identifier: .gregorian)
        options.calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        let snapshot = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: ["CLOUDSDK_CONFIG": dir.path, "GOOGLE_CLOUD_PROJECT": "proj-models"],
            vertexAISettings: VertexAIProviderSettings(
                telemetryCostSource: .cloudMonitoringOnly,
                estimateCloudCost: true),
            vertexAITransport: transport,
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot

        #expect(snapshot.sessionTokens == 170_000)
        #expect(snapshot.last30DaysTokens == 170_000)
        let snapCost = try #require(snapshot.last30DaysCostUSD)
        #expect(abs(snapCost - totalCost) < 1e-9)
        #expect(snapshot.sessionCostUSD == snapshot.last30DaysCostUSD)

        let breakdowns = try #require(snapshot.daily.first?.modelBreakdowns)
        #expect(breakdowns.count == 2)
        let claudeBreakdown = try #require(breakdowns.first { $0.modelName == "claude-sonnet-4-5" })
        #expect(claudeBreakdown.totalTokens == 120_000)
        #expect(abs((claudeBreakdown.costUSD ?? 0) - totalCost) < 1e-9)
        let geminiBreakdown = try #require(breakdowns.first { $0.modelName == "gemini-2.5-pro" })
        #expect(geminiBreakdown.totalTokens == 50000)
        #expect(geminiBreakdown.costUSD == nil)

        let cliOutput = CodexBarCLI.renderCostText(
            provider: .vertexai,
            snapshot: snapshot,
            useColor: false,
            calendar: options.calendar,
            includeBreakdown: true)
        #expect(cliOutput.contains("Top models"))
        #expect(cliOutput.contains("claude-sonnet-4-5"))
        #expect(cliOutput.contains("$0.60 · 120K tokens"))
        #expect(cliOutput.contains("gemini-2.5-pro"))
        #expect(cliOutput.contains("50K tokens"))
        #expect(cliOutput.contains("170K tokens"))
    }

    @Test
    func `cloud reporting window starts at calendar midnight for 1-day and multi-day windows`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let gcloudDir = env.root.appendingPathComponent("gcloud-window", isDirectory: true)
        try FileManager.default.createDirectory(at: gcloudDir, withIntermediateDirectories: true)
        try """
        {
          "client_id": "cid",
          "client_secret": "csecret",
          "refresh_token": "rtoken",
          "access_token": "valid-token",
          "token_expiry": "2099-01-01T00:00:00Z"
        }
        """.write(
            to: gcloudDir.appendingPathComponent("application_default_credentials.json"),
            atomically: true,
            encoding: .utf8)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 25, hour: 15, minute: 30, second: 0)))

        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"timeSeries":[]}"#.utf8), response)
        }

        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            calendar: calendar)
        let testEnv = [
            "CLOUDSDK_CONFIG": gcloudDir.path,
            "GOOGLE_CLOUD_PROJECT": "vertex-window-proj",
        ]
        let formatter = ISO8601DateFormatter()

        _ = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: testEnv,
            vertexAISettings: VertexAIProviderSettings(telemetryCostSource: .cloudMonitoringOnly),
            vertexAITransport: transport,
            now: now,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            scannerOptions: options)

        let oneDayRequests = await transport.requests()
        #expect(!oneDayRequests.isEmpty)
        let expectedOneDayStart = formatter.string(from: calendar.startOfDay(for: now))
        let expectedEnd = formatter.string(from: now)
        for request in oneDayRequests {
            let url = try #require(request.url)
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(query.first { $0.name == "interval.startTime" }?.value == expectedOneDayStart)
            #expect(query.first { $0.name == "interval.endTime" }?.value == expectedEnd)
        }

        let multiDayTransport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"timeSeries":[]}"#.utf8), response)
        }

        _ = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: testEnv,
            vertexAISettings: VertexAIProviderSettings(telemetryCostSource: .cloudMonitoringOnly),
            vertexAITransport: multiDayTransport,
            now: now,
            forceRefresh: true,
            historyDays: 7,
            allowPricingRefresh: false,
            scannerOptions: options)

        let sevenDayRequests = await multiDayTransport.requests()
        #expect(!sevenDayRequests.isEmpty)
        let expectedSevenDayStartDate = try #require(calendar.date(
            byAdding: .day,
            value: -6,
            to: calendar.startOfDay(for: now)))
        let expectedSevenDayStart = formatter.string(from: expectedSevenDayStartDate)
        for request in sevenDayRequests {
            let url = try #require(request.url)
            let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(query.first { $0.name == "interval.startTime" }?.value == expectedSevenDayStart)
            #expect(query.first { $0.name == "interval.endTime" }?.value == expectedEnd)
        }
    }

    @Test
    func `auto mode distinguishes cloud failure from confirmed-empty history`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 11, day: 25)

        let gcloudDir = env.root.appendingPathComponent("gcloud-failure", isDirectory: true)
        try FileManager.default.createDirectory(at: gcloudDir, withIntermediateDirectories: true)
        try """
        {
          "client_id": "cid",
          "client_secret": "csecret",
          "refresh_token": "rtoken",
          "access_token": "valid-token",
          "token_expiry": "2099-01-01T00:00:00Z"
        }
        """.write(
            to: gcloudDir.appendingPathComponent("application_default_credentials.json"),
            atomically: true,
            encoding: .utf8)

        let failingTransport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
            return (Data(#"{"error":{"code":503}}"#.utf8), response)
        }
        let emptyTransport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"timeSeries":[]}"#.utf8), response)
        }

        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let testEnv = [
            "CLOUDSDK_CONFIG": gcloudDir.path,
            "GOOGLE_CLOUD_PROJECT": "vertex-failure-proj",
        ]

        let failedSnapshot = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: testEnv,
            vertexAISettings: VertexAIProviderSettings(telemetryCostSource: .auto),
            vertexAITransport: failingTransport,
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot
        #expect(failedSnapshot.daily.isEmpty)
        #expect(!failedSnapshot.historyCoverageIsEstablished)

        let confirmedEmptySnapshot = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: testEnv,
            vertexAISettings: VertexAIProviderSettings(telemetryCostSource: .auto),
            vertexAITransport: emptyTransport,
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot
        #expect(confirmedEmptySnapshot.daily.isEmpty)
        #expect(confirmedEmptySnapshot.historyCoverageIsEstablished)
    }

    @Test
    func `invocation-only buckets preserve unknown tokens when token_count query fails`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 11, day: 25)
        let isoNow = ISO8601DateFormatter().string(from: now)

        let gcloudDir = env.root.appendingPathComponent("gcloud-partial", isDirectory: true)
        try FileManager.default.createDirectory(at: gcloudDir, withIntermediateDirectories: true)
        try """
        {
          "client_id": "cid",
          "client_secret": "csecret",
          "refresh_token": "rtoken",
          "access_token": "valid-token",
          "token_expiry": "2099-01-01T00:00:00Z"
        }
        """.write(
            to: gcloudDir.appendingPathComponent("application_default_credentials.json"),
            atomically: true,
            encoding: .utf8)

        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "filter" }?.value ?? ""
            if filter.contains("online_serving/token_count") {
                let response = try #require(HTTPURLResponse(
                    url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
                return (Data(#"{"error":{"code":503}}"#.utf8), response)
            }
            let body = """
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
                  "points": [
                    {"interval": {"endTime": "\(isoNow)"}, "value": {"int64Value": "12"}}
                  ]
                }
              ]
            }
            """
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }

        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        let testEnv = [
            "CLOUDSDK_CONFIG": gcloudDir.path,
            "GOOGLE_CLOUD_PROJECT": "vertex-partial-proj",
        ]

        let snapshot = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: testEnv,
            vertexAISettings: VertexAIProviderSettings(
                telemetryCostSource: .cloudMonitoringOnly,
                estimateCloudCost: true),
            vertexAITransport: transport,
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot

        #expect(snapshot.historyScanIsPartial)
        #expect(snapshot.last30DaysTokens == nil)
        let day = try #require(snapshot.daily.first)
        #expect(day.totalTokens == nil)
        #expect(day.inputTokens == nil)
        #expect(day.outputTokens == nil)
        #expect(day.requestCount == 12)
        let hourly = try #require(snapshot.hourly.first)
        #expect(hourly.totalTokens == nil)
        #expect(!hourly.tokensAreComplete)
    }

    @Test
    func `auto mode still loads cloud history when optional local scan fails`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let now = try env.makeLocalNoon(year: 2026, month: 11, day: 25)
        let isoNow = ISO8601DateFormatter().string(from: now)

        let gcloudDir = env.root.appendingPathComponent("gcloud-local-fail", isDirectory: true)
        try FileManager.default.createDirectory(at: gcloudDir, withIntermediateDirectories: true)
        try """
        {
          "client_id": "cid",
          "client_secret": "csecret",
          "refresh_token": "rtoken",
          "access_token": "valid-token",
          "token_expiry": "2099-01-01T00:00:00Z"
        }
        """.write(
            to: gcloudDir.appendingPathComponent("application_default_credentials.json"),
            atomically: true,
            encoding: .utf8)

        // Create an unreadable directory to force local Claude root inventory failure.
        let unreadableDir = env.root.appendingPathComponent("unreadable-claude", isDirectory: true)
        try FileManager.default.createDirectory(at: unreadableDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableDir.path)
        }

        let labels = #""location":"us-central1","publisher":"google","model_user_id":"gemini-2.5-pro""#
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let filter = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "filter" }?.value ?? ""
            let body = if filter.contains("online_serving/token_count") {
                """
                {"timeSeries":[
                  {"metric":{"labels":{"type":"input","request_type":"shared"}},
                   "resource":{"labels":{\(labels)}},
                   "points":[{"interval":{"endTime":"\(isoNow)"},"value":{"int64Value":"1000"}}]}
                ]}
                """
            } else {
                """
                {"timeSeries":[
                  {"metric":{"labels":{"request_type":"shared"}},
                   "resource":{"labels":{\(labels)}},
                   "points":[{"interval":{"endTime":"\(isoNow)"},"value":{"int64Value":"4"}}]}
                ]}
                """
            }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        }

        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [unreadableDir],
            cacheRoot: env.cacheRoot)
        let testEnv = [
            "CLOUDSDK_CONFIG": gcloudDir.path,
            "GOOGLE_CLOUD_PROJECT": "vertex-cloud-ok-proj",
        ]

        let snapshot = try await CostUsageFetcher.loadTokenResult(
            provider: .vertexai,
            environment: testEnv,
            vertexAISettings: VertexAIProviderSettings(telemetryCostSource: .auto),
            vertexAITransport: transport,
            now: now,
            forceRefresh: true,
            allowPricingRefresh: false,
            scannerOptions: options).snapshot

        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysTokens == 1000)
        #expect(!snapshot.detailsAreComplete)
    }
}
