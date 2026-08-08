import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginDetailsParityTests {
    @Test
    func `OpenAI prepends JS only when the prototype flag is enabled`() async {
        let fixtures: [(UsageProvider, [String], [String])] = [
            (.openai, ["openai.api.balance"], ["openai.js", "openai.api.balance"]),
        ]

        for (provider, defaultIDs, enabledIDs) in fixtures {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            let defaultStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
                Self.context(environment: Self.environment(for: provider)))
            var enabledEnvironment = Self.environment(for: provider)
            enabledEnvironment[ProviderPluginPrototype.environmentKey] = "1"
            let enabledStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(
                Self.context(environment: enabledEnvironment))

            #expect(defaultStrategies.map(\.id) == defaultIDs)
            #expect(enabledStrategies.map(\.id) == enabledIDs)
        }
    }

    @Test
    func `zai plugin resolves China region credential aliases only for China`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .zai)
        let environment = [
            ProviderPluginPrototype.environmentKey: "1",
            "BIGMODEL_API_KEY": "china-token",
        ]
        let chinaContext = Self.context(
            environment: environment,
            settings: .make(zai: .init(apiRegion: .bigmodelCN)))
        let globalContext = Self.context(
            environment: environment,
            settings: .make(zai: .init(apiRegion: .global)))

        let chinaStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(chinaContext)
        let globalStrategies = await descriptor.fetchPlan.pipeline.resolveStrategies(globalContext)

        #expect(chinaStrategies.map(\.id) == ["zai.js"])
        #expect(await chinaStrategies[0].isAvailable(chinaContext))
        #expect(globalStrategies.map(\.id) == ["zai.js"])
        #expect(await globalStrategies[0].isAvailable(globalContext) == false)
    }

    @Test
    func `OpenRouter fixture matches stable cut-over details`() async throws {
        let transport = Self.transport { request in
            switch request.url?.path {
            case "/api/v1/credits": Self.openRouterCredits
            case "/api/v1/key": Self.openRouterKey
            case "/api/v1/activity": Self.openRouterActivity
            default: throw FixtureError.unexpectedURL(request.url)
            }
        }
        let now = Date(timeIntervalSince1970: 1_785_686_400)
        let script = try await ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport)
            .fetchUsage(secrets: ["OPENROUTER_API_KEY": "fixture-key"], now: now)

        #expect(script.primary?.usedPercent == 25)
        #expect(script.identity?.loginMethod == "Balance: $60.00")
        let activity = try #require(script.openRouterActivityUsage)
        let activityCost = activity.toCostUsageTokenSnapshot()
        #expect(activityCost.last30DaysTokens == 45)
        #expect(activityCost.last30DaysRequests == 3)
        #expect(abs((activityCost.last30DaysCostUSD ?? -1) - 0.015) < 0.000_000_001)
        #expect(activityCost.daily.count == 1)
        #expect(activityCost.daily.first?.modelBreakdowns?.count == 1)
        #expect(try script.details == [
            Self.section("Credits", rows: [
                Self.row("Remaining", "$60.00"),
                Self.row("Used", "$40.00"),
                Self.row("Total added", "$100.00"),
            ]),
            Self.section(
                "API key",
                rows: [
                    Self.row("API key budget", "$20.00"),
                    Self.row("API key remaining", "$15.00"),
                    Self.row("API key used", "$5.00"),
                    Self.row("Reset window", "monthly"),
                    Self.row("Today", "$1.00"),
                    Self.row("This week", "$2.00"),
                    Self.row("This month", "$4.00"),
                    Self.row("Rate limit", "120 requests / 10s"),
                ],
                chart: Self.chart("Key spend", unit: "USD", points: [
                    ("Today", 1), ("This week", 2), ("This month", 4),
                ])),
        ])
    }

    @Test
    func `OpenRouter malformed optional activity preserves credits on both plugin engines`() async throws {
        let transport = Self.transport { request in
            switch request.url?.path {
            case "/api/v1/credits": Self.openRouterCredits
            case "/api/v1/key": Self.openRouterKey
            case "/api/v1/activity": #"{"data":[{"date":"2026-08-01","usage":"free"}]}"#
            default: throw FixtureError.unexpectedURL(request.url)
            }
        }

        let script = try await ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport)
            .fetchUsage(secrets: ["OPENROUTER_API_KEY": "fixture-key"])

        #expect(script.openRouterActivityUsage == nil)
        #expect(script.identity?.loginMethod == "Balance: $60.00")
    }

    @Test
    func `OpenRouter delayed optional activity stays within the fast return budget`() async throws {
        let requests = PluginRequestRecorder()
        let transport = ProviderHTTPTransportHandler { request in
            await requests.append(request)
            if request.url?.path == "/api/v1/activity" {
                try await Task.sleep(for: .seconds(3))
                throw URLError(.timedOut)
            }
            let body = switch request.url?.path {
            case "/api/v1/credits": Self.openRouterCredits
            case "/api/v1/key": Self.openRouterKey
            default: throw FixtureError.unexpectedURL(request.url)
            }
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
        let clock = ContinuousClock()
        let startedAt = clock.now
        let script = try await ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport)
            .fetchUsage(secrets: ["OPENROUTER_API_KEY": "fixture-key"])
        let elapsed = startedAt.duration(to: clock.now)
        let optionalRequests = await requests.requests.filter {
            ["key", "activity"].contains($0.url?.lastPathComponent)
        }

        #expect(optionalRequests.count == 2)
        #expect(optionalRequests.allSatisfy { $0.timeoutInterval == 1 })
        #expect(elapsed < .seconds(2))
        #expect(script.openRouterActivityUsage == nil)
        #expect(script.identity?.loginMethod == "Balance: $60.00")
    }

    @Test
    func `ClawRouter fixture matches stable cut-over details`() async throws {
        let transport = Self.transport { request in
            guard request.url?.path == "/v1/usage" else { throw FixtureError.unexpectedURL(request.url) }
            return Self.clawRouter
        }
        let now = Date(timeIntervalSince1970: 1_785_686_400)
        let script = try await ProviderPluginRuntime(bundledPlugin: "clawrouter", transport: transport)
            .fetchUsage(secrets: ["CLAWROUTER_API_KEY": "fixture-key"], now: now)

        #expect(script.primary?.usedPercent == 0.024)
        #expect(script.providerCost?.used == 0.006)
        #expect(script.providerCost?.limit == 25)
        #expect(try script.details == [
            Self.section("Usage", rows: [
                Self.row("Requests", "6", "5 succeeded · 1 failed"),
                Self.row("Tokens", "54191", "50000 input · 4191 output"),
                Self.row("Actual cost", "$0.006000"),
                Self.row("Budget ledger", "durable_object"),
                Self.row("Monthly budget", "$0.006000 / $25.00", "$24.994000 remaining"),
            ]),
            Self.section(
                "Routed providers",
                rows: [
                    Self.row("openai", "4 requests", "$0.004000 · 42000 tokens"),
                    Self.row("anthropic", "2 requests", "$0.002000 · 12191 tokens"),
                ],
                chart: Self.chart("Provider cost", unit: "USD", points: [
                    ("openai", 0.004), ("anthropic", 0.002),
                ])),
        ])
    }

    @Test(arguments: [false, true])
    func `OpenRouter cut-over honors default and overridden requests`(overridden: Bool) async throws {
        let environment: [String: String] = overridden ? [
            OpenRouterSettingsReader.apiURLEnvironmentKey: "https://router.example.test/gateway/v1",
            OpenRouterSettingsReader.httpRefererEnvironmentKey: " https://codexbar.example ",
            OpenRouterSettingsReader.clientTitleEnvironmentKey: "CodexBar QA",
        ] : [:]
        let settings: [String: String] = [
            OpenRouterSettingsReader.apiURLEnvironmentKey:
                OpenRouterSettingsReader.apiURL(environment: environment).absoluteString,
            OpenRouterSettingsReader.clientTitleEnvironmentKey:
                OpenRouterSettingsReader.clientTitle(environment: environment),
            OpenRouterSettingsReader.httpRefererEnvironmentKey:
                OpenRouterSettingsReader.httpReferer(environment: environment) ?? "",
        ]
        let requests = PluginRequestRecorder()
        let transport = Self.recordingTransport(requests) { request in
            request.url?.path.hasSuffix("/key") == true ? Self.openRouterKey : Self.openRouterCredits
        }

        _ = try await ProviderPluginRuntime(bundledPlugin: "openrouter", transport: transport).fetchUsage(
            settings: settings,
            secrets: [OpenRouterSettingsReader.envKey: "fixture-key"])

        let recorded = await requests.requests
        #expect(recorded.count == 3)
        #expect(recorded[0].url?.absoluteString == (overridden
                ? "https://router.example.test/gateway/v1/credits"
                : "https://openrouter.ai/api/v1/credits"))
        #expect(recorded[1].url?.absoluteString == (overridden
                ? "https://router.example.test/gateway/v1/key"
                : "https://openrouter.ai/api/v1/key"))
        #expect(recorded[2].url?.absoluteString == (overridden
                ? "https://router.example.test/gateway/v1/activity"
                : "https://openrouter.ai/api/v1/activity"))
        #expect(recorded[0].value(forHTTPHeaderField: "X-Title") == (overridden ? "CodexBar QA" : "CodexBar"))
        #expect(recorded[0].value(forHTTPHeaderField: "HTTP-Referer") ==
            (overridden ? "https://codexbar.example" : nil))
        #expect(recorded[1].value(forHTTPHeaderField: "X-Title") == nil)
        #expect(recorded[2].value(forHTTPHeaderField: "X-Title") == nil)
        #expect(recorded[1].timeoutInterval == 1)
        #expect(recorded[2].timeoutInterval == 1)
    }

    @Test
    func `OpenRouter credential adapter projects and validates configured origin`() throws {
        let endpointKey = OpenRouterSettingsReader.apiURLEnvironmentKey
        let configured = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [endpointKey: "https://environment.example"],
            provider: .openrouter,
            config: ProviderConfig(
                id: .openrouter,
                apiKey: "config-key",
                enterpriseHost: "https://config.example/v1"))

        #expect(configured[OpenRouterSettingsReader.envKey] == "config-key")
        #expect(configured[endpointKey] == "https://config.example/v1")
        let credentials = try #require(ProviderDescriptorRegistry.descriptor(for: .openrouter).credentials)
        #expect(credentials.validateConfig(ProviderConfig(
            id: .openrouter,
            enterpriseHost: "http://api.example")).contains { $0.code == "invalid_enterprise_host" })
        #expect(credentials.validateConfig(ProviderConfig(
            id: .openrouter,
            enterpriseHost: "api.example/v1")).isEmpty)
    }

    @Test(arguments: [false, true])
    func `ClawRouter cut-over honors default and overridden requests`(overridden: Bool) async throws {
        let baseURL = try #require(URL(string: overridden
                ? "https://router.example.test/gateway/v1"
                : "https://clawrouter.openclaw.ai"))
        let requests = PluginRequestRecorder()
        let transport = Self.recordingTransport(requests) { _ in Self.clawRouter }

        _ = try await ProviderPluginRuntime(bundledPlugin: "clawrouter", transport: transport).fetchUsage(
            settings: [ClawRouterSettingsReader.baseURLEnvironmentKey: baseURL.absoluteString],
            secrets: [ClawRouterSettingsReader.apiKeyEnvironmentKey: "fixture-key"])

        let recorded = await requests.requests
        #expect(recorded.count == 1)
        #expect(recorded[0].url?.absoluteString == (overridden
                ? "https://router.example.test/gateway/v1/usage"
                : "https://clawrouter.openclaw.ai/v1/usage"))
    }

    @Test
    func `Poe fixture matches the cut-over golden`() async throws {
        let transport = Self.transport { request in
            switch request.url?.path {
            case "/usage/current_balance": Self.poeBalance
            case "/usage/points_history": Self.poeHistory
            default: throw FixtureError.unexpectedURL(request.url)
            }
        }
        let now = Date(timeIntervalSince1970: 1_785_816_000)
        let script = try await ProviderPluginRuntime(bundledPlugin: "poe", transport: transport)
            .fetchUsage(secrets: ["POE_API_KEY": "fixture-key"], now: now)

        #expect(script.primary == nil)
        #expect(script.secondary == nil)
        #expect(script.tertiary == nil)
        #expect(script.providerCost == nil)
        #expect(script.identity?.providerID == .poe)
        #expect(script.identity?.loginMethod == "Balance: 2,500 points")
        #expect(try script.details == [Self.section(
            "Points",
            rows: [
                Self.row("Current balance", "2,500 points"),
                Self.row("Today", "0 points", "0 requests"),
                Self.row("Last 7 days", "20.5 points", "2 requests · $0.05"),
                Self.row("Last 30 days", "20.5 points", "2 requests · $0.05"),
                Self.row("Top model", "gpt-5", "12.5 points"),
                Self.row("Usage mix", "API: 12.5 points · Chat: 8 points"),
                Self.row("Recent activity", "08-03 16:00 · claude-sonnet-4", "8 points"),
                Self.row("08-02 16:00", "gpt-5", "12.5 points"),
            ],
            chart: Self.chart("Daily points", unit: "points", points: [
                ("2026-08-02", 12.5), ("2026-08-03", 8),
            ]))])
    }

    @Test
    func `zai fixture matches the cut-over golden`() async throws {
        let transport = Self.transport { request in
            if request.url?.path.hasSuffix("/quota/limit") == true {
                return Self.zaiQuota
            }
            if request.url?.path.hasSuffix("/model-usage") == true {
                return Self.zaiModelUsage
            }
            throw FixtureError.unexpectedURL(request.url)
        }
        let now = Date(timeIntervalSince1970: 1_785_816_000)
        let script = try await ProviderPluginRuntime(bundledPlugin: "zai", transport: transport)
            .fetchUsage(
                settings: [
                    "Z_AI_REGION": "global",
                    "Z_AI_USAGE_SCOPE": "personal",
                ],
                secrets: ["Z_AI_API_KEY": "fixture-key"],
                now: now)

        #expect(script.primary?.usedPercent == 25)
        #expect(script.primary?.windowMinutes == 300)
        #expect(script.primary?.resetsAt == Date(timeIntervalSince1970: 1_785_816_000))
        #expect(script.primary?.resetDescription == "5-hour")
        #expect(script.secondary?.usedPercent == 9)
        #expect(script.secondary?.windowMinutes == 10080)
        #expect(script.secondary?.resetsAt == Date(timeIntervalSince1970: 1_786_291_200))
        #expect(script.extraRateWindows?.first?.id == "zai-mcp")
        #expect(script.extraRateWindows?.first?.window.usedPercent == 22.400000000000002)
        #expect(script.identity?.providerID == .zai)
        #expect(script.identity?.loginMethod == "Pro")
        #expect(try script.details == [
            Self.section("Quota details", rows: [
                Self.row("Token quota", "9% used"),
                Self.row("Session token quota", "25% used"),
                Self.row("MCP quota", "22.4% used", "1000 limit · 776 remaining"),
                Self.row("search-prime", "210"),
                Self.row("web-reader", "14"),
            ]),
            Self.section(
                "Hourly tokens",
                rows: [
                    Self.row("glm-4.6", "100"),
                    Self.row("glm-4.5", "75"),
                ],
                chart: Self.chart("Hourly tokens", unit: "tokens", points: [
                    ("2026-08-02 08:00", 150), ("2026-08-02 09:00", 25),
                ])),
            Self.section(
                "Daily tokens",
                rows: [
                    Self.row("glm-4.6", "100"),
                    Self.row("glm-4.5", "75"),
                ],
                chart: Self.chart("Daily tokens", unit: "tokens", points: [
                    ("2026-08-02 08:00", 150), ("2026-08-02 09:00", 25),
                ])),
        ])
    }

    @Test
    func `zai CREDIT_LIMIT fixture matches the cut-over golden`() async throws {
        let transport = Self.transport { request in
            // Quota only: model-usage is intentionally unserved so the plugin's non-fatal
            // model-usage fetch fails and both paths produce only Quota details.
            if request.url?.path.hasSuffix("/quota/limit") == true {
                return Self.zaiCreditQuota
            }
            throw FixtureError.unexpectedURL(request.url)
        }
        let now = Date(timeIntervalSince1970: 1_786_073_946)
        let script = try await ProviderPluginRuntime(bundledPlugin: "zai", transport: transport)
            .fetchUsage(
                settings: [
                    "Z_AI_REGION": "global",
                    "Z_AI_USAGE_SCOPE": "personal",
                ],
                secrets: ["Z_AI_API_KEY": "fixture-key"],
                now: now)

        #expect(script.primary?.usedPercent == 5)
        #expect(script.primary?.windowMinutes == 300)
        #expect(script.primary?.resetDescription == "5-hour")
        #expect(script.secondary?.usedPercent == 10)
        #expect(script.secondary?.windowMinutes == 10080)
        #expect(script.identity?.providerID == .zai)
        #expect(script.identity?.loginMethod == "lite")
        #expect(try script.details == [
            Self.section("Quota details", rows: [
                Self.row("Credit quota", "10% used", "10000 limit · 9000 remaining"),
                Self.row("Session credit quota", "5% used", "2000 limit · 1900 remaining"),
            ]),
        ])
    }

    @Test
    func `OpenAI fixture has Swift core parity and stable details`() async throws {
        let transport = Self.transport { request in
            if request.url?.path.hasSuffix("/organization/costs") == true {
                return Self.openAICosts
            }
            if request.url?.path.hasSuffix("/usage/completions") == true {
                return Self.openAICompletions
            }
            throw FixtureError.unexpectedURL(request.url)
        }
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let swift = try await OpenAIAPIUsageFetcher.fetchUsage(
            apiKey: "fixture-key",
            session: transport,
            now: now,
            historyDays: 30).toUsageSnapshot()
        let script = try await ProviderPluginRuntime(bundledPlugin: "openai", transport: transport)
            .fetchUsage(
                settings: [
                    "OPENAI_HISTORY_DAYS": "30",
                    "OPENAI_ALLOW_BALANCE_FALLBACK": "1",
                ],
                secrets: ["OPENAI_API_KEY": "fixture-key"],
                now: now)

        Self.expectCoreParity(swift, script)
        #expect(try script.details == [
            Self.section(
                "Usage summary",
                rows: [
                    Self.row("Spend", "$14.75", "Last 30 days"),
                    Self.row("Requests", "10"),
                    Self.row("Tokens", "2,000", "1,300 input · 700 output"),
                    Self.row("Cached input", "250"),
                ],
                chart: Self.chart("Daily spend", unit: "USD", points: [("2023-11-14", 14.75)])),
            Self.section("Models", rows: [
                Self.row("gpt-5.2", "1,500 tokens", "7 requests"),
                Self.row("gpt-5.2-codex", "500 tokens", "3 requests"),
            ]),
            Self.section("Line items", rows: [
                Self.row("Text tokens", "$12.50"),
                Self.row("Web search tool calls", "$2.25"),
            ]),
        ])
    }

    private static func transport(
        body: @escaping @Sendable (URLRequest) throws -> String) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return try (Data(body(request).utf8), response)
        }
    }

    private static func recordingTransport(
        _ recorder: PluginRequestRecorder,
        body: @escaping @Sendable (URLRequest) throws -> String) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            await recorder.append(request)
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return try (Data(body(request).utf8), response)
        }
    }

    private static func row(_ label: String, _ value: String, _ secondary: String? = nil)
        throws -> ProviderDetailSection.Row
    {
        try ProviderDetailSection.Row(label: label, value: value, secondaryValue: secondary)
    }

    private static func chart(
        _ title: String,
        unit: String,
        points: [(String, Double)]) throws -> ProviderDetailSection.Chart
    {
        try ProviderDetailSection.Chart(
            kind: .bars,
            title: title,
            unit: unit,
            points: points.map { try ProviderDetailSection.Chart.Point(label: $0.0, value: $0.1) })
    }

    private static func section(
        _ title: String,
        rows: [ProviderDetailSection.Row],
        chart: ProviderDetailSection.Chart? = nil) throws -> ProviderDetailSection
    {
        try ProviderDetailSection(title: title, rows: rows, chart: chart)
    }

    private static func expectCoreParity(_ swift: UsageSnapshot, _ script: UsageSnapshot) {
        #expect(swift.primary == script.primary)
        #expect(swift.secondary == script.secondary)
        #expect(swift.tertiary == script.tertiary)
        #expect(swift.extraRateWindows == script.extraRateWindows)
        #expect(swift.subscriptionRenewsAt == script.subscriptionRenewsAt)
        #expect(swift.subscriptionExpiresAt == script.subscriptionExpiresAt)
        #expect(swift.providerCost?.used == script.providerCost?.used)
        #expect(swift.providerCost?.limit == script.providerCost?.limit)
        #expect(swift.providerCost?.currencyCode == script.providerCost?.currencyCode)
        #expect(swift.providerCost?.period == script.providerCost?.period)
        #expect(swift.providerCost?.resetsAt == script.providerCost?.resetsAt)
        #expect(swift.providerCost?.nextRegenAmount == script.providerCost?.nextRegenAmount)
        #expect(swift.identity?.providerID == script.identity?.providerID)
        #expect(swift.identity?.accountEmail == script.identity?.accountEmail)
        #expect(swift.identity?.accountOrganization == script.identity?.accountOrganization)
        #expect(swift.identity?.loginMethod == script.identity?.loginMethod)
        #expect(swift.identity?.accountID == script.identity?.accountID)
    }

    private static func environment(for provider: UsageProvider) -> [String: String] {
        switch provider {
        case .openai: [OpenAIAPISettingsReader.apiKeyEnvironmentKey: "fixture-key"]
        case .openrouter: [OpenRouterSettingsReader.envKey: "fixture-key"]
        case .poe: [PoeSettingsReader.apiKeyEnvironmentKey: "fixture-key"]
        case .clawrouter: [ClawRouterSettingsReader.apiKeyEnvironmentKey: "fixture-key"]
        default: [:]
        }
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
            claudeFetcher: FixtureClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private enum FixtureError: Error {
        case unexpectedURL(URL?)
    }

    private static let openRouterCredits = #"{"data":{"total_credits":100,"total_usage":40}}"#
    private static let openRouterKey = #"""
    {"data":{"limit":20,"limit_remaining":15,"limit_reset":"monthly","usage":5,
    "usage_daily":1,"usage_weekly":2,"usage_monthly":4,
    "rate_limit":{"requests":120,"interval":"10s"}}}
    """#
    private static let openRouterActivity = #"""
    {"data":[
      {"date":"2026-08-01","model":"anthropic/claude-sonnet-4-6","prompt_tokens":10,
       "completion_tokens":20,"reasoning_tokens":5,"requests":2,"usage":0.01},
      {"date":"2026-08-01","model":"anthropic/claude-sonnet-4-6","prompt_tokens":5,
       "completion_tokens":10,"reasoning_tokens":2,"requests":1,"usage":0.005}
    ]}
    """#
    private static let poeBalance = #"{"current_point_balance":2500}"#
    private static let poeHistory = #"""
    {"data":[
      {"query_id":"p1","creation_time":1785686400000000,"bot_name":"gpt-5","usage_type":"API",
       "cost_points":12.5,"cost_usd":0.03},
      {"query_id":"p2","creation_time":1785772800000000,"bot_name":"claude-sonnet-4","usage_type":"Chat",
       "cost_points":8,"cost_usd":0.02}
    ],"next_cursor":null}
    """#
    private static let zaiQuota = #"""
    {"code":200,"msg":"success","success":true,"data":{"planName":"Pro","limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1785816000000},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9,"nextResetTime":1786291200000},
      {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":224,"remaining":776,
       "percentage":22,"usageDetails":[{"modelCode":"search-prime","usage":210},
       {"modelCode":"web-reader","usage":14}]}
    ]}}
    """#
    private static let zaiCreditQuota = #"""
    {"code":200,"msg":"success","success":true,"data":{"level":"lite","limits":[
      {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":100,"remaining":1900,
       "percentage":5,"nextResetTime":1786073946574},
      {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":1000,"remaining":9000,
       "percentage":10,"nextResetTime":1786660486998}
    ]}}
    """#
    private static let zaiModelUsage = #"""
    {"code":200,"msg":"success","success":true,"data":{
      "x_time":["2026-08-02 08:00","2026-08-02 09:00"],
      "modelDataList":[{"modelName":"glm-4.6","tokensUsage":[100,null]},
      {"modelName":"glm-4.5","tokensUsage":[50,25]}]}}
    """#
    private static let clawRouter = #"""
    {"budget":{"configured":true,"ledger":"durable_object","windowKey":"fixture/2026-07",
      "limitMicros":25000000,"spentMicros":6000,"remainingMicros":24994000},
     "usage":{"summary":{"requestCount":6,"successCount":5,"errorCount":1,"inputTokens":50000,
       "outputTokens":4191,"totalTokens":54191,"actualCostMicros":6000},"providers":[
       {"provider":"anthropic","requestCount":2,"successCount":2,"errorCount":0,
        "totalTokens":12191,"actualCostMicros":2000},
       {"provider":"openai","requestCount":4,"successCount":3,"errorCount":1,
        "totalTokens":42000,"actualCostMicros":4000}]}}
    """#
    private static let openAICosts = #"""
    {"object":"page","data":[{"object":"bucket","start_time":1700000000,"end_time":1700086400,"results":[
      {"amount":{"value":12.5,"currency":"usd"},"line_item":"Text tokens"},
      {"amount":{"value":"2.25","currency":"usd"},"line_item":"Web search tool calls"}
    ]}],"has_more":false,"next_page":null}
    """#
    private static let openAICompletions = #"""
    {"object":"page","data":[{"object":"bucket","start_time":1700000000,"end_time":1700086400,"results":[
      {"input_tokens":1000,"input_cached_tokens":250,"output_tokens":500,"num_model_requests":7,
       "model":"gpt-5.2"},
      {"input_tokens":300,"output_tokens":200,"num_model_requests":3,"model":"gpt-5.2-codex"}
    ]}],"has_more":false,"next_page":null}
    """#
}

private struct FixtureClaudeFetcher: ClaudeUsageFetching {
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

private actor PluginRequestRecorder {
    private(set) var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        self.requests.append(request)
    }
}
