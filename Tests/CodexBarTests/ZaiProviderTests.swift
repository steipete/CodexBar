import Foundation
import Testing
@testable import CodexBarCore

struct ZaiProviderTests {
    @Test
    func `settings reader preserves regional credential precedence`() {
        #expect(ZaiSettingsReader.apiToken(environment: ["Z_AI_API_KEY": " direct-token "]) == "direct-token")
        #expect(ZaiSettingsReader.apiToken(
            for: .bigmodelCN,
            environment: ["BIGMODEL_API_KEY": " china-token "],
            homeDirectory: URL(fileURLWithPath: "/nonexistent")) == "china-token")
        #expect(ZaiSettingsReader.apiToken(
            for: .global,
            environment: ["BIGMODEL_API_KEY": "china-token"],
            homeDirectory: URL(fileURLWithPath: "/nonexistent")) == nil)
    }

    @Test
    func `endpoint router preserves quota model and dashboard routing`() {
        #expect(ZaiEndpointRouter.resolveQuotaURL(region: .global, environment: [:]).absoluteString ==
            "https://api.z.ai/api/monitor/usage/quota/limit")
        #expect(ZaiEndpointRouter.resolveModelUsageURL(region: .bigmodelCN, environment: [:]).absoluteString ==
            "https://open.bigmodel.cn/api/monitor/usage/model-usage")

        let quotaOverride = [ZaiSettingsReader.quotaURLKey: "https://zai-proxy.test/custom-quota"]
        #expect(ZaiEndpointRouter.resolveQuotaURL(region: .global, environment: quotaOverride).absoluteString ==
            "https://zai-proxy.test/custom-quota")
        #expect(ZaiEndpointRouter.resolveModelUsageURL(region: .global, environment: quotaOverride).absoluteString ==
            "https://api.z.ai/api/monitor/usage/model-usage")

        let hostOverride = [ZaiSettingsReader.apiHostKey: "open.bigmodel.cn"]
        #expect(ZaiEndpointRouter.resolveQuotaURL(region: .global, environment: hostOverride).absoluteString ==
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
        #expect(ZaiEndpointRouter.resolveDashboardURL(region: .global, environment: hostOverride) ==
            ZaiAPIRegion.bigmodelCN.dashboardURL)
        #expect(ZaiEndpointRouter.resolveDashboardURL(
            region: .global,
            environment: hostOverride,
            usageScope: .team) == ZaiAPIRegion.bigmodelCN.teamDashboardURL)
    }

    @Test
    func `script strategy projects validated endpoint overrides`() async throws {
        let environment = [
            ZaiSettingsReader.apiTokenKey: "fixture-key",
            ZaiSettingsReader.quotaURLKey: "https://zai-proxy.test/custom-quota?keep=1&type=9",
            ZaiSettingsReader.apiHostKey: "https://zai-proxy.test/custom-model",
            ZaiSettingsReader.bigModelOrganizationKey: "org-fixture",
            ZaiSettingsReader.bigModelProjectKey: "project-fixture",
        ]
        let settings = ProviderSettingsSnapshot.make(zai: .init(
            apiRegion: .global,
            usageScope: .team,
            teamContext: nil))
        let context = Self.context(environment: environment, settings: settings)
        let strategy = try #require(await ZaiProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(context).first)
        let requests = RequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await requests.append(request)
            let body = request.url?.path == "/custom-quota" ? Self.quotaFixture : Self.emptyModelUsageFixture
            return try Self.response(request: request, body: body)
        }
        let script = ScriptFetchStrategy(
            id: "zai.js",
            provider: .zai,
            bundledPlugin: "zai",
            secretKey: ZaiSettingsReader.apiTokenKey,
            sourceLabel: "api",
            transport: transport,
            validateContext: { _ in },
            resolveValues: { _ in
                ScriptFetchStrategy.Values(
                    settings: [
                        "Z_AI_REGION": "global",
                        "Z_AI_USAGE_SCOPE": "team",
                        "Z_AI_ORGANIZATION": "org-fixture",
                        "Z_AI_PROJECT": "project-fixture",
                        "Z_AI_QUOTA_ENDPOINT": "https://zai-proxy.test/custom-quota?keep=1&type=9",
                        "Z_AI_MODEL_USAGE_ENDPOINT": "https://zai-proxy.test/custom-model",
                    ],
                    secrets: [ZaiSettingsReader.apiTokenKey: "fixture-key"])
            },
            isEnabled: { _ in true })

        _ = try await script.fetch(context)

        let recorded = await requests.requests
        let quotaRequest = try #require(recorded.first { $0.url?.path == "/custom-quota" })
        #expect(quotaRequest.url?.query?.contains("keep=1") == true)
        #expect(quotaRequest.url?.query?.contains("type=2") == true)
        #expect(quotaRequest.url?.query?.contains("type=9") == false)
        #expect(quotaRequest.value(forHTTPHeaderField: "Bigmodel-Organization") == "org-fixture")
        #expect(quotaRequest.value(forHTTPHeaderField: "Bigmodel-Project") == "project-fixture")
        #expect(recorded.count { $0.url?.path == "/custom-model" } == 2)
        #expect(strategy.id == "zai.js")
    }

    @Test
    func `strategy rejects invalid endpoints and missing team context before network`() async throws {
        let invalidContext = Self.context(environment: [
            ZaiSettingsReader.apiTokenKey: "fixture-key",
            ZaiSettingsReader.apiHostKey: "http://attacker.test",
        ])
        let teamContext = Self.context(
            environment: [ZaiSettingsReader.apiTokenKey: "fixture-key"],
            settings: .make(zai: .init(usageScope: .team)))
        let strategy = try #require(await ZaiProviderDescriptor.descriptor.fetchPlan.pipeline
            .resolveStrategies(invalidContext).first)

        await #expect(throws: ZaiSettingsError.invalidEndpointOverride(ZaiSettingsReader.apiHostKey)) {
            _ = try await strategy.fetch(invalidContext)
        }
        await #expect(throws: ZaiProviderSettingsError.missingTeamContext) {
            _ = try await strategy.fetch(teamContext)
        }
    }

    @Test
    func `plugin maps quota and model usage into stable generic details`() async throws {
        let snapshot = try await Self.pluginSnapshot(quotaFixture: Self.quotaFixture)

        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.secondary?.usedPercent == 9)
        #expect(snapshot.extraRateWindows?.first?.id == "zai-mcp")
        #expect(snapshot.extraRateWindows?.first?.window.windowMinutes ==
            ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(snapshot.identity?.loginMethod == "Pro")
        #expect(snapshot.details.map(\.title) == ["Quota details", "Hourly tokens", "Daily tokens"])
    }

    @Test
    func `plugin preserves explicit MCP duration`() async throws {
        let snapshot = try await Self.pluginSnapshot(quotaFixture: Self.explicitTimeLimitFixture)

        #expect(snapshot.extraRateWindows?.first?.window.windowMinutes == 5 * 60)
    }

    @Test
    func `plugin leaves unknown MCP cadence unset`() async throws {
        let snapshot = try await Self.pluginSnapshot(quotaFixture: Self.unknownTimeLimitFixture)

        #expect(snapshot.extraRateWindows?.first?.window.windowMinutes == nil)
    }

    @Test(arguments: ["TOKENS_LIMIT", "CREDIT_LIMIT"])
    func `plugin preserves rolling 30-day limits without MCP semantics`(limitType: String) async throws {
        let fixture = #"""
        {"code":200,"msg":"success","success":true,"data":{"limits":[
          {"type":"\#(limitType)","unit":1,"number":30,"percentage":50,"nextResetTime":1787112000000}
        ]}}
        """#
        let snapshot = try await Self.pluginSnapshot(quotaFixture: fixture)

        #expect(snapshot.primary?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(snapshot.primary?.resetDescription == "30 days window")
    }

    @Test
    func `provider metadata keeps regional dashboards`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .zai)
        #expect(descriptor.metadata.displayName == "z.ai / GLM")
        #expect(descriptor.metadata.dashboardURL == ZaiAPIRegion.global.dashboardURL.absoluteString)
        #expect(ZaiAPIRegion.bigmodelCN.teamDashboardURL.absoluteString ==
            "https://bigmodel.cn/coding-plan/team/usage-stats")
    }

    private static func context(
        environment: [String: String],
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ZaiTestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func response(request: URLRequest, body: String) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private static func pluginSnapshot(quotaFixture: String) async throws -> UsageSnapshot {
        let transport = ProviderHTTPTransportHandler { request in
            let body = request.url?.path.hasSuffix("/quota/limit") == true
                ? quotaFixture
                : Self.modelUsageFixture
            return try Self.response(request: request, body: body)
        }
        return try await ProviderPluginRuntime(bundledPlugin: "zai", transport: transport).fetchUsage(
            settings: [
                "Z_AI_REGION": "global",
                "Z_AI_USAGE_SCOPE": "personal",
            ],
            secrets: ["Z_AI_API_KEY": "fixture-key"],
            now: Date(timeIntervalSince1970: 1_785_816_000))
    }

    private static let quotaFixture = #"""
    {"code":200,"msg":"success","success":true,"data":{"planName":"Pro","limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1785816000000},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9,"nextResetTime":1786291200000},
      {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":224,"remaining":776,
       "percentage":22,"usageDetails":[{"modelCode":"search-prime","usage":210}]}
    ]}}
    """#

    private static let explicitTimeLimitFixture = #"""
    {"code":200,"msg":"success","success":true,"data":{"limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1785816000000},
      {"type":"TIME_LIMIT","unit":3,"number":5,"percentage":22,"nextResetTime":1785816000000}
    ]}}
    """#

    private static let unknownTimeLimitFixture = #"""
    {"code":200,"msg":"success","success":true,"data":{"limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1785816000000},
      {"type":"TIME_LIMIT","unit":0,"number":1,"percentage":22,"nextResetTime":1785816000000}
    ]}}
    """#

    private static let modelUsageFixture = #"""
    {"code":200,"msg":"success","success":true,"data":{
      "x_time":["2026-08-02 08:00","2026-08-02 09:00"],
      "modelDataList":[{"modelName":"glm-4.6","tokensUsage":[100,null]},
      {"modelName":"glm-4.5","tokensUsage":[50,25]}]}}
    """#

    private static let emptyModelUsageFixture =
        #"{"code":200,"msg":"success","success":true,"data":{"x_time":[],"modelDataList":[]}}"#
}

private actor RequestRecorder {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}

private struct ZaiTestClaudeFetcher: ClaudeUsageFetching {
    func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
        throw ProviderPluginError.script("unused")
    }

    func debugRawProbe(model _: String) async -> String {
        "unused"
    }

    func detectVersion() -> String? {
        nil
    }
}
