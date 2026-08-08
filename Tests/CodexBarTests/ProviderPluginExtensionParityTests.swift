// swiftlint:disable line_length multiline_arguments
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ProviderPluginExtensionParityTests {
    @Test
    func `Qoder cookie plugin matches Swift generic projection`() async throws {
        let fixture = #"{"total_quota":{"quota_summary":{"used_value":25,"limit_value":100,"remaining_value":75,"unit":"credits"}},"shared_quota":{"quota_summary":{"used_value":5,"limit_value":20,"remaining_value":15}},"next_reset_at":"2027-01-15T00:00:00Z"}"#
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let swift = try QoderUsageFetcher.parseUsage(data: Data(fixture.utf8), now: now).toUsageSnapshot()
        let script = try await ProviderPluginRuntime(
            bundledPlugin: "qoder",
            transport: Self.transport { _ in fixture })
            .fetchUsage(now: now, cookieResolver: { _, _ in "session=fixture" })

        Self.expectCoreParity(swift, script)
    }

    @Test
    func `Manus cookie plugin matches Swift generic projection`() async throws {
        let fixture = #"{"totalCredits":1200,"freeCredits":200,"periodicCredits":300,"refreshCredits":40,"maxRefreshCredits":100,"proMonthlyCredits":1000,"eventCredits":0,"addonCredits":0,"nextRefreshTime":"2027-01-15T00:00:00Z","refreshInterval":"daily"}"#
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let swift = try ManusUsageFetcher.parseResponse(Data(fixture.utf8)).toUsageSnapshot(now: now)
        let script = try await ProviderPluginRuntime(
            bundledPlugin: "manus",
            transport: Self.transport { _ in fixture })
            .fetchUsage(now: now, cookieResolver: { _, _ in "session_id=fixture-session" })

        Self.expectCoreParity(swift, script)
    }

    @Test
    func `Perplexity cookie plugin matches Swift generic projection`() async throws {
        let fixture = #"{"balance_cents":900,"renewal_date_ts":1893456000,"current_period_purchased_cents":200,"credit_grants":[{"type":"recurring","amount_cents":1000},{"type":"promotional","amount_cents":300,"expires_at_ts":1893456000},{"type":"purchased","amount_cents":200}],"total_usage_cents":1100}"#
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let swift = try PerplexityUsageFetcher._parseResponseForTesting(Data(fixture.utf8), now: now)
            .toUsageSnapshot()
        let script = try await ProviderPluginRuntime(
            bundledPlugin: "perplexity",
            transport: Self.transport { _ in fixture })
            .fetchUsage(now: now, cookieResolver: { _, _ in "__Secure-next-auth.session-token=fixture" })

        Self.expectCoreParity(swift, script)
    }

    @Test
    func `T3 Chat cookie plugin matches Swift generic projection`() async throws {
        let fixture = #"{"json":[2,0,[[{"subTier":"pro","subscription":{"productName":"pro","currentPeriodEnd":1780763009000},"usageBand":"max","usageFourHourPercentage":12.5,"usageMonthPercentage":34.25,"usageFourHourNextResetAt":1779366216920}]]]}"#
        let now = Date(timeIntervalSince1970: 1_778_000_000)
        let swift = try T3ChatUsageParser.parseJSONLines(fixture, now: now).toUsageSnapshot()
        let script = try await ProviderPluginRuntime(
            bundledPlugin: "t3chat",
            transport: Self.textTransport(body: fixture))
            .fetchUsage(now: now, cookieResolver: { _, _ in "session=fixture" })

        Self.expectCoreParity(swift, script)
    }

    @Test
    func `Deepgram plugin matches the cut-over details golden`() async throws {
        let transport = Self.transport { request in
            switch request.url?.path {
            case "/v1/projects":
                #"{"projects":[{"project_id":"project-a","name":"Alpha"}]}"#
            case "/v1/projects/project-a/usage/breakdown":
                #"{"start":"2026-07-01","end":"2026-07-31","results":[{"hours":1.5,"total_hours":2,"tokens_in":100,"tokens_out":50,"requests":3}]}"#
            default:
                throw URLError(.badURL)
            }
        }
        let script = try await ProviderPluginRuntime(bundledPlugin: "deepgram", transport: transport)
            .fetchUsage(secrets: ["DEEPGRAM_API_KEY": "fixture-key"])

        #expect(script.primary == nil)
        #expect(script.identity?.loginMethod == "Project: Alpha")
        #expect(try script.details == [ProviderDetailSection(
            title: "Usage summary",
            rows: [
                .init(label: "Requests", value: "3"),
                .init(label: "Audio", value: "1.5 hours", secondaryValue: "2 billable hours"),
                .init(label: "Tokens", value: "150"),
                .init(label: "Period", value: "2026-07-01 to 2026-07-31"),
            ])])
    }

    @Test
    func `sub2api plugin matches the cut-over details golden`() async throws {
        let fixture = #"{"mode":"quota_limited","isValid":true,"planName":"Team","quota":{"limit":100,"used":25,"remaining":75,"unit":"USD"},"usage":{"today":{"requests":4,"total_tokens":1200,"actual_cost":1.25}}}"#
        let transport = Self.transport { _ in fixture }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let script = try await ProviderPluginRuntime(bundledPlugin: "sub2api", transport: transport)
            .fetchUsage(
                settings: ["SUB2API_BASE_URL": "http://127.0.0.1:8787"],
                secrets: ["SUB2API_API_KEY": "fixture-key"],
                now: now)

        #expect(script.primary?.usedPercent == 25)
        #expect(script.secondary == nil)
        #expect(script.tertiary == nil)
        #expect(script.identity?.accountOrganization == "Team")
        #expect(script.identity?.loginMethod == "Team")
        #expect(script.dataConfidence == .exact)
        #expect(try script.details == [ProviderDetailSection(
            title: "Usage summary",
            rows: [
                .init(label: "Today requests", value: "4"),
                .init(label: "Today tokens", value: "1,200", secondaryValue: "$1.25"),
            ])])
    }

    @Test
    func `xAI plugin matches generic Swift projection and details golden`() async throws {
        let transport = Self.transport { request in
            if request.url?.path.hasSuffix("/prepaid/balance") == true {
                return #"{"total":{"val":"-1000"}}"#
            }
            return #"{"timeSeries":[{"dataPoints":[{"timestamp":"2027-01-15T00:00:00Z","values":[1.5]}]}],"limitReached":false}"#
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let swift = try await XAIBillingFetcher.fetchUsage(
            managementKey: "fixture-key",
            teamID: "team-1234",
            transport: transport,
            now: now).toUsageSnapshot()
        let script = try await ProviderPluginRuntime(bundledPlugin: "xai", transport: transport)
            .fetchUsage(
                settings: ["XAI_TEAM_ID": "team-1234"],
                secrets: ["XAI_MANAGEMENT_API_KEY": "fixture-key"],
                now: now)

        #expect(script.primary == swift.primary)
        #expect(script.providerCost == swift.providerCost)
        #expect(script.identity?.loginMethod == swift.identity?.loginMethod)
        #expect(script.details == swift.details)
        let details = try #require(script.details.first)
        #expect(details.title == "Billing summary")
        #expect(try details.rows.first == .init(label: "Prepaid balance", value: "$10.00"))
        #expect(try details.rows.last == .init(label: "Last 30 days", value: "$1.50"))
        #expect(try details.chart?.points == [.init(label: "2027-01-15", value: 1.5)])
    }

    private static func transport(
        handler: @escaping @Sendable (URLRequest) throws -> String) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            let body = try handler(request)
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]))
            return (Data(body.utf8), response)
        }
    }

    private static func textTransport(body: String) -> ProviderHTTPTransportHandler {
        ProviderHTTPTransportHandler { request in
            let response = try #require(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/jsonl"]))
            return (Data(body.utf8), response)
        }
    }

    private static func expectCoreParity(_ swift: UsageSnapshot, _ script: UsageSnapshot) {
        #expect(script.primary == swift.primary)
        #expect(script.secondary == swift.secondary)
        #expect(script.tertiary == swift.tertiary)
        #expect(script.extraRateWindows == swift.extraRateWindows)
        #expect(script.providerCost == swift.providerCost)
        #expect(script.subscriptionRenewsAt == swift.subscriptionRenewsAt)
        #expect(script.subscriptionExpiresAt == swift.subscriptionExpiresAt)
        #expect(script.identity?.accountEmail == swift.identity?.accountEmail)
        #expect(script.identity?.accountOrganization == swift.identity?.accountOrganization)
        #expect(script.identity?.loginMethod == swift.identity?.loginMethod)
        #expect(script.identity?.accountID == swift.identity?.accountID)
    }
}

// swiftlint:enable line_length multiline_arguments
