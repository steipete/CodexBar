#if os(macOS)
import Foundation
import Testing
@testable import CodexBarCore

@MainActor
struct CodexWorkspaceBalanceDashboardTests {
    private static let updatedAt = Date(timeIntervalSince1970: 1_786_000_000)

    private func snapshot(
        balance: Double? = nil,
        available: Bool? = nil,
        workspace: Bool? = nil) -> OpenAIDashboardSnapshot
    {
        OpenAIDashboardSnapshot(
            signedInEmail: "user@example.com",
            accountID: "workspace-a",
            codeReviewRemainingPercent: nil,
            creditEvents: [],
            dailyBreakdown: [],
            usageBreakdown: [],
            creditsPurchaseURL: nil,
            creditsRemaining: balance,
            creditsAvailable: available,
            balanceIsWorkspace: workspace,
            updatedAt: Self.updatedAt)
    }

    private func apiData(
        balance: Double? = nil,
        available: Bool? = nil,
        workspace: Bool? = nil) -> OpenAIDashboardFetcher.DashboardAPIData
    {
        OpenAIDashboardFetcher.DashboardAPIData(
            accountID: "workspace-a",
            primaryLimit: nil,
            secondaryLimit: nil,
            extraRateWindows: [],
            creditsRemaining: balance,
            creditsAvailable: available,
            balanceIsWorkspace: workspace,
            codexCreditLimit: nil,
            accountPlan: "business")
    }

    private func fetchBalanceResponse(
        status: Int,
        payload: String,
        includeCap: Bool = false) async throws -> OpenAIDashboardFetcher.DashboardAPIData
    {
        let cap = includeCap ? #", "individual_limit":{"limit":100,"used":100}"# : ""
        let usage = """
        {"account_id":"workspace-123","plan_type":"business",
         "credits":{"has_credits":true,"unlimited":false,"balance":null}\(cap)}
        """
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let isBalanceRequest = url.path.hasSuffix("/remaining_balance")
            if isBalanceRequest {
                #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "workspace-123")
                #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
                #expect(request.timeoutInterval <= 4)
            } else {
                #expect(url.path == "/backend-api/wham/usage")
            }
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: isBalanceRequest ? status : 200,
                httpVersion: nil,
                headerFields: nil))
            return (Data((isBalanceRequest ? payload : usage).utf8), response)
        }
        let result = await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            try? await OpenAIDashboardFetcher.fetchDashboardAPIResponse(
                cookieHeader: "session=fixture",
                deadline: Date().addingTimeInterval(10),
                logger: { _ in })?.apiData
        }
        #expect(await transport.requests().count == 2)
        return try #require(result)
    }

    @Test(arguments: [0.0, 1234.0])
    func `owner balance remains distinct from an exhausted personal cap`(balance: Double) async throws {
        let api = try await self.fetchBalanceResponse(
            status: 200,
            payload: #"{"balance":\#(balance)}"#,
            includeCap: true)
        let dashboard = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: api,
            verifiedEmail: "user@example.com",
            previous: nil)
        let credits = try #require(dashboard.toCreditsSnapshot())

        #expect(credits.codexCreditLimit?.remaining == 0)
        #expect(credits.balanceIsWorkspace)
        #expect(credits.balanceReadSucceeded)
        #expect(credits.displayRemaining == balance)
    }

    @Test(arguments: [403, 500])
    func `unavailable owner endpoint retains hidden credits without rate windows`(status: Int) async throws {
        let api = try await self.fetchBalanceResponse(status: status, payload: #"{"error":"unavailable"}"#)
        let dashboard = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: api,
            verifiedEmail: "user@example.com",
            previous: self.snapshot(balance: 1234, available: true, workspace: true))
        let credits = try #require(dashboard.toCreditsSnapshot())

        #expect(api.hasUsageData)
        #expect(credits.creditsAvailable == true)
        #expect(!credits.balanceReadSucceeded)
        #expect(!credits.balanceIsWorkspace)
        #expect(credits.displayRemaining == nil)
    }

    @Test
    func `missing balance payload never revives a cached workspace amount`() async throws {
        let api = try await self.fetchBalanceResponse(status: 200, payload: #"{"balance":null}"#)
        let current = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: api,
            verifiedEmail: "user@example.com",
            previous: self.snapshot(balance: 1234, available: true, workspace: true))
        let filled = OpenAIDashboardFetcher.fillingMissingPageFields(
            current,
            from: self.snapshot(balance: 1234, available: true, workspace: true))

        #expect(filled.creditsRemaining == nil)
        #expect(filled.creditsAvailable == true)
        #expect(filled.balanceIsWorkspace != true)
    }

    @Test
    func `merges keep provenance with the selected numeric balance`() {
        let previous = self.snapshot(balance: 1234, available: true, workspace: true)
        let inherited = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: self.apiData(),
            verifiedEmail: "user@example.com",
            previous: previous)
        let replaced = OpenAIDashboardFetcher.snapshotByMergingAPI(
            apiData: self.apiData(balance: 12, available: true),
            verifiedEmail: "user@example.com",
            previous: previous)
        let pageReplaced = OpenAIDashboardFetcher.fillingMissingPageFields(
            self.snapshot(balance: 12),
            from: previous)

        #expect(inherited.creditsRemaining == 1234)
        #expect(inherited.balanceIsWorkspace == true)
        #expect(replaced.creditsRemaining == 12)
        #expect(replaced.balanceIsWorkspace != true)
        #expect(pageReplaced.creditsRemaining == 12)
        #expect(pageReplaced.balanceIsWorkspace != true)
    }

    @Test
    func `page placeholder cannot replace the API hidden balance state`() {
        let scrape = OpenAIDashboardFetcher.ScrapeResult(
            loginRequired: false,
            workspacePicker: false,
            cloudflareInterstitial: false,
            href: nil,
            bodyText: "Credits remaining 0",
            signedInEmail: "user@example.com",
            authStatus: nil,
            accountPlan: nil,
            creditsPurchaseURL: nil,
            rows: [],
            usageBreakdown: [],
            usageBreakdownDebug: nil,
            usageBreakdownError: nil,
            scrollY: 0,
            scrollHeight: 0,
            viewportHeight: 0,
            creditsHeaderPresent: true,
            creditsHeaderInViewport: true,
            didScrollToCredits: false)
        #expect(OpenAIDashboardParser.parseCreditsRemaining(bodyText: scrape.bodyText ?? "") == 0)
        let parsed = OpenAIDashboardFetcher.parseDashboardScrape(
            scrape,
            apiData: self.apiData(available: true),
            verifiedSignedInEmail: "user@example.com")
        let page = OpenAIDashboardFetcher.makePageSnapshot(
            scrape: scrape,
            dashboardData: parsed,
            subscriptionResult: .unavailable,
            previousSnapshot: self.snapshot(balance: 1234, available: true, workspace: true))

        #expect(parsed.hasReturnableData)
        #expect(page.creditsRemaining == nil)
        #expect(page.toCreditsSnapshot()?.balanceReadSucceeded == false)
    }

    @Test
    func `dashboard cache preserves provenance and accepts older snapshots`() throws {
        let original = self.snapshot(balance: 1234, available: true, workspace: true)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(OpenAIDashboardSnapshot.self, from: data)
        #expect(restored == original)
        #expect(restored.withSubscriptionMetadata(nil).balanceIsWorkspace == true)

        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "creditsAvailable")
        legacy.removeValue(forKey: "balanceIsWorkspace")
        let decodedLegacy = try JSONDecoder().decode(
            OpenAIDashboardSnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decodedLegacy.creditsRemaining == 1234)
        #expect(decodedLegacy.creditsAvailable == nil)
        #expect(decodedLegacy.toCreditsSnapshot()?.balanceIsWorkspace == false)
    }
}
#endif
