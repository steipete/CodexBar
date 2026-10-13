import Foundation
import Testing
@testable import CodexBarCore

struct OpenAILiveUsageTests {
    private static let now = Date(timeIntervalSince1970: 120_025)
    private static let environment = ["OPENAI_ADMIN_KEY": "test-admin-key", "OPENAI_PROJECT_ID": "proj_&test"]

    @Test
    func `requests use minute buckets model grouping project scope and pagination`() async throws {
        let transport = Transport(pages: [
            Self.page("", more: true, cursor: "next & page"),
            Self.page(""),
        ])
        let result = try await OpenAILiveUsageFetcher(transport: transport).fetch(
            environment: Self.environment, windowMinutes: 15, now: Self.now)
        let requests = await transport.requests
        #expect(requests.count == 2)
        for (index, request) in requests.enumerated() {
            let url = try #require(request.url)
            #expect(url.scheme == "https")
            #expect(url.host == "api.openai.com")
            #expect(url.path == "/v1/organization/usage/completions")
            let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            var expected = [
                "start_time": "119160", "end_time": "120025", "bucket_width": "1m",
                "limit": "15", "project_ids": "proj_&test",
            ]
            if index == 1 { expected["page"] = "next & page" }
            #expect(items.filter { $0.name == "group_by" }.map(\.value) == ["model", "batch"])
            #expect(Array(items.prefix(6).map(\.name)) == [
                "start_time", "end_time", "bucket_width", "group_by", "group_by", "limit",
            ])
            #expect(Dictionary(uniqueKeysWithValues: items.filter { $0.name != "group_by" }
                    .map { ($0.name, $0.value ?? "") }) == expected)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-admin-key")
            #expect(request.timeoutInterval == 20)
        }
        #expect(result.projectID == "proj_&test")
        #expect(result.minutes.count == 15)
        #expect(result.minutes.first?.start == Date(timeIntervalSince1970: 119_160))
        #expect(result.minutes.last?.start == Date(timeIntervalSince1970: 120_000))
    }

    @Test
    func `parsing merges pages floors buckets drops outside minutes and defaults counts`() async throws {
        let transport = Transport(pages: [
            Self.page(
                """
                {"start_time":119947,"results":[
                  {"model":"model-a","input_tokens":100,"input_cached_tokens":20,
                   "output_tokens":50,"num_model_requests":2},
                  {"model":"model-b","output_tokens":30}, {"model":null}, {"model":""}]},
                {"start_time":119100,"results":[{"input_tokens":999}]},
                {"start_time":120060,"results":[{"input_tokens":999}]}
                """,
                more: true,
                cursor: "two"),
            Self.page("""
            {"start_time":119940,"results":[{"model":"model-a","input_tokens":5,"output_tokens":5}]},
            {"start_time":120000,"results":[{"model":"model-a","input_tokens":500}]}
            """),
        ])
        let result = try await OpenAILiveUsageFetcher(transport: transport).fetch(
            environment: Self.environment, windowMinutes: 15, now: Self.now)
        #expect(result.modelNames == ["model-a", "model-b", "unknown"])
        let all = result.series(for: .allModels)
        #expect(all.count == 15)
        #expect(all.prefix(13).allSatisfy { $0.totalTokens == 0 })
        #expect(all[13].totalTokens == 190)
        #expect(all[13].uncachedInputTokens == 85)
        #expect(all[13].cachedInputTokens == 20)
        #expect(all[13].outputTokens == 85)
        #expect(all[13].requests == 2)
        #expect(!all[13].isInProgress)
        #expect(all[14].isInProgress)
        #expect(result.series(for: .model("model-b"))[13].totalTokens == 30)
        #expect(result.series(for: .model("absent")).allSatisfy { $0.totalTokens == 0 })
        let summary = result.summary(for: .allModels)
        #expect(summary.latestTPM == 190)
        #expect(summary.latestMinuteStart == all[13].start)
        #expect(summary.fiveMinuteAverageTPM == 38)
        // The in-progress minute's partial 500 tokens count toward totals but never become the peak.
        #expect(summary.peakTPM == 190)
        #expect(summary.peakMinuteStart == all[13].start)
        #expect(summary.totalTokens == 690)
        #expect(summary.inputTokens == 605)
        #expect(summary.cachedInputTokens == 20)
        #expect(summary.outputTokens == 85)
        #expect(summary.requests == 2)
        #expect(result.modelRows.first == .init(
            name: "model-a", latestTPM: 160, peakTPM: 160, totalTokens: 660, requests: 2))
    }

    @Test
    func `model ordering breaks ties by name and stacking keeps five models plus Other`() async throws {
        let entries = (1...7).map { "{\"model\":\"model-\($0)\",\"input_tokens\":\($0) }" }.joined(separator: ",")
        let transport = Transport(pages: [Self.page("{\"start_time\":119940,\"results\":[\(entries)]}")])
        let snapshot = try await OpenAILiveUsageFetcher(transport: transport).fetch(
            environment: Self.environment, windowMinutes: 15, now: Self.now)
        #expect(snapshot.modelNames == ["model-7", "model-6", "model-5", "model-4", "model-3", "model-2", "model-1"])
        let stacks = snapshot.stackedByModel()
        #expect(stacks.count == 15 * 6)
        #expect(stacks.filter { $0.modelOrOther == "Other" }.reduce(0) { $0 + $1.tokens } == 3)
        #expect(stacks.reduce(0) { $0 + $1.tokens } == snapshot.summary(for: .allModels).totalTokens)
        let tied = OpenAILiveUsageSnapshot(
            minutes: [.init(start: Self.now, models: [
                .init(name: "z", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, requests: 0),
                .init(name: "a", inputTokens: 1, cachedInputTokens: 0, outputTokens: 0, requests: 0),
            ])],
            windowMinutes: 15,
            fetchedAt: Self.now,
            projectID: nil)
        #expect(tied.modelNames == ["a", "z"])
    }

    @Test(arguments: [401, 403, 429, 500])
    func `HTTP errors map to actionable typed errors`(status: Int) async {
        let transport = Transport(pages: ["{}"], status: status)
        let expected: OpenAILiveUsageError = switch status {
        case 401, 403: .adminKeyRequired
        case 429: .rateLimited
        default: .apiFailure(status)
        }
        await #expect(throws: expected) {
            try await OpenAILiveUsageFetcher(transport: transport).fetch(environment: Self.environment, now: Self.now)
        }
    }

    @Test(arguments: [
        "not json", "{}", "{\"data\":null}",
        "{\"data\":[{\"results\":[]}]}",
        "{\"data\":[{\"start_time\":120000}]}",
        "{\"data\":[{\"start_time\":120000,\"results\":[{\"input_tokens\":-1}]}]}",
        "{\"data\":[{\"start_time\":120000,\"results\":[{\"output_tokens\":1.5}]}]}",
        "{\"data\":[{\"start_time\":120000,\"results\":[{\"num_model_requests\":true}]}]}",
        "{\"data\":[{\"start_time\":120000,\"results\":[{\"input_audio_tokens\":-1}]}]}",
        "{\"data\":[{\"start_time\":120000,\"results\":[{\"input_tokens\":9223372036854775807,\"output_tokens\":1}]}]}",
    ])
    func `malformed responses and invalid counts are parse errors`(body: String) async {
        await #expect(throws: OpenAILiveUsageError.parseFailure) {
            try await OpenAILiveUsageFetcher(transport: Transport(pages: [body])).fetch(
                environment: Self.environment, now: Self.now)
        }
    }

    @Test
    func `pagination rejects missing repeated and excessive cursors`() async {
        for pages in [
            [Self.page("", more: true)],
            Array(repeating: Self.page("", more: true, cursor: "same"), count: 2),
            (0..<20).map { Self.page("", more: true, cursor: "page-\($0)") },
        ] {
            let transport = Transport(pages: pages)
            await #expect(throws: OpenAILiveUsageError.parseFailure) {
                try await OpenAILiveUsageFetcher(transport: transport).fetch(
                    environment: Self.environment,
                    now: Self.now)
            }
            #expect(await transport.requests.count <= 20)
        }
    }

    @Test
    func `missing credentials and unsupported ranges never request the network`() async {
        let transport = Transport(pages: [])
        let fetcher = OpenAILiveUsageFetcher(transport: transport)
        await #expect(throws: OpenAILiveUsageError.missingCredential) {
            try await fetcher.fetch(environment: [:])
        }
        await #expect(throws: OpenAILiveUsageError.invalidWindow) {
            try await fetcher.fetch(environment: Self.environment, windowMinutes: 30)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test(arguments: [15, 60, 360])
    func `unscoped empty windows include exact ascending grids`(minutes: Int) async throws {
        let transport = Transport(pages: [Self.page("")])
        let snapshot = try await OpenAILiveUsageFetcher(transport: transport).fetch(
            environment: ["OPENAI_API_KEY": "test-key"], windowMinutes: minutes, now: Self.now)
        #expect(snapshot.minutes.count == minutes)
        #expect(snapshot.projectID == nil)
        #expect(snapshot.summary(for: .allModels).totalTokens == 0)
        #expect(snapshot.summary(for: .allModels).fiveMinuteAverageTPM == 0)
        #expect(snapshot.minutes.map(\.start) == snapshot.minutes.map(\.start).sorted())
        #expect(snapshot.series(for: .allModels).filter(\.isInProgress).count == 1)
        let request = try #require(await transport.requests.first)
        let url = try #require(request.url)
        #expect(!url.absoluteString.contains("project_ids"))
    }

    @Test
    func `reporting frontier skips lagging trailing zeros across all models`() {
        let snapshot = Self.frontierSnapshot(activeMinutes: [8: ("model-a", 80), 11: ("model-b", 110)])
        #expect(snapshot.reportingFrontier == snapshot.minutes[11].start)
        #expect(snapshot.summary(for: .allModels).latestTPM == 110)
        #expect(snapshot.series(for: .allModels).filter(\.isPending).map(\.start) ==
            snapshot.minutes.suffix(3).map(\.start))
        #expect(snapshot.stackedByModel().filter(\.isPending).count == 6)
    }

    @Test
    func `peaks ignore partial minutes after the reporting frontier`() {
        // Minute 14 is still in progress at `now`, so its partial bucket is pending.
        let snapshot = Self.frontierSnapshot(activeMinutes: [8: ("model-a", 80), 14: ("model-a", 900)])
        #expect(snapshot.reportingFrontier == snapshot.minutes[8].start)
        let summary = snapshot.summary(for: .allModels)
        #expect(summary.peakTPM == 80)
        #expect(summary.peakMinuteStart == snapshot.minutes[8].start)
        let limits = OpenAIOrgLimitResolver(
            manual: [.init(model: "model-a", tokensPerMinute: 1000, requestsPerMinute: 10)],
            projectCaps: nil)
        let utilization = snapshot.utilization(for: .model("model-a"), limits: limits)
        #expect(utilization?.peakTPMPercent == 8)
        #expect(utilization?.peakRPMPercent == 10)
        #expect(snapshot.throughput.peakTokensPerMinute == 80)
        #expect(snapshot.throughput.models.first?.peakLimitCountedTokens == 80)
    }

    @Test
    func `model ranking ignores pending-only volume for the top series`() {
        // Six models report at minute 8; a seventh only has a large partial bucket in the in-progress minute.
        var active: [Int: [(String, Int)]] = [8: (1...6).map { ("model-\($0)", 100 - $0) }]
        active[14] = [("pending-model", 10000)]
        let snapshot = OpenAILiveUsageSnapshot(
            minutes: (0..<15).map { index in
                .init(
                    start: Date(timeIntervalSince1970: 119_160 + Double(index) * 60),
                    models: (active[index] ?? []).map { name, tokens in
                        .init(name: name, inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0, requests: 1)
                    })
            },
            windowMinutes: 15,
            fetchedAt: Self.now,
            projectID: nil)
        #expect(snapshot.modelNames.prefix(5) == ["model-1", "model-2", "model-3", "model-4", "model-5"])
        #expect(snapshot.modelNames.last == "pending-model")
        let topSeries = Set(snapshot.stackedByModel().map(\.modelOrOther))
        #expect(topSeries.contains("model-5"))
        #expect(!topSeries.contains("pending-model"))
        #expect(snapshot.throughput.models.first?.name == "model-1")
    }

    @Test
    func `reporting frontier resets to real zeros after ten idle minutes`() {
        let snapshot = Self.frontierSnapshot(activeMinutes: [3: ("model-a", 100)])
        #expect(snapshot.reportingFrontier == snapshot.minutes[13].start)
        #expect(snapshot.summary(for: .allModels).latestTPM == 0)
        #expect(snapshot.summary(for: .allModels).fiveMinuteAverageTPM == 0)
        #expect(snapshot.series(for: .allModels).filter(\.isPending).count == 1)
        // The oldest of the ten complete minutes is still eligible.
        let boundary = Self.frontierSnapshot(activeMinutes: [4: ("model-a", 100)])
        #expect(boundary.reportingFrontier == boundary.minutes[4].start)
    }

    @Test
    func `frontier is shared across filters so an idle model reports zero`() {
        let snapshot = Self.frontierSnapshot(activeMinutes: [8: ("model-a", 80), 11: ("model-b", 110)])
        let idle = snapshot.summary(for: .model("model-a"))
        #expect(idle.latestTPM == 0)
        #expect(idle.latestMinuteStart == snapshot.minutes[11].start)
        #expect(snapshot.summary(for: .model("absent")).latestMinuteStart == idle.latestMinuteStart)
    }

    @Test
    func `five minute average ends at the reporting frontier including idle minutes`() {
        let snapshot = Self.frontierSnapshot(activeMinutes: [
            6: ("model-a", 999),
            7: ("model-a", 50),
            8: ("model-a", 100),
            11: ("model-b", 150),
        ])
        #expect(snapshot.summary(for: .allModels).fiveMinuteAverageTPM == 60)
        #expect(snapshot.summary(for: .model("model-a")).fiveMinuteAverageTPM == 30)
        #expect(snapshot.summary(for: .model("model-b")).fiveMinuteAverageTPM == 30)
        let limits = OpenAIOrgLimitResolver(manual: [.init(model: "model-b", tokensPerMinute: 300)], projectCaps: nil)
        #expect(snapshot.utilization(for: .model("model-b"), limits: limits)?.latestTPMPercent == 50)
    }

    @Test(arguments: ["true", "false", "null", "missing"])
    func `batch decoding preserves audio totals and standard defaults`(batch: String) async throws {
        let batchField = batch == "missing" ? "" : "\"batch\":\(batch),"
        let body = Self.page("""
        {"start_time":119940,"results":[{\(batchField)"model":"model-fixture",
        "input_tokens":100,"input_cached_tokens":60,"output_tokens":20,"num_model_requests":3,
        "input_audio_tokens":40,"output_audio_tokens":10}]}
        """)
        let snapshot = try await OpenAILiveUsageFetcher(transport: Transport(pages: [body])).fetch(
            environment: Self.environment, windowMinutes: 15, now: Self.now)
        let point = try #require(snapshot.series(for: .allModels).first { $0.totalTokens > 0 })
        #expect(point.totalTokens == 120)
        #expect(point.batchTokens == (batch == "true" ? 120 : 0))
        #expect(point.batchRequests == (batch == "true" ? 3 : 0))
        #expect(point.limitCountedTokens == (batch == "true" ? 0 : 120))
        #expect(point.limitCountedRequests == (batch == "true" ? 0 : 3))
    }

    @Test(arguments: ["\"yes\"", "1", "[]", "{}"])
    func `non boolean batch values are parse failures`(batch: String) async {
        let body = Self.page("{\"start_time\":119940,\"results\":[{\"batch\":\(batch)}]}")
        await #expect(throws: OpenAILiveUsageError.parseFailure) {
            try await OpenAILiveUsageFetcher(transport: Transport(pages: [body])).fetch(
                environment: Self.environment, now: Self.now)
        }
    }

    @Test(arguments: [9_007_199_254_740_991, Int.max])
    func `token sums above the safe integer range fail before batch projection`(input: Int) async {
        let body = Self.page("""
        {"start_time":119940,"results":[{"batch":true,"input_tokens":\(input),"output_tokens":1}]}
        """)
        await #expect(throws: OpenAILiveUsageError.parseFailure) {
            try await OpenAILiveUsageFetcher(transport: Transport(pages: [body])).fetch(
                environment: Self.environment, now: Self.now)
        }
    }

    @Test
    func `batch traffic stays in totals while utilization uses standard peaks`() throws {
        func row(_ input: Int, _ cached: Int, _ output: Int, _ requests: Int, batch: Bool)
            -> OpenAILiveUsageSnapshot.ModelUsage
        {
            .init(
                name: "model-fixture",
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output,
                requests: requests,
                batchTokens: batch ? input + output : 0,
                batchRequests: batch ? requests : 0)
        }
        let snapshot = try OpenAILiveUsageBuilder.build(
            buckets: [
                .init(start: Date(timeIntervalSince1970: 119_880), models: [
                    row(900, 800, 100, 90, batch: true), row(80, 70, 20, 2, batch: false),
                ]),
                .init(start: Date(timeIntervalSince1970: 119_940), models: [
                    row(40, 30, 10, 5, batch: true), row(160, 150, 40, 4, batch: false),
                    .init(
                        name: "model-second",
                        inputTokens: 90,
                        cachedInputTokens: 0,
                        outputTokens: 0,
                        requests: 1),
                ]),
            ],
            windowMinutes: 15,
            fetchedAt: Self.now,
            projectID: nil)
        let points = snapshot.series(for: .model("model-fixture")).suffix(3)
        #expect(points.map(\.totalTokens) == [1100, 250, 0])
        #expect(points.map(\.batchTokens) == [1000, 50, 0])
        #expect(points.map(\.batchRequests) == [90, 5, 0])
        #expect(points.map(\.limitCountedTokens) == [100, 200, 0])
        #expect(points.map(\.limitCountedRequests) == [2, 4, 0])
        #expect(snapshot.minutes[12].models.count == 1)
        #expect(snapshot.modelNames == ["model-fixture", "model-second"])
        #expect(snapshot.reportingFrontier == Date(timeIntervalSince1970: 119_940))
        let summary = snapshot.summary(for: .model("model-fixture"))
        #expect(summary.totalTokens == 1350)
        #expect(summary.batchTokens == 1050)
        #expect(summary.inputTokens == 1180)
        #expect(summary.cachedInputTokens == 1050)
        #expect(summary.outputTokens == 170)
        #expect(summary.requests == 101)
        #expect(summary.latestTPM == 250)
        #expect(summary.peakTPM == 1100)
        #expect(summary.peakMinuteStart == Date(timeIntervalSince1970: 119_880))
        #expect(snapshot.summary(for: .allModels).totalTokens == 1440)
        #expect(snapshot.summary(for: .allModels).batchTokens == 1050)
        #expect(snapshot.stackedByModel().reduce(0) { $0 + $1.tokens } == 1440)
        #expect(snapshot.modelRows.first?.totalTokens == 1350)
        #expect(snapshot.modelRows.first?.requests == 101)
        let limits = OpenAIOrgLimitResolver(manual: [
            .init(model: "model-fixture", tokensPerMinute: 400, requestsPerMinute: 8),
            .init(model: "model-second", tokensPerMinute: 100),
        ], projectCaps: nil)
        let utilization = try #require(snapshot.utilization(for: .model("model-fixture"), limits: limits))
        #expect(utilization.latestTPMPercent == 50)
        #expect(utilization.peakTPMPercent == 50)
        #expect(utilization.peakRPMPercent == 50)
        #expect(snapshot.modelRows(limits: limits).first?.peakTPMPercent == 50)
        #expect(snapshot.modelRows(limits: limits).first?.latestTPMPercent == 50)
        #expect(snapshot.highestUtilization(limits: limits)?.name == "model-second")
        #expect(snapshot.highestUtilization(limits: limits)?.peakTPMPercent == 90)
        #expect(snapshot.throughput.minutes.suffix(3).map(\.totalTokens) == [1100, 340, 0])
        #expect(snapshot.throughput.minutes.suffix(3).map(\.requests) == [92, 10, 0])
        #expect(snapshot.throughput.models.first?.peakTPM == 1100)
        #expect(snapshot.throughput.models.first?.peakLimitCountedTokens == 200)
    }

    @Test(arguments: [(-1, 0), (0, -1), (121, 0), (0, 4)])
    func `builder rejects invalid batch subsets`(tokens: Int, requests: Int) {
        #expect(throws: OpenAILiveUsageError.parseFailure) {
            try OpenAILiveUsageBuilder.build(
                buckets: [
                    .init(start: Self.now.addingTimeInterval(-85), models: [
                        .init(
                            name: "model-fixture",
                            inputTokens: 100,
                            cachedInputTokens: 60,
                            outputTokens: 20,
                            requests: 3,
                            batchTokens: tokens,
                            batchRequests: requests),
                    ]),
                ],
                windowMinutes: 15,
                fetchedAt: Self.now,
                projectID: nil)
        }
    }

    private static func frontierSnapshot(activeMinutes: [Int: (String, Int)]) -> OpenAILiveUsageSnapshot {
        .init(
            minutes: (0..<15).map { index in
                .init(
                    start: Date(timeIntervalSince1970: 119_160 + Double(index) * 60),
                    models: activeMinutes[index].map { name, tokens in
                        [.init(name: name, inputTokens: tokens, cachedInputTokens: 0, outputTokens: 0, requests: 1)]
                    } ?? [])
            },
            windowMinutes: 15,
            fetchedAt: self.now,
            projectID: nil)
    }

    private static func page(_ buckets: String, more: Bool = false, cursor: String? = nil) -> String {
        let next = cursor.map { "\"\($0)\"" } ?? "null"
        return "{\"data\":[\(buckets)],\"has_more\":\(more),\"next_page\":\(next),\"unknown\":true}"
    }

    private actor Transport: ProviderHTTPTransport {
        let pages: [String]
        let status: Int
        var requests: [URLRequest] = []

        init(pages: [String], status: Int = 200) {
            self.pages = pages
            self.status = status
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let index = self.requests.count
            self.requests.append(request)
            let page = self.pages.indices.contains(index) ? self.pages[index] : "{}"
            return (Data(page.utf8), HTTPURLResponse(
                url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!)
        }
    }
}
