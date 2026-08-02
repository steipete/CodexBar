import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

struct XAIProviderTests {
    // MARK: - Settings reader

    @Test
    func `settings reader trims whitespace and quotes`() {
        #expect(XAISettingsReader.apiKey(environment: [
            XAISettingsReader.apiKeyEnvironmentKey: "  'fixture-management-key'  ",
        ]) == "fixture-management-key")
        #expect(XAISettingsReader.apiKey(environment: [:]) == nil)
        #expect(XAISettingsReader.apiKey(environment: [
            XAISettingsReader.apiKeyEnvironmentKey: "   ",
        ]) == nil)
        #expect(XAISettingsReader.teamID(environment: [
            XAISettingsReader.teamIDEnvironmentKey: " \"team-1234\" ",
        ]) == "team-1234")
        #expect(XAISettingsReader.teamID(environment: [:]) == nil)
    }

    // MARK: - Fetch: request shape

    @Test
    func `balance and usage requests use documented endpoints and bearer auth`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.scheme == "https")
            #expect(url.host == "management-api.x.ai")
            #expect(url.user == nil)
            #expect(url.password == nil)
            #expect(url.query == nil)
            #expect(url.fragment == nil)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-management-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            switch url.path {
            case "/v1/billing/teams/team-1234/prepaid/balance":
                #expect(request.httpMethod == "GET")
                return Self.response(url: url, body: Self.balanceFixture)
            case "/v1/billing/teams/team-1234/usage":
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body = try #require(request.httpBody)
                let payload = try #require(
                    try JSONSerialization.jsonObject(with: body) as? [String: Any])
                let analytics = try #require(payload["analyticsRequest"] as? [String: Any])
                let timeRange = try #require(analytics["timeRange"] as? [String: Any])
                #expect(timeRange["startTime"] as? String == "2026-12-17 00:00:00")
                #expect(timeRange["endTime"] as? String == "2027-01-15 08:00:00")
                #expect(timeRange["timezone"] as? String == "Etc/GMT")
                #expect(analytics["timeUnit"] as? String == "TIME_UNIT_DAY")
                let values = try #require(analytics["values"] as? [[String: Any]])
                #expect(values.count == 1)
                #expect(values.first?["name"] as? String == "usd")
                #expect(values.first?["aggregation"] as? String == "AGGREGATION_SUM")
                #expect(analytics["groupBy"] as? [String] == [])
                #expect(analytics["filters"] as? [String] == [])
                return Self.response(url: url, body: Self.usageFixture)
            default:
                Issue.record("unexpected request path \(url.path)")
                throw URLError(.badURL)
            }
        }

        let usage = try await XAIBillingFetcher.fetchUsage(
            managementKey: "fixture-management-key",
            teamID: "team-1234",
            transport: transport,
            now: now)

        #expect(await transport.requests().count == 2)
        // Docs example: a $10 top-up shows total.val = "-1000" (string USD cents,
        // inverted ledger), so the remaining balance is +$10.00.
        #expect(usage.balanceUSD == 10.0)
        #expect(!usage.limitReached)
        #expect(usage.historyDays == 30)
        #expect(usage.updatedAt == now)
        // Two series contribute to the same days; sums are per-day and zeros stay dense.
        #expect(usage.daily.map(\.day) == ["2027-01-13", "2027-01-14", "2027-01-15"])
        let costs = usage.daily.map(\.costUSD)
        #expect(costs.count == 3)
        #expect(abs(costs[0] - 1.25973725) < 1e-9)
        #expect(costs[1] == 0.5)
        #expect(costs[2] == 0)
    }

    @Test
    func `management key is only sent as a bearer header`() async throws {
        let transport = Self.happyTransport()

        _ = try await XAIBillingFetcher.fetchUsage(
            managementKey: "fixture-management-key",
            teamID: "team-1234",
            transport: transport)

        for request in await transport.requests() {
            let url = try #require(request.url)
            #expect(!url.absoluteString.contains("fixture-management-key"))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-management-key")
        }
    }

    @Test
    func `team id is encoded as a single path component`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(!url.absoluteString.contains("team one"))
            #expect(url.absoluteString.contains("team%20one"))
            if url.path.hasSuffix("/prepaid/balance") {
                return Self.response(url: url, body: Self.balanceFixture)
            }
            return Self.response(url: url, body: Self.usageFixture)
        }

        _ = try await XAIBillingFetcher.fetchUsage(
            managementKey: "fixture-management-key",
            teamID: "team one",
            transport: transport)
    }

    @Test
    func `team id with path separators is rejected`() async {
        await #expect {
            _ = try await XAIBillingFetcher.fetchUsage(
                managementKey: "fixture-management-key",
                teamID: "team/../other",
                transport: Self.happyTransport())
        } throws: { error in
            error as? XAIBillingError == .invalidTeamID
        }
    }

    // MARK: - Fetch: balance mapping

    @Test
    func `positive ledger total maps to a negative remaining balance`() async throws {
        let usage = try await Self.fetch(balanceBody: #"{"changes":[],"total":{"val":"2500"}}"#)
        #expect(usage.balanceUSD == -25.0)
    }

    @Test
    func `zero total maps to a zero balance`() async throws {
        let usage = try await Self.fetch(balanceBody: #"{"changes":[],"total":{"val":"0"}}"#)
        #expect(usage.balanceUSD == 0)
    }

    @Test
    func `fractional cent strings convert exactly`() async throws {
        let usage = try await Self.fetch(balanceBody: #"{"changes":[],"total":{"val":"-333"}}"#)
        #expect(usage.balanceUSD == 3.33)
    }

    @Test
    func `malformed 200 balance is a parse error not a zero balance`() async {
        for body in [
            "{}",
            #"{"total":{}}"#,
            #"{"total":{"val":""}}"#,
            #"{"total":{"val":"n/a"}}"#,
            #"{"total":{"val":"12abc"}}"#,
            #"{"error":"forbidden"}"#,
        ] {
            await #expect {
                _ = try await Self.fetch(balanceBody: body)
            } throws: { error in
                guard case .parseFailed = error as? XAIBillingError else { return false }
                return true
            }
        }
    }

    // MARK: - Fetch: usage mapping

    @Test
    func `usage history failure preserves the balance`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/prepaid/balance") {
                return Self.response(url: url, body: Self.balanceFixture)
            }
            return Self.response(url: url, body: #"{"error":"unavailable"}"#, statusCode: 500)
        }

        let usage = try await XAIBillingFetcher.fetchUsage(
            managementKey: "fixture-management-key",
            teamID: "team-1234",
            transport: transport)

        #expect(usage.balanceUSD == 10.0)
        #expect(usage.daily.isEmpty)
        #expect(!usage.limitReached)
    }

    @Test
    func `usage auth failure is not hidden by the balance success`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/prepaid/balance") {
                return Self.response(url: url, body: Self.balanceFixture)
            }
            return Self.response(url: url, body: #"{"error":"unauthorized"}"#, statusCode: 401)
        }

        await #expect {
            _ = try await XAIBillingFetcher.fetchUsage(
                managementKey: "fixture-management-key",
                teamID: "team-1234",
                transport: transport)
        } throws: { error in
            error as? XAIBillingError == .authenticationRejected
        }
    }

    @Test
    func `limitReached marks the history partial`() async throws {
        let body = Self.usageFixture.replacingOccurrences(
            of: #""limitReached": false"#,
            with: #""limitReached": true"#)
        let usage = try await Self.fetch(usageBody: body)
        #expect(usage.limitReached)
    }

    @Test
    func `malformed usage payload degrades to balance only`() async throws {
        let usage = try await Self.fetch(usageBody: #"{"object":"list"}"#)
        #expect(usage.balanceUSD == 10.0)
        #expect(usage.daily.isEmpty)
    }

    // MARK: - Fetch: errors

    @Test
    func `missing or whitespace credential fails clearly`() async {
        await #expect {
            _ = try await XAIBillingFetcher.fetchUsage(
                managementKey: "   ",
                teamID: "team-1234",
                transport: Self.happyTransport())
        } throws: { error in
            error as? XAIBillingError == .notConfigured
        }
        #expect(XAIBillingError.notConfigured.errorDescription?.contains("XAI_MANAGEMENT_API_KEY") == true)
    }

    @Test
    func `missing team id fails with actionable guidance`() async {
        await #expect {
            _ = try await XAIBillingFetcher.fetchUsage(
                managementKey: "fixture-management-key",
                teamID: "  ",
                transport: Self.happyTransport())
        } throws: { error in
            error as? XAIBillingError == .missingTeamID
        }
        #expect(XAIBillingError.missingTeamID.errorDescription?.contains("XAI_TEAM_ID") == true)
    }

    @Test
    func `401 maps to management key guidance`() async {
        await #expect {
            _ = try await Self.fetch(balanceBody: #"{"error":"unauthorized"}"#, balanceStatus: 401)
        } throws: { error in
            error as? XAIBillingError == .authenticationRejected
        }
        #expect(XAIBillingError.authenticationRejected.errorDescription?.contains("Management") == true)
    }

    @Test
    func `403 maps to management key guidance`() async {
        await #expect {
            _ = try await Self.fetch(balanceBody: #"{"error":"forbidden"}"#, balanceStatus: 403)
        } throws: { error in
            error as? XAIBillingError == .authenticationRejected
        }
    }

    @Test
    func `404 maps to team id guidance`() async {
        await #expect {
            _ = try await Self.fetch(balanceBody: #"{"error":"not found"}"#, balanceStatus: 404)
        } throws: { error in
            error as? XAIBillingError == .teamNotFound
        }
        #expect(XAIBillingError.teamNotFound.errorDescription?.contains("team") == true)
    }

    @Test
    func `429 is surfaced as rate limiting`() async {
        await #expect {
            _ = try await Self.fetch(balanceBody: #"{"error":"slow down"}"#, balanceStatus: 429)
        } throws: { error in
            error as? XAIBillingError == .rateLimited
        }
    }

    @Test
    func `unexpected status is reported with its code`() async {
        await #expect {
            _ = try await Self.fetch(balanceBody: #"{"error":"boom"}"#, balanceStatus: 503)
        } throws: { error in
            error as? XAIBillingError == .apiError(503)
        }
    }

    // MARK: - Snapshot projections

    @Test
    func `usage snapshot projects balance and history into shared models`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 UTC
        let usage = XAIUsageSnapshot(
            balanceUSD: 7.36,
            daily: [
                .init(day: "2027-01-15", costUSD: 0.25),
                .init(day: "2027-01-14", costUSD: 1.5),
            ],
            updatedAt: now)
        let snapshot = usage.toUsageSnapshot()

        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.providerCost?.used == 7.36)
        #expect(snapshot.providerCost?.limit == 0)
        #expect(snapshot.providerCost?.currencyCode == "USD")
        #expect(snapshot.providerCost?.period == "Prepaid credits")
        #expect(snapshot.xaiUsage == usage)
        #expect(snapshot.identity?.providerID == .xai)
        #expect(snapshot.identity?.loginMethod == "Management API")
        #expect(snapshot.dataConfidence == .exact)

        let token = try #require(usage.costHistorySnapshot())
        // Ascending day order; a nil costUSD would silently drop the day from the chart.
        #expect(token.daily.map(\.date) == ["2027-01-14", "2027-01-15"])
        #expect(token.daily.compactMap(\.costUSD) == [1.5, 0.25])
        #expect(token.sessionCostUSD == 0.25)
        #expect(token.last30DaysCostUSD == 1.75)
        #expect(token.currencyCode == "USD")
        #expect(token.historyDays == 30)
        #expect(token.sessionTokens == nil)
        #expect(token.last30DaysTokens == nil)
    }

    @Test
    func `limitReached lowers confidence and labels the history partial`() throws {
        let usage = XAIUsageSnapshot(
            balanceUSD: 1,
            daily: [.init(day: "2027-01-15", costUSD: 0.5)],
            limitReached: true,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(usage.toUsageSnapshot().dataConfidence == .estimated)
        let token = try #require(usage.costHistorySnapshot())
        #expect(token.historyLabel == "Last 30 days (partial)")
    }

    @Test
    func `empty history yields no cost history snapshot`() {
        let usage = XAIUsageSnapshot(
            balanceUSD: 1,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(usage.costHistorySnapshot() == nil)
        #expect(usage.toUsageSnapshot().providerCost?.used == 1)
    }

    @Test
    func `snapshot round trips through Codable with xai usage preserved`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = XAIUsageSnapshot(
            balanceUSD: 7.36,
            daily: [.init(day: "2027-01-15", costUSD: 0.25)],
            updatedAt: now)
        let encoded = try JSONEncoder().encode(usage.toUsageSnapshot())
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: encoded)
        #expect(decoded.xaiUsage == usage)
        #expect(decoded.providerCost?.used == 7.36)
    }

    // MARK: - Registration and wiring

    @Test @MainActor
    func `descriptor and app registry include xai`() throws {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .xai)
        #expect(descriptor.metadata.displayName == "xAI")
        #expect(descriptor.metadata.cliName == "xai")
        #expect(descriptor.metadata.defaultEnabled == false)
        #expect(!descriptor.metadata.supportsCredits)
        #expect(!descriptor.tokenCost.supportsTokenCost)
        #expect(descriptor.fetchPlan.sourceModes == [.auto, .api])
        #expect(descriptor.cli.aliases.isEmpty)

        let implementation = try #require(ProviderImplementationRegistry.implementation(for: .xai))
        #expect(implementation is XAIProviderImplementation)
    }

    @Test
    func `config API key and team ID project into the fetch environment`() {
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [
                XAISettingsReader.apiKeyEnvironmentKey: "environment-key",
                XAISettingsReader.teamIDEnvironmentKey: "environment-team",
            ],
            provider: .xai,
            config: ProviderConfig(id: .xai, apiKey: "config-key", workspaceID: "config-team"))

        #expect(XAISettingsReader.apiKey(environment: env) == "config-key")
        #expect(XAISettingsReader.teamID(environment: env) == "config-team")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .xai))
    }

    @Test @MainActor
    func `menu card renders the prepaid balance line`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = XAIUsageSnapshot(
            balanceUSD: 7.36,
            daily: [.init(day: "2027-01-15", costUSD: 0.25)],
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .xai,
            metadata: XAIProviderDescriptor.descriptor.metadata,
            snapshot: usage.toUsageSnapshot(),
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
            now: now))

        #expect(model.metrics.isEmpty)
        #expect(model.creditsText == nil)
        #expect(model.providerCost?.title == "Credits")
        #expect(model.providerCost?.spendLine == "Balance: $7.36")
        #expect(model.providerCost?.percentUsed == nil)
        #expect(model.providerCost?.percentLine == nil)
    }

    @Test
    func `CLI text renders the prepaid balance instead of the generic cost fallback`() {
        let usage = XAIUsageSnapshot(
            balanceUSD: 7.36,
            daily: [
                .init(day: "2027-01-14", costUSD: 1.5),
                .init(day: "2027-01-15", costUSD: 0.25),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let text = CLIRenderer.renderText(
            provider: .xai,
            snapshot: usage.toUsageSnapshot(),
            credits: nil,
            context: RenderContext(
                header: "xAI (api)",
                status: nil,
                useColor: false,
                resetStyle: .countdown))

        #expect(text.contains("Balance: $7.36"))
        #expect(text.contains("Last 30 days: $1.75"))
        // The generic no-window fallback would print "Cost: 7.4 / 0.0", which
        // presents the balance as a spend against a zero budget.
        #expect(!text.contains("Cost:"))
        // `plan.capitalized` would mangle the login method into "Management Api".
        #expect(text.contains("Plan: Management API"))
    }

    // MARK: - Helpers

    private static func fetch(
        balanceBody: String = balanceFixture,
        balanceStatus: Int = 200,
        usageBody: String = usageFixture,
        usageStatus: Int = 200,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000)) async throws -> XAIUsageSnapshot
    {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/prepaid/balance") {
                return Self.response(url: url, body: balanceBody, statusCode: balanceStatus)
            }
            return Self.response(url: url, body: usageBody, statusCode: usageStatus)
        }
        return try await XAIBillingFetcher.fetchUsage(
            managementKey: "fixture-management-key",
            teamID: "team-1234",
            transport: transport,
            now: now)
    }

    private static func happyTransport() -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            if url.path.hasSuffix("/prepaid/balance") {
                return Self.response(url: url, body: Self.balanceFixture)
            }
            return Self.response(url: url, body: Self.usageFixture)
        }
    }

    /// Shape from the documented balance example: a $10 top-up (PURCHASE) recorded
    /// as "-1000" cents, with the running total in the same inverted-ledger unit.
    static let balanceFixture = #"""
    {
      "changes": [
        {
          "teamId": "team-1234",
          "changeOrigin": "PURCHASE",
          "topupStatus": "SUCCEEDED",
          "amount": { "val": "-1000" },
          "invoiceId": "fixture-invoice-id",
          "invoiceNumber": "000-000-000-001",
          "createTime": "2026-12-24T15:28:02.308840Z",
          "paymentProcessor": { "kind": "STRIPE" }
        }
      ],
      "total": { "val": "-1000" }
    }
    """#

    /// Shape from the documented usage example: dense daily buckets per series,
    /// numeric USD values, `limitReached` cardinality marker.
    static let usageFixture = #"""
    {
      "timeSeries": [
        {
          "group": ["Chat grok-4-fixture"],
          "groupLabels": ["Chat grok-4-fixture"],
          "dataPoints": [
            { "timestamp": "2027-01-13T00:00:00Z", "values": [0.75973725] },
            { "timestamp": "2027-01-14T00:00:00Z", "values": [0.5] },
            { "timestamp": "2027-01-15T00:00:00Z", "values": [0] }
          ]
        },
        {
          "group": ["Live search"],
          "groupLabels": ["Live search"],
          "dataPoints": [
            { "timestamp": "2027-01-13T00:00:00Z", "values": [0.5] },
            { "timestamp": "2027-01-14T00:00:00Z", "values": [0] },
            { "timestamp": "2027-01-15T00:00:00Z", "values": [0] }
          ]
        }
      ],
      "limitReached": false
    }
    """#

    static func response(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}
