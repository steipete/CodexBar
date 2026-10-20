import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct QwenCloudTeamPluginTests {
    private static let now = Date(timeIntervalSince1970: 1_789_500_000)
    /// Sanitized #3711 response; account and request identifiers are omitted.
    private static let summary = #"""
    {"code":"200","successResponse":true,"data":{"Code":"Success","Success":true,"Data":{
      "StartTime":1784894400000,"EndTime":1790251200000,"ProductCode":"sfm_tokenplanteams_dp_intl",
      "SubscriptionGroupList":[{"SpecType":"standard","SubscriptionAssignedNumber":1,
        "SubscriptionTotalNumber":1,"NextCycleFlushTime":1790251200000,"EquityList":[
          {"EquityCode":"credit_value","TotalValue":"25000.00000000","SurplusValue":"6373.93922996"}
        ]}]
    }}}
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `Team discovers its billing selector and maps the reported credit pool`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "qwencloud-team", engine: engine, transport: Self.transport(summary: Self.summary))
        let usage = try await runtime.fetchUsage(now: Self.now, cookieResolver: { provider, domain in
            #expect(provider == .qwencloud)
            #expect(domain == "home.qwencloud.com")
            return "session=synthetic"
        })
        #expect(try abs(#require(usage.primary?.usedPercent) - 74.50424308016) < 0.00000001)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_790_251_200))
        #expect(usage.primary?.windowMinutes == nil)
        #expect(usage.primary?.resetDescription == "Team")
        #expect(usage.identity?.providerID == .qwencloud)
        #expect(usage.identity?.loginMethod == "Standard Team")
        #expect(usage.details.first?.rows.first?.value == "18,626.06 / 25,000 credits used")
        #expect(usage.details.first?.rows.last?.value == "1 / 1")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `credit equity and cycle reset are independent of list order and subscription expiry`(
        engine: ProviderPluginEngineKind) async throws
    {
        let payload = Self.summary.replacingOccurrences(
            of: #""EquityList":["#, with: #""EquityList":[{"EquityCode":"seats","TotalValue":"999"},"#)
            .replacingOccurrences(
                of: #""NextCycleFlushTime":1790251200000"#,
                with: #""NextCycleFlushTime":1790000000000"#)
        let usage = try await Self.fetch(payload, engine: engine)
        #expect(try abs(#require(usage.primary?.usedPercent) - 74.50424308016) < 0.00000001)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test(arguments: BundledPluginTestSupport.engines, [
        #"{"successResponse":true,"data":{"Success":true,"Data":null}}"#,
        #"{"successResponse":true,"data":{"Success":true,"Data":{"SubscriptionGroupList":[]}}}"#,
        #"{"successResponse":true,"data":{"Success":true,"Data":{}}}"#,
    ])
    func `no active Team subscription leaves Individual available`(
        engine: ProviderPluginEngineKind, payload: String) async throws
    {
        #expect(try await Self.fetch(payload, engine: engine).primary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired Team subscriptions do not present an old credit pool`(engine: ProviderPluginEngineKind) async throws {
        let usage = try await Self.fetch(Self.summary, engine: engine, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(usage.primary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `absent billing selector follows the console default scope`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "qwencloud-team", engine: engine, transport: Self.transport(summary: Self.summary, selector: nil))
        let usage = try await runtime.fetchUsage(now: Self.now, cookieResolver: { _, _ in "session=synthetic" })
        #expect(usage.identity?.loginMethod == "Standard Team")
    }

    @Test(arguments: BundledPluginTestSupport.engines, ["-1", "NaN", "26000", "9007199254740992"])
    func `invalid remaining credits are errors rather than absence or zero usage`(
        engine: ProviderPluginEngineKind, remaining: String) async
    {
        let payload = Self.summary.replacingOccurrences(of: "6373.93922996", with: remaining)
        let error = await #expect(throws: ProviderFetchClassifiedError.self) {
            try await Self.fetch(payload, engine: engine)
        }
        #expect(error?.kind == .parseFailure)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed successful envelopes and multiple pools are not treated as no plan`(
        engine: ProviderPluginEngineKind) async throws
    {
        var root = try #require(JSONSerialization.jsonObject(with: Data(Self.summary.utf8)) as? [String: Any])
        var envelope = try #require(root["data"] as? [String: Any])
        var data = try #require(envelope["Data"] as? [String: Any])
        let groups = try #require(data["SubscriptionGroupList"] as? [[String: Any]])
        data["SubscriptionGroupList"] = groups + groups
        envelope["Data"] = data
        root["data"] = envelope
        let multiple = try #require(String(data: JSONSerialization.data(withJSONObject: root), encoding: .utf8))
        let nonArrayGroups = #"{"successResponse":true,"data":{"Success":true,"Data":{"SubscriptionGroupList":{}}}}"#
        let partial = #"{"successResponse":true,"data":{"Success":true,"Data":{"ProductCode":"x"}}}"#
        for payload in [#"{"successResponse":true,"data":{}}"#, nonArrayGroups, partial, multiple] {
            let error = await #expect(throws: ProviderFetchClassifiedError.self) {
                try await Self.fetch(payload, engine: engine)
            }
            #expect(error?.kind == .parseFailure)
        }
    }

    @Test
    func `Team wins the pipeline and the descriptor labels it Team`() async throws {
        let context = Self.context()
        let strategy = QwenCloudTeamFetchStrategy(transport: Self.transport(summary: Self.summary), now: Self.now)
        let pipeline = ProviderFetchPipeline(resolveStrategies: { _ in [strategy, IndividualFixture()] })
        let outcome = await pipeline.fetch(context: context, provider: .qwencloud)
        let usage = try outcome.result.get().usage
        #expect(outcome.attempts.map(\.strategyID) == ["qwen-cloud.team"])
        let descriptor = QwenCloudProviderDescriptor.descriptor
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        #expect(strategies.map(\.id) == ["qwen-cloud.team", "qwen-cloud.web"])
        #expect(descriptor.presentation.rateWindowLabels(metadata: descriptor.metadata, snapshot: usage, now: Self.now)
            .primary == "Team")
    }

    @Test
    func `expired automatic Team cookies refresh before giving up Team precedence`() async throws {
        let attempts = CookieAttempts()
        let fresh = Self.transport(summary: Self.summary)
        let strategy = QwenCloudTeamFetchStrategy(
            transport: ProviderHTTPTransportHandler { request in
                if request.value(forHTTPHeaderField: "Cookie") == "session=fixture-stale-cookie" {
                    let url = try #require(request.url)
                    return try (
                        Data(),
                        #require(HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)))
                }
                return try await fresh.data(for: request)
            },
            now: Self.now,
            cookieResolver: { _, allowCached in
                attempts.append(allowCached)
                return .init(
                    apiCookieHeader: "api=unused",
                    dashboardCookieHeader:
                    allowCached ? "session=fixture-stale-cookie" : "session=synthetic")
            })
        // Calling the injected strategy directly avoids availability's real browser-cache lookup.
        let result = try await strategy.fetch(Self.context(cookieSource: .auto))
        #expect(result.strategyID == "qwen-cloud.team")
        #expect(result.usage.identity?.loginMethod == "Standard Team")
        #expect(attempts.values == [true, false])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `console login errors retain authentication classification inside HTTP success`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "qwencloud-team", engine: engine, transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                let body = url.path == "/tool/user/info.json"
                    ? #"{"data":{"secToken":"fixture-token"}}"#
                    : #"{"successResponse":false,"code":"ConsoleNeedLogin"}"#
                return try (
                    Data(body.utf8),
                    #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
            })
        let error = await #expect(throws: ProviderFetchClassifiedError.self) {
            try await runtime.fetchUsage(cookieResolver: { _, _ in "session=synthetic" })
        }
        #expect(error?.kind == .authenticationExpired)
    }

    @Test
    func `rejected manual cookies never trigger automatic recovery`() async {
        let attempts = CookieAttempts()
        let strategy = QwenCloudTeamFetchStrategy(
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                return try (Data(), #require(HTTPURLResponse(
                    url: url, statusCode: 401, httpVersion: nil, headerFields: nil)))
            }, cookieResolver: { _, cached in
                attempts.append(cached)
                return .init(singleHeader: "session=fixture-stale-cookie")!
            })
        await #expect(throws: ProviderFetchClassifiedError.self) {
            try await strategy.fetch(Self.context())
        }
        #expect(attempts.values == [true])
    }

    @Test(arguments: [
        (true, #"{"successResponse":true,"data":{}}"#),
        (false, #"{"successResponse":true,"data":{"Success":true,"Data":null}}"#),
        (false, #"{"successResponse":true,"data":{"Success":true,"Data":{}}}"#),
        (true, #"{"successResponse":true,"data":{"Success":true,"Data":{"ProductCode":"x"}}}"#),
    ])
    func `Individual fallback distinguishes absent Team from a broken Team response`(
        broken: Bool, summary: String) async throws
    {
        let strategy = QwenCloudTeamFetchStrategy(transport: Self.transport(summary: summary), now: Self.now)
        let pipeline = ProviderFetchPipeline(
            resolveStrategies: { _ in [strategy, IndividualFixture()] },
            resolveFallbackError: QwenCloudTeamFetchStrategy.fallbackError)
        let outcome = await pipeline.fetch(context: Self.context(), provider: .qwencloud)
        let result = try outcome.result.get()
        #expect(result.usage.primary?.usedPercent == 12)
        #expect(outcome.attempts.count == 2)
        #expect((result.diagnostic != nil) == broken)
    }

    @Test(arguments: ["QWEN_CLOUD_HOST", "QWEN_CLOUD_QUOTA_URL"])
    func `endpoint overrides never probe the canonical Team host`(key: String) async {
        let strategy = QwenCloudTeamFetchStrategy()
        let context = Self.context(environment: [key: "https://fixture.example"])
        #expect(await strategy.isAvailable(context) == false)
        await #expect(throws: ProviderFetchError.self) { try await strategy.fetch(context) }
    }

    @Test
    func `disabled cookies and non web modes fail before reading a session`() async {
        let strategy = QwenCloudTeamFetchStrategy()
        for context in [Self.context(source: .api), Self.context(cookieSource: .off)] {
            #expect(await strategy.isAvailable(context) == false)
            await #expect(throws: ProviderFetchError.self) { try await strategy.fetch(context) }
        }
    }

    @Test
    func `cancellation does not fall through to Individual and preserves Team errors on double failure`() async {
        let strategy = QwenCloudTeamFetchStrategy(transport: ProviderHTTPTransportHandler { _ in
            throw CancellationError()
        })
        let pipeline = ProviderFetchPipeline(resolveStrategies: { _ in [strategy, IndividualFixture()] })
        let outcome = await pipeline.fetch(context: Self.context(), provider: .qwencloud)
        #expect(outcome.attempts.count == 1)
        if case let .failure(error) = outcome.result {
            #expect(error is CancellationError)
        } else {
            Issue.record("Cancellation must fail")
        }
        let original = ProviderFetchClassifiedError(kind: .parseFailure, message: "Team fixture failure")
        let resolved = QwenCloudTeamFetchStrategy.fallbackError(previous: original, current: URLError(.badURL))
        #expect((resolved as? ProviderFetchClassifiedError) == original)
    }

    private struct IndividualFixture: ProviderFetchStrategy {
        let id = "individual.fixture"
        let kind: ProviderFetchKind = .web
        func isAvailable(_: ProviderFetchContext) async -> Bool { true }
        func fetch(_: ProviderFetchContext) async throws -> ProviderFetchResult {
            self.makeResult(usage: UsageSnapshot(
                primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: QwenCloudTeamPluginTests.now), sourceLabel: "web")
        }

        func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool { false }
        func diagnostic(forPriorFailure error: Error) -> String? {
            QwenCloudWebFetchStrategy().diagnostic(forPriorFailure: error)
        }
    }

    private final class CookieAttempts: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Bool] = []
        var values: [Bool] {
            self.lock.withLock { self.storage }
        }

        func append(_ value: Bool) { self.lock.withLock { self.storage.append(value) } }
    }

    private static func context(
        environment: [String: String] = [:],
        source: ProviderSourceMode = .web,
        cookieSource: ProviderCookieSource = .manual) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .cli,
            sourceMode: source,
            includeCredits: false,
            webTimeout: 30,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: .make(qwenCloud: .init(cookieSource: cookieSource, manualCookieHeader: "session=synthetic")),
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: BrowserDetection()),
            browserDetection: BrowserDetection())
    }

    private static func fetch(
        _ summary: String, engine: ProviderPluginEngineKind, now: Date = Self.now) async throws -> UsageSnapshot
    {
        try await BundledPluginTestSupport.runtime(
            "qwencloud-team", engine: engine, transport: self.transport(summary: summary))
            .fetchUsage(now: now, cookieResolver: { _, _ in "session=synthetic" })
    }

    private static func transport(
        summary: String,
        selector: String? = "fixture-seller") -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            #expect(url.host == "home.qwencloud.com")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=synthetic")
            let body: String
            if url.path == "/tool/user/info.json" {
                #expect(request.httpMethod == "GET")
                body = #"{"data":{"secToken":"fixture +&=%"}}"#
            } else {
                #expect(url.path == "/data/api.json")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://home.qwencloud.com")
                #expect(request
                    .value(forHTTPHeaderField: "Referer") == "https://home.qwencloud.com/analytics/token-plan/team")
                let form = try #require(String(data: request.httpBody ?? Data(), encoding: .utf8))
                let fields = Dictionary(uniqueKeysWithValues: form.split(separator: "&").map { pair in
                    let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return (String(parts[0]).removingPercentEncoding!, String(parts[1]).removingPercentEncoding!)
                })
                #expect(fields["sec_token"] == "fixture +&=%")
                let params = try #require(fields["params"]).data(using: .utf8)!
                let values = try #require(JSONSerialization.jsonObject(with: params) as? [String: String])
                switch fields["action"] {
                case "LoadHumanInfo":
                    #expect(fields["product"] == "ea-service")
                    #expect(fields["region"] == "ap-southeast-1")
                    #expect(values.isEmpty)
                    // The shared console client also accepts the string success code without successResponse.
                    let seller = selector.map { #"{"Nbid":"\#($0)"}"# } ?? "{}"
                    body = #"{"code":"200","data":{"Data":{"SellerInfoDto":\#(seller)}}}"#
                case "GetSeatSubscriptionSummary":
                    #expect(fields["product"] == "BssOpenAPI-V3")
                    #expect(fields["region"] == "cn-hangzhou")
                    #expect(fields["language"] == "zh-CN")
                    var expected = ["productCode": "sfm_tokenplanteams_dp_intl"]
                    expected["Nbid"] = selector
                    #expect(values == expected)
                    body = summary
                default:
                    Issue.record("Unexpected Team action")
                    throw URLError(.badURL)
                }
            }
            return try (
                Data(body.utf8),
                #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
        }
    }
}
