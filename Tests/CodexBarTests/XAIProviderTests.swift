import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct XAIProviderTests {
    @Test
    func `settings reader trims whitespace and quotes`() {
        #expect(
            XAISettingsReader.apiKey(environment: [
                XAISettingsReader.apiKeyEnvironmentKey: "  'fixture-management-key'  ",
            ]) == "fixture-management-key")
        #expect(XAISettingsReader.apiKey(environment: [:]) == nil)
        #expect(
            XAISettingsReader.teamID(environment: [
                XAISettingsReader.teamIDEnvironmentKey: " \"team-1234\" ",
            ]) == "team-1234")
        #expect(XAISettingsReader.teamID(environment: [:]) == nil)
    }

    @Test
    func `descriptor preflight preserves team ID validation errors`() async throws {
        let missing = Self.context(environment: [
            XAISettingsReader.apiKeyEnvironmentKey: "fixture-management-key",
        ])
        let invalid = Self.context(environment: [
            XAISettingsReader.apiKeyEnvironmentKey: "fixture-management-key",
            XAISettingsReader.teamIDEnvironmentKey: "team/../other",
        ])
        let strategy = try #require(
            await XAIProviderDescriptor.descriptor.fetchPlan.pipeline
                .resolveStrategies(missing).first)

        for (context, expected) in [
            (missing, XAISettingsError.missingTeamID), (invalid, .invalidTeamID),
        ] {
            do {
                _ = try await strategy.fetch(context)
                Issue.record("Expected xAI team ID validation error")
            } catch let error as XAISettingsError {
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test
    func `balance and usage requests match the native golden`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.scheme == "https")
            #expect(url.host == "management-api.x.ai")
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url.query == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-management-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            switch url.path {
            case "/v1/billing/teams/team-1234/prepaid/balance":
                #expect(request.httpMethod == "GET")
                return Self.response(url: url, body: Self.balanceFixture)
            case "/v1/billing/teams/team-1234/usage":
                #expect(request.httpMethod == "POST")
                let body = try #require(request.httpBody)
                let payload = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                let analytics = try #require(payload["analyticsRequest"] as? [String: Any])
                let timeRange = try #require(analytics["timeRange"] as? [String: Any])
                #expect(timeRange["startTime"] as? String == "2026-12-17 00:00:00")
                #expect(timeRange["endTime"] as? String == "2027-01-15 08:00:00")
                #expect(timeRange["timezone"] as? String == "Etc/GMT")
                #expect(analytics["timeUnit"] as? String == "TIME_UNIT_DAY")
                return Self.response(url: url, body: Self.usageFixture)
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }

        let snapshot = try await Self.runtime(transport: transport).fetchUsage(
            settings: ["XAI_TEAM_ID": "team-1234"],
            secrets: ["XAI_MANAGEMENT_API_KEY": "fixture-management-key"],
            now: now)

        #expect(await transport.requests().count == 2)
        #expect(snapshot.providerCost?.used == 10)
        #expect(snapshot.detailRow(label: "Last 30 days")?.value == "$1.76")
        #expect(
            snapshot.details.first?.chart?.points.map(\.label) == [
                "2027-01-13", "2027-01-14", "2027-01-15",
            ])
        #expect(snapshot.dataConfidence == .exact)
    }

    @Test(arguments: [
        (#"{"total":{"val":"2500"}}"#, -25.0),
        (#"{"total":{"val":"0"}}"#, 0.0),
        (#"{"total":{"val":"-333"}}"#, 3.33),
    ])
    func `ledger balances match the production goldens`(body: String, expected: Double) async throws {
        let snapshot = try await Self.fetch(balanceBody: body)
        #expect(snapshot.providerCost?.used == expected)
    }

    @Test
    func `malformed balance is a classified parse failure`() async throws {
        do {
            _ = try await Self.fetch(balanceBody: #"{"total":{"val":"n/a"}}"#)
            Issue.record("Expected parse failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == .parseFailure)
            #expect(error.message.contains("balance total.val"))
        }
    }

    @Test(arguments: [
        (401, ProviderFetchClassifiedError.Kind.authenticationExpired),
        (403, .authenticationExpired),
        (404, .apiFailure),
        (429, .rateLimited),
        (503, .apiFailure),
    ])
    func `balance errors retain classified surfaces`(
        status: Int,
        kind: ProviderFetchClassifiedError.Kind) async throws
    {
        do {
            _ = try await Self.fetch(balanceStatus: status)
            Issue.record("Expected classified xAI failure")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        }
    }

    @Test
    func `history failure preserves balance and partial history lowers confidence`() async throws {
        let degraded = try await Self.fetch(usageStatus: 500)
        #expect(degraded.providerCost?.used == 10)
        #expect(degraded.details.first?.chart == nil)
        #expect(degraded.dataConfidence == .exact)

        let partial = try await Self.fetch(
            usageBody: Self.usageFixture.replacingOccurrences(
                of: #""limitReached": false"#,
                with: #""limitReached": true"#))
        #expect(partial.detailRow(label: "Last 30 days (partial)")?.value == "$1.76")
        #expect(partial.dataConfidence == .estimated)
    }

    @Test @MainActor
    func `descriptor registry menu card and CLI retain xAI presentation`() async throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .xai)
        #expect(descriptor.metadata.displayName == "xAI")
        #expect(descriptor.metadata.dashboardURL == "https://console.x.ai")
        #expect(
            descriptor.metadata.subscriptionDashboardURL == XAIOAuthUsageMapper.superGrokUsageDashboardURL)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api, .oauth, .web])
        #expect(
            try #require(ProviderImplementationRegistry.implementation(for: .xai))
                is XAIProviderImplementation)

        let snapshot = try await Self.fetch()
        let model = UsageMenuCardView.Model.make(
            .init(
                provider: .xai,
                metadata: descriptor.metadata,
                snapshot: snapshot,
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: nil,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: true,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: false,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(model.providerCost?.spendLine == "Balance: $10.00")

        let text = CLIRenderer.renderText(
            provider: .xai,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "xAI (api)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))
        #expect(text.contains("Prepaid balance: $10.00"))
        #expect(text.contains("Plan: Management API"))
        #expect(!text.contains("Cost:"))
    }

    @Test
    func `config API key and team ID project into the fetch environment`() {
        let environment = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                XAISettingsReader.apiKeyEnvironmentKey: "environment-key",
                XAISettingsReader.teamIDEnvironmentKey: "environment-team",
            ],
            provider: .xai,
            config: ProviderConfig(id: .xai, apiKey: "config-key", workspaceID: "config-team"))

        #expect(XAISettingsReader.apiKey(environment: environment) == "config-key")
        #expect(XAISettingsReader.teamID(environment: environment) == "config-team")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .xai))
    }

    @Test
    func `auto cookie source does not mark xAI unavailable`() throws {
        let suite = "XAIProviderTests-auto-cookie-available"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.xaiUsageDataSource = .auto
        settings.xaiCookieSource = .auto
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            environmentBase: [:])

        #expect(
            XAIProviderImplementation().isAvailable(
                context: ProviderAvailabilityContext(
                    provider: .xai,
                    settings: settings,
                    environment: [:])))
        #expect(store.isProviderAvailable(.xai))
        #expect(store.unavailableMessage(for: .xai) == nil)
    }

    private static func fetch(
        balanceBody: String = balanceFixture,
        balanceStatus: Int = 200,
        usageBody: String = usageFixture,
        usageStatus: Int = 200) async throws -> UsageSnapshot
    {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/prepaid/balance") {
                return Self.response(url: url, body: balanceBody, statusCode: balanceStatus)
            }
            return Self.response(url: url, body: usageBody, statusCode: usageStatus)
        }
        return try await Self.runtime(transport: transport).fetchUsage(
            settings: ["XAI_TEAM_ID": "team-1234"],
            secrets: ["XAI_MANAGEMENT_API_KEY": "fixture-management-key"],
            now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static func runtime(transport: any ProviderHTTPTransport) throws -> ProviderPluginRuntime {
        try ProviderPluginRuntime(bundledPlugin: "xai", transport: transport)
    }

    private static func context(environment: [String: String]) -> ProviderFetchContext {
        ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: XAITestClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
    }

    private static func response(url: URL, body: String, statusCode: Int = 200) -> (Data, URLResponse) {
        let response =
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]) ?? HTTPURLResponse()
        return (Data(body.utf8), response)
    }

    static let balanceFixture = #"{"total":{"val":"-1000"}}"#

    static let usageFixture = #"""
    {
      "timeSeries": [
        {"dataPoints": [
          {"timestamp":"2027-01-13T00:00:00Z","values":[0.75973725]},
          {"timestamp":"2027-01-14T00:00:00Z","values":[0.5]},
          {"timestamp":"2027-01-15T00:00:00Z","values":[0]}
        ]},
        {"dataPoints": [
          {"timestamp":"2027-01-13T00:00:00Z","values":[0.5]},
          {"timestamp":"2027-01-14T00:00:00Z","values":[0]},
          {"timestamp":"2027-01-15T00:00:00Z","values":[0]}
        ]}
      ],
      "limitReached": false
    }
    """#
}

private struct XAITestClaudeFetcher: ClaudeUsageFetching {
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
