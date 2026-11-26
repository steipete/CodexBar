import Foundation
import Testing
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
    func `auto telemetry mode deduplicates anthropic cloud series when local Vertex logs exist`() async throws {
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

        // Auto mode: local Claude-on-Vertex (500 tokens) + non-Anthropic Cloud Gemini (1000 tokens) = 1500 tokens.
        // The 99,999 Anthropic cloud tokens are deduplicated!
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
        #expect(autoSnapshot.last30DaysTokens == 1500)
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
}
