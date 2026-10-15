import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct OpenAIOrgRateLimitsTests {
    private static let now = Date(timeIntervalSince1970: 120_025)
    private static let environment = ["OPENAI_ADMIN_KEY": "test-admin", "OPENAI_PROJECT_ID": "proj_scoped"]

    @Test
    func `organization discovery paginates both endpoints and ignores project scoping`() async throws {
        let transport = Transport(pages: [
            Self.page(
                #"{"id":"proj_a","status":"active"},{"id":"proj_archived","status":"archived"}"#,
                more: true,
                cursor: "proj_page & 2"),
            Self.page(#"{"id":"proj_b","status":"active"}"#),
            Self.page(Self.limit("gpt-5", tpm: 100, rpm: 20), more: true, cursor: "rl_next"),
            Self.page(Self.limit("gpt-4o-mini", tpm: 50, rpm: 5)),
            Self.page(Self.limit("gpt-5", tpm: 200, rpm: 10)),
        ])
        let result = try await OpenAIOrgRateLimitsFetcher(transport: transport).fetch(
            environment: Self.environment, now: Self.now)
        #expect(result.projectsSampled == 2)
        #expect(!result.truncated)
        #expect(result.fetchedAt == Self.now)
        #expect(result.byModel["gpt-5"] == .init(tokensPerMinute: 200, requestsPerMinute: 20))
        #expect(result.byModel["gpt-4o-mini"] == .init(tokensPerMinute: 50, requestsPerMinute: 5))
        let requests = await transport.requests
        #expect(requests.count == 5)
        #expect(requests.compactMap(\.url).map(\.path) == [
            "/v1/organization/projects", "/v1/organization/projects",
            "/v1/organization/projects/proj_a/rate_limits", "/v1/organization/projects/proj_a/rate_limits",
            "/v1/organization/projects/proj_b/rate_limits",
        ])
        for (index, request) in requests.enumerated() {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-admin")
            #expect(request.timeoutInterval == 20)
            let url = try #require(request.url)
            #expect(url.host == "api.openai.com")
            let query = Dictionary(uniqueKeysWithValues:
                (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map {
                    ($0.name, $0.value ?? "")
                })
            var expected = ["limit": "100"]
            if index == 1 { expected["after"] = "proj_page & 2" }
            if index == 3 { expected["after"] = "rl_next" }
            #expect(query == expected)
        }
    }

    @Test
    func `projects without a status are treated as active`() async throws {
        let transport = Transport(pages: [
            Self.page(#"{"id":"proj_a"},{"id":"proj_b","status":null},{"id":"proj_c","status":"archived"}"#),
            Self.page(Self.limit("gpt-5", tpm: 100, rpm: 2)),
            Self.page(Self.limit("gpt-5", tpm: 300, rpm: 4)),
        ])
        let result = try await OpenAIOrgRateLimitsFetcher(transport: transport).fetch(
            environment: Self.environment, now: Self.now)
        #expect(result.projectsSampled == 2)
        #expect(result.byModel["gpt-5"] == .init(tokensPerMinute: 300, requestsPerMinute: 4))
    }

    @Test
    func `project sample truncates at twenty five active projects`() async throws {
        let projects = (0..<30).map { #"{"id":"proj_\#($0)","status":"active"}"# }.joined(separator: ",")
        let transport = Transport(pages: [Self.page(projects)] + Array(repeating: Self.page(""), count: 25))
        let result = try await OpenAIOrgRateLimitsFetcher(transport: transport).fetch(environment: Self.environment)
        #expect(result.projectsSampled == 25)
        #expect(result.truncated)
        #expect(await transport.requests.count == 26)
    }

    @Test
    func `exactly twenty five complete projects is not truncated`() async throws {
        let projects = (0..<25).map { #"{"id":"proj_\#($0)","status":"active"}"# }.joined(separator: ",")
        let transport = Transport(pages: [Self.page(projects)] + Array(repeating: Self.page(""), count: 25))
        let result = try await OpenAIOrgRateLimitsFetcher(transport: transport).fetch(environment: Self.environment)
        #expect(!result.truncated)
    }

    @Test(arguments: [
        "not json",
        "{}",
        #"{"data":[],"has_more":true}"#,
        #"{"data":[{"id":"proj_a"}],"has_more":false}"#,
    ])
    func `malformed project responses fail parsing`(page: String) async {
        await #expect(throws: OpenAIOrgRateLimitsError.parseFailure) {
            try await OpenAIOrgRateLimitsFetcher(transport: Transport(pages: [page])).fetch(
                environment: Self.environment)
        }
    }

    @Test
    func `rows without token or request limits are tolerated`() async throws {
        let rows = [
            #"{"model":"gpt-5","max_tokens_per_1_minute":100}"#,
            #"{"model":"gpt-5","max_tokens_per_1_minute":80,"max_requests_per_1_minute":3}"#,
            #"{"model":"sora-2","max_requests_per_1_minute":5}"#,
            #"{"model":"gpt-4o","max_tokens_per_1_minute":0,"max_requests_per_1_minute":0}"#,
        ].joined(separator: ",")
        let result = try await OpenAIOrgRateLimitsFetcher(transport: Transport(pages: [
            Self.page(#"{"id":"proj_a","status":"active"}"#), Self.page(rows),
        ])).fetch(environment: Self.environment)
        #expect(result.byModel == ["gpt-5": .init(tokensPerMinute: 100, requestsPerMinute: 3)])
    }

    @Test(arguments: [
        #"{"max_tokens_per_1_minute":100,"max_requests_per_1_minute":2}"#,
        #"{"model":"","max_tokens_per_1_minute":100,"max_requests_per_1_minute":2}"#,
        #"{"model":"gpt-5","max_tokens_per_1_minute":-1,"max_requests_per_1_minute":2}"#,
        #"{"model":"gpt-5","max_tokens_per_1_minute":1.5,"max_requests_per_1_minute":2}"#,
        #"{"model":"gpt-5","max_tokens_per_1_minute":100,"max_requests_per_1_minute":-2}"#,
    ])
    func `required rate limit fields are validated`(row: String) async {
        await #expect(throws: OpenAIOrgRateLimitsError.parseFailure) {
            try await OpenAIOrgRateLimitsFetcher(transport: Transport(pages: [
                Self.page(#"{"id":"proj_a","status":"active"}"#), Self.page(row),
            ])).fetch(environment: Self.environment)
        }
    }

    @Test
    func `repeated and excessive cursors are rejected for both endpoints`() async {
        for prefix in [[], [Self.page(#"{"id":"proj_a","status":"active"}"#)]] {
            for pages in [
                Array(repeating: Self.page("", more: true, cursor: "same"), count: 2),
                (0..<20).map { Self.page("", more: true, cursor: "page-\($0)") },
            ] {
                await #expect(throws: OpenAIOrgRateLimitsError.parseFailure) {
                    try await OpenAIOrgRateLimitsFetcher(transport: Transport(pages: prefix + pages)).fetch(
                        environment: Self.environment)
                }
            }
        }
    }

    @Test(arguments: [401, 403, 429, 500])
    func `HTTP failures have typed errors`(status: Int) async {
        let expected: OpenAIOrgRateLimitsError = switch status {
        case 401, 403: .adminKeyRequired
        case 429: .rateLimited
        default: .apiFailure(status)
        }
        await #expect(throws: expected) {
            try await OpenAIOrgRateLimitsFetcher(transport: Transport(pages: ["{}"], status: status)).fetch(
                environment: Self.environment)
        }
    }

    @Test
    func `missing credential never accesses the transport`() async {
        let transport = Transport(pages: [])
        await #expect(throws: OpenAIOrgRateLimitsError.missingCredential) {
            try await OpenAIOrgRateLimitsFetcher(transport: transport).fetch(environment: [:])
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func `manual org limits and project caps match independently by exact then dated snapshot family`() {
        let projectCaps = OpenAIOrgRateLimits(
            byModel: [
                "gpt-5-2025-08-07": .init(tokensPerMinute: 1000),
                "gpt-4o": .init(tokensPerMinute: 200),
                "gpt-4o-mini": .init(tokensPerMinute: 300),
            ],
            projectsSampled: 2,
            truncated: false,
            fetchedAt: Self.now)
        let resolver = OpenAIOrgLimitResolver(
            manual: [.init(model: "gpt-5", tokensPerMinute: 100)],
            projectCaps: projectCaps)
        #expect(resolver.projectCap(for: "gpt-5-2025-08-07")?.tokensPerMinute == 1000)
        #expect(resolver.resolve("gpt-5-2025-08-07")?.tokensPerMinute == 100)
        #expect(resolver.manualLimitKey(for: "gpt-5-2025-08-07") == "gpt-5")
        #expect(resolver.manualLimitKey(for: "gpt-4o") == nil)
        #expect(resolver.resolve("gpt-4o") == nil)
        #expect(resolver.projectCap(for: "gpt-4o")?.tokensPerMinute == 200)
        #expect(resolver.projectCap(for: "gpt-4o-mini-2024-07-18")?.tokensPerMinute == 300)
        #expect(resolver.resolve("absent") == nil)
        let manual = OpenAIOrgLimitResolver(manual: [
            .init(model: "gpt-4", tokensPerMinute: 1), .init(model: "gpt-4o", tokensPerMinute: 2),
            .init(model: "gpt-4o-mini", tokensPerMinute: 3),
            .init(model: "gpt-4o-mini-2024-07-18", tokensPerMinute: 4),
        ], projectCaps: nil)
        #expect(manual.resolve("gpt-4o-mini-2024-07-18")?.tokensPerMinute == 4)
        #expect(manual.manualLimitKey(for: "gpt-4o-mini-2024-07-18") == "gpt-4o-mini-2024-07-18")
        #expect(manual.manualLimitKey(for: "gpt-4o-mini-2024-08-01") == "gpt-4o-mini")
        #expect(manual.resolve("gpt-4o-mini-next") == nil)
        #expect(manual.resolve("gpt-4-0613")?.tokensPerMinute == 1)
        #expect(OpenAIOrgLimitResolver(manual: [.init(model: "gpt-4", tokensPerMinute: 1)], projectCaps: nil)
            .resolve("gpt-4o-mini") == nil)
        // A family limit covers dated snapshots only, never distinct sibling models.
        let gpt5 = OpenAIOrgLimitResolver(manual: [.init(model: "gpt-5", tokensPerMinute: 100)], projectCaps: nil)
        #expect(gpt5.resolve("gpt-5-mini") == nil)
        #expect(gpt5.resolve("gpt-5-mini-2025-08-07") == nil)
        #expect(gpt5.resolve("gpt-5-2025-08-07")?.tokensPerMinute == 100)
    }

    @Test
    func `utilization measures complete minute peaks and RPM with deterministic highest model`() throws {
        let snapshot = OpenAILiveUsageSnapshot(
            minutes: [
                .init(start: Self.now.addingTimeInterval(-90), models: [
                    .init(name: "b", inputTokens: 80, cachedInputTokens: 0, outputTokens: 20, requests: 4),
                    .init(name: "a", inputTokens: 50, cachedInputTokens: 0, outputTokens: 0, requests: 1),
                ]),
                .init(start: Self.now.addingTimeInterval(-30), models: [
                    .init(name: "b", inputTokens: 150, cachedInputTokens: 0, outputTokens: 0, requests: 2),
                    .init(name: "a", inputTokens: 75, cachedInputTokens: 0, outputTokens: 0, requests: 1),
                    .init(name: "no-limit", inputTokens: 1000, cachedInputTokens: 0, outputTokens: 0, requests: 1),
                ]),
            ],
            windowMinutes: 15,
            fetchedAt: Self.now,
            projectID: nil)
        let limits = OpenAIOrgLimitResolver(manual: [
            .init(model: "a", tokensPerMinute: 100),
            .init(model: "b", tokensPerMinute: 200, requestsPerMinute: 8),
        ], projectCaps: nil)
        let b = try #require(snapshot.utilization(for: .model("b"), limits: limits))
        #expect(b.latestTPMPercent == 50)
        // The in-progress minute (150 TPM, 75%) is pending, so the peak is the complete minute.
        #expect(b.peakTPMPercent == 50)
        #expect(b.peakRPMPercent == 50)
        #expect(snapshot.utilization(for: .allModels, limits: limits) == nil)
        #expect(snapshot.utilization(for: .model("no-limit"), limits: limits) == nil)
        #expect(snapshot.highestUtilization(limits: limits)?.name == "a")
        let row = try #require(snapshot.modelRows(limits: limits).first { $0.name == "b" })
        #expect(row.tpmLimit == 200)
        #expect(row.rpmLimit == 8)
        #expect(row.projectCap == nil)
        #expect(row.peakTPMPercent == 50)
        #expect(row.latestTPMPercent == 50)
        #expect(snapshot.utilization(for: .model("a"), limits: limits)?.peakRPMPercent == nil)
    }

    @Test
    func `shared manual limits pool minute traffic while exact limits remain independent`() throws {
        let minutes: [OpenAILiveUsageSnapshot.Minute] = [
            .init(start: Self.now.addingTimeInterval(-150), models: [
                .init(
                    name: "gpt-5",
                    inputTokens: 90,
                    cachedInputTokens: 50,
                    outputTokens: 10,
                    requests: 10,
                    batchTokens: 40,
                    batchRequests: 4),
                .init(
                    name: "gpt-5-2025-08-07",
                    inputTokens: 60,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    requests: 6),
                .init(
                    name: "gpt-5-2025-08-08",
                    inputTokens: 70,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    requests: 7),
            ]),
            .init(start: Self.now.addingTimeInterval(-90), models: [
                .init(name: "gpt-5", inputTokens: 20, cachedInputTokens: 0, outputTokens: 0, requests: 1),
                .init(
                    name: "gpt-5-2025-08-07",
                    inputTokens: 30,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    requests: 2),
            ]),
            .init(start: Self.now.addingTimeInterval(-30), models: [
                .init(name: "gpt-5", inputTokens: 1000, cachedInputTokens: 0, outputTokens: 0, requests: 100),
                .init(
                    name: "gpt-5-2025-08-07",
                    inputTokens: 1000,
                    cachedInputTokens: 0,
                    outputTokens: 0,
                    requests: 100),
            ]),
        ]
        let limits = OpenAIOrgLimitResolver(manual: [
            .init(model: "gpt-5", tokensPerMinute: 100, requestsPerMinute: 10),
            .init(model: "gpt-5-2025-08-08", tokensPerMinute: 200, requestsPerMinute: 20),
        ], projectCaps: nil)
        let snapshot = OpenAILiveUsageSnapshot(
            minutes: minutes,
            windowMinutes: 15,
            fetchedAt: Self.now,
            projectID: nil)
        for name in ["gpt-5", "gpt-5-2025-08-07"] {
            let utilization = try #require(snapshot.utilization(for: .model(name), limits: limits))
            #expect(utilization.pooledModels == ["gpt-5", "gpt-5-2025-08-07"])
            #expect(utilization.latestTPMPercent == 50)
            #expect(utilization.peakTPMPercent == 120)
            #expect(utilization.peakRPMPercent == 120)
        }
        let exact = try #require(snapshot.utilization(for: .model("gpt-5-2025-08-08"), limits: limits))
        #expect(exact.pooledModels == ["gpt-5-2025-08-08"])
        #expect(exact.peakTPMPercent == 35)
        #expect(exact.latestTPMPercent == 0)
        #expect(exact.peakRPMPercent == 35)
        #expect(snapshot.highestUtilization(limits: limits)?.peakTPMPercent == 120)
        #expect(snapshot.modelRows(limits: limits).prefix(2).map(\.peakTPMPercent) == [120, 120])
        let scoped = OpenAILiveUsageSnapshot(
            minutes: minutes,
            windowMinutes: 15,
            fetchedAt: Self.now,
            projectID: "proj_fixture")
        #expect(scoped.utilization(for: .model("gpt-5"), limits: limits) == nil)
    }

    @Test
    func `org traffic can exceed every project cap without implying an org limit`() throws {
        let snapshot = OpenAILiveUsageSnapshot(
            minutes: [.init(start: Self.now.addingTimeInterval(-90), models: [
                .init(
                    name: "gpt-4o",
                    inputTokens: 75_000_000,
                    cachedInputTokens: 0,
                    outputTokens: 22_000_000,
                    requests: 100),
            ])],
            windowMinutes: 15,
            fetchedAt: Self.now,
            projectID: nil)
        let limits = OpenAIOrgLimitResolver(manual: [], projectCaps: .init(
            byModel: ["gpt-4o": .init(tokensPerMinute: 40_000_000)],
            projectsSampled: 4,
            truncated: false,
            fetchedAt: Self.now))
        let row = try #require(snapshot.modelRows(limits: limits).first)
        #expect(row.projectCap == 40_000_000)
        #expect(row.tpmLimit == nil)
        #expect(row.peakTPMPercent == nil)
        #expect(row.latestTPMPercent == nil)
        #expect(snapshot.utilization(for: .model("gpt-4o"), limits: limits) == nil)
        #expect(snapshot.highestUtilization(limits: limits) == nil)
    }

    @Test
    func `project scoped snapshots never report org limit utilization`() {
        let minutes: [OpenAILiveUsageSnapshot.Minute] = [.init(
            start: Self.now.addingTimeInterval(-90),
            models: [.init(name: "a", inputTokens: 80, cachedInputTokens: 0, outputTokens: 20, requests: 4)])]
        let limits = OpenAIOrgLimitResolver(manual: [.init(model: "a", tokensPerMinute: 200)], projectCaps: nil)
        let orgWide = OpenAILiveUsageSnapshot(minutes: minutes, windowMinutes: 15, fetchedAt: Self.now, projectID: nil)
        #expect(orgWide.utilization(for: .model("a"), limits: limits)?.peakTPMPercent == 50)

        let scoped = OpenAILiveUsageSnapshot(
            minutes: minutes,
            windowMinutes: 15,
            fetchedAt: Self.now,
            projectID: "proj_fixture")
        #expect(scoped.utilization(for: .model("a"), limits: limits) == nil)
        #expect(scoped.highestUtilization(limits: limits) == nil)
        #expect(scoped.modelRows(limits: limits).first?.tpmLimit == nil)
        #expect(scoped.modelRows(limits: limits).first?.peakTPMPercent == nil)
    }

    private static func page(_ rows: String, more: Bool = false, cursor: String? = nil) -> String {
        let cursor = cursor.map { "\"\($0)\"" } ?? "null"
        return #"{"object":"list","data":[\#(rows)],"has_more":\#(more),"last_id":\#(cursor)}"#
    }

    private static func limit(_ model: String, tpm: Int, rpm: Int) -> String {
        #"""
        {"object":"project.rate_limit","id":"rl_test","model":"\#(model)",
         "max_tokens_per_1_minute":\#(tpm),"max_requests_per_1_minute":\#(rpm)}
        """#
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
            let body = self.pages.indices.contains(index) ? self.pages[index] : "{}"
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!)
        }
    }
}
