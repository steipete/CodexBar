import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CodexWorkspaceBalanceTests {
    private struct Fixture {
        let usage: CodexUsageResponse
        let result: ProviderFetchResult
    }

    private func makeFixture(
        accountId: String? = "usage-account",
        hasCredits: Bool = true,
        unlimited: Bool = false,
        balance: String = "null") throws -> Fixture
    {
        let account = accountId.map { #""account_id":"\#($0)","# } ?? ""
        let json = """
        {
          \(account)
          "plan_type": "business",
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "reset_at": 1786161204,
              "limit_window_seconds": 18000
            }
          },
          "credits": {"has_credits": \(hasCredits), "unlimited": \(unlimited), "balance": \(balance)}
        }
        """
        let data = Data(json.utf8)
        return try Fixture(
            usage: CodexOAuthUsageFetcher._decodeUsageResponseForTesting(data),
            result: CodexOAuthFetchStrategy._mapResultForTesting(data, credentials: self.makeCredentials()))
    }

    private func makeCredentials(accountId: String? = nil) -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: "fixture-access",
            refreshToken: "fixture-refresh",
            idToken: nil,
            accountId: accountId,
            lastRefresh: Date())
    }

    private func mapCreditRefresh(
        balance: String,
        includeCredits: Bool,
        hasCap: Bool) throws -> ProviderFetchResult
    {
        let cap = hasCap ? #", "individual_limit": {"limit": 400, "used": 300}"# : ""
        let json = """
        {
          "account_id": "workspace-fixture",
          "plan_type": "business",
          "credits": {"has_credits": true, "unlimited": false, "balance": \(balance)}\(cap)
        }
        """
        return try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(json.utf8),
            credentials: self.makeCredentials(),
            includeCredits: includeCredits)
    }

    private func makeContext(includeCredits: Bool = true) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .oauth,
            includeCredits: includeCredits,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: nil,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func decodeBalance(_ json: String) throws -> CodexWorkspaceRemainingBalanceResponse {
        try JSONDecoder().decode(CodexWorkspaceRemainingBalanceResponse.self, from: Data(json.utf8))
    }

    private func expectUnchanged(_ result: ProviderFetchResult, original: ProviderFetchResult) {
        #expect(result.credits == original.credits)
        #expect(result.usage.primary == original.usage.primary)
        #expect(result.usage.secondary == original.usage.secondary)
        #expect(result.usage.providerCost == original.usage.providerCost)
        #expect(result.usage.updatedAt == original.usage.updatedAt)
        #expect(result.usage.identity?.accountID == original.usage.identity?.accountID)
        #expect(result.usage.identity?.loginMethod == original.usage.identity?.loginMethod)
        #expect(result.dashboard == original.dashboard)
        #expect(result.sourceLabel == original.sourceLabel)
        #expect(result.strategyID == original.strategyID)
        #expect(result.strategyKind == original.strategyKind)
        #expect(result.codexResetCreditsAttempted == original.codexResetCreditsAttempted)
        #expect(result.codexMonthlyLimitEnrichmentFailed == original.codexMonthlyLimitEnrichmentFailed)
        #expect(result.diagnostic == original.diagnostic)
    }

    @Test(arguments: [false, true], [false, true])
    func `deferred balance refresh preserves a workspace balance while a requested missing read invalidates it`(
        includeCredits: Bool,
        hasCap: Bool) throws
    {
        let result = try self.mapCreditRefresh(balance: "null", includeCredits: includeCredits, hasCap: hasCap)
        let fresh = try #require(result.credits)
        let retained = CreditsSnapshot(
            remaining: 1234,
            events: [],
            updatedAt: fresh.updatedAt.addingTimeInterval(-60),
            balanceIsWorkspace: true)
        let display = try #require(CodexExtraUsageCost.creditsForDisplay(retained, attached: result.usage.providerCost))
        let expectedRemaining: Double? = includeCredits ? (hasCap ? 100 : nil) : 1234

        // This response has no rate windows: raw availability must still admit a useful partial result.
        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
        #expect(fresh.balanceReadSucceeded == false)
        #expect(fresh.creditsAvailable == (includeCredits ? true : nil))
        #expect(fresh.codexCreditLimit?.remaining == (hasCap ? 100 : nil))
        #expect(display.displayRemaining == expectedRemaining)
        #expect(display.balanceReadSucceeded == !includeCredits)
        #expect(display.hasWorkspaceBalance == !includeCredits)
    }

    @Test(arguments: [0.0, 14.0], [false, true])
    func `usage only numeric balances remain authoritative over an older workspace balance`(
        balance: Double,
        hasCap: Bool) throws
    {
        let result = try self.mapCreditRefresh(balance: String(balance), includeCredits: false, hasCap: hasCap)
        let fresh = try #require(result.credits)
        let retained = CreditsSnapshot(
            remaining: 1234,
            events: [],
            updatedAt: fresh.updatedAt.addingTimeInterval(-60),
            balanceIsWorkspace: true)
        let display = try #require(CodexExtraUsageCost.creditsForDisplay(retained, attached: result.usage.providerCost))

        #expect(fresh.balanceReadSucceeded)
        #expect(fresh.creditsAvailable == true)
        #expect(fresh.codexCreditLimit?.remaining == (hasCap ? 100 : nil))
        #expect(display.remaining == balance)
        #expect(display.balanceReadSucceeded)
        #expect(display.hasWorkspaceBalance == false)
        #expect(display.updatedAt == fresh.updatedAt)
        #expect(result.usage.providerCost?.balance == (balance > 0 ? balance : nil))
        #expect(result.usage.providerCost?.balanceUpdatedAt == fresh.updatedAt)
    }

    @Test(arguments: ["disabled", "unavailable", "unlimited", "known balance", "known zero", "missing account"])
    func `workspace enrichment skips ineligible usage without invoking the endpoint`(scenario: String) async throws {
        let fixture = try self.makeFixture(
            accountId: scenario == "missing account" ? nil : "usage-account",
            hasCredits: scenario != "unavailable",
            unlimited: scenario == "unlimited",
            balance: scenario == "known balance" ? "14" : scenario == "known zero" ? "0" : "null")
        let result = try await CodexOAuthFetchStrategy._applyWorkspaceRemainingBalanceForTesting(
            fixture.result,
            usage: fixture.usage,
            credentials: self.makeCredentials(),
            context: self.makeContext(includeCredits: scenario != "disabled"),
            fetcher: { _ in
                Issue.record("Ineligible usage must not fetch the workspace balance")
                throw CodexOAuthFetchError.invalidResponse
            })

        self.expectUnchanged(result, original: fixture.result)
    }

    @Test(arguments: ["credential-account", "usage-account", " usage-account ", "", "   "])
    func `workspace enrichment requires a response account matching any credential scope`(
        credentialAccount: String) async throws
    {
        let fixture = try self.makeFixture(accountId: credentialAccount == "credential-account" ? nil : "usage-account")
        let payload = try self.decodeBalance(#"{"balance":1234}"#)
        let result = try await CodexOAuthFetchStrategy._applyWorkspaceRemainingBalanceForTesting(
            fixture.result,
            usage: fixture.usage,
            credentials: self.makeCredentials(accountId: credentialAccount),
            context: self.makeContext(),
            fetcher: { accountId in
                #expect(credentialAccount != "credential-account", "An unscoped response must not fetch a balance")
                #expect(accountId == "usage-account")
                return payload
            })

        if credentialAccount == "credential-account" {
            self.expectUnchanged(result, original: fixture.result)
        } else {
            #expect(result.credits?.remaining == 1234)
            #expect(result.credits?.hasWorkspaceBalance == true)
        }
    }

    @Test
    func `workspace enrichment rejects conflicting credential and response accounts`() async throws {
        let fixture = try self.makeFixture(accountId: "response-workspace")
        let result = try await CodexOAuthFetchStrategy._applyWorkspaceRemainingBalanceForTesting(
            fixture.result,
            usage: fixture.usage,
            credentials: self.makeCredentials(accountId: "different-workspace"),
            context: self.makeContext(),
            fetcher: { _ in
                Issue.record("Conflicting account scopes must not fetch a balance")
                throw URLError(.badURL)
            })
        #expect(result.credits == fixture.result.credits)
        #expect(result.usage.providerCost == fixture.result.usage.providerCost)
    }

    @Test(arguments: [401, 403, 404, 500])
    func `workspace endpoint HTTP failures retain the usable OAuth result`(status: Int) async throws {
        let fixture = try self.makeFixture()
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil))
            return (Data(#"{"error":"fixture failure"}"#.utf8), response)
        }
        let result = try await CodexOAuthFetchStrategy._applyWorkspaceRemainingBalanceForTesting(
            fixture.result,
            usage: fixture.usage,
            credentials: self.makeCredentials(),
            context: self.makeContext(),
            fetcher: { accountId in
                try await CodexOAuthUsageFetcher.fetchWorkspaceRemainingBalance(
                    accessToken: "fixture-access",
                    accountId: accountId,
                    env: ["CODEX_HOME": "/tmp/codexbar-workspace-balance-fixture-home"],
                    session: transport)
            })

        #expect(await transport.requests().count == 1)
        self.expectUnchanged(result, original: fixture.result)
    }

    @Test
    func `workspace network failure retains the usable OAuth result`() async throws {
        let fixture = try self.makeFixture()
        let result = try await CodexOAuthFetchStrategy._applyWorkspaceRemainingBalanceForTesting(
            fixture.result,
            usage: fixture.usage,
            credentials: self.makeCredentials(),
            context: self.makeContext(),
            fetcher: { _ in throw CodexOAuthFetchError.networkError(URLError(.timedOut)) })

        self.expectUnchanged(result, original: fixture.result)
    }

    @Test(arguments: [
        #"{}"#,
        #"{"balance":null}"#,
        #"{"balance":"NaN"}"#,
        #"{"balance":"Infinity"}"#,
        #"{"balance":{"amount":14}}"#,
        #"{"balance":true}"#,
    ])
    func `missing or invalid workspace balances retain the original result`(json: String) async throws {
        let fixture = try self.makeFixture()
        let payload = try self.decodeBalance(json)
        let result = try await CodexOAuthFetchStrategy._applyWorkspaceRemainingBalanceForTesting(
            fixture.result,
            usage: fixture.usage,
            credentials: self.makeCredentials(),
            context: self.makeContext(),
            fetcher: { _ in payload })

        self.expectUnchanged(result, original: fixture.result)
    }

    @Test
    func `workspace enrichment propagates cancellation`() async throws {
        let fixture = try self.makeFixture()

        await #expect(throws: CancellationError.self) {
            try await CodexOAuthFetchStrategy._applyWorkspaceRemainingBalanceForTesting(
                fixture.result,
                usage: fixture.usage,
                credentials: self.makeCredentials(),
                context: self.makeContext(),
                fetcher: { _ in throw CancellationError() })
        }
    }

    @Test
    func `successful zero workspace balance retains provenance monthly limit and result metadata`() async throws {
        let fixture = try self.makeFixture()
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let limit = CodexCreditLimitSnapshot(
            title: "Monthly credit limit",
            used: 40,
            limit: 100,
            remainingPercent: 60,
            resetsAt: nil,
            updatedAt: date)
        let credits = CreditsSnapshot(
            remaining: 0,
            events: [CreditEvent(date: date, service: "fixture-service", creditsUsed: 2)],
            updatedAt: date,
            codexCreditLimit: limit,
            balanceReadSucceeded: false,
            creditsAvailable: true)
        let original = ProviderFetchResult(
            usage: fixture.result.usage,
            credits: credits,
            dashboard: nil,
            sourceLabel: fixture.result.sourceLabel,
            strategyID: fixture.result.strategyID,
            strategyKind: fixture.result.strategyKind,
            codexResetCreditsAttempted: true,
            codexMonthlyLimitEnrichmentFailed: true,
            diagnostic: "fixture diagnostic")
        let payload = try self.decodeBalance(#"{"balance":0}"#)
        let enriched = try await CodexOAuthFetchStrategy._applyWorkspaceRemainingBalanceForTesting(
            original,
            usage: fixture.usage,
            credentials: self.makeCredentials(),
            context: self.makeContext(),
            fetcher: { _ in payload })

        #expect(enriched.credits?.remaining == 0)
        #expect(enriched.credits?.balanceReadSucceeded == true)
        #expect(enriched.credits?.creditsAvailable == true)
        #expect(enriched.credits?.hasWorkspaceBalance == true)
        #expect(enriched.credits?.displayRemaining == 0)
        #expect(enriched.credits?.codexCreditLimit == limit)
        #expect(enriched.credits?.events == credits.events)
        #expect(enriched.usage.primary == original.usage.primary)
        #expect(enriched.usage.identity?.accountID == original.usage.identity?.accountID)
        #expect(enriched.usage.identity?.loginMethod == original.usage.identity?.loginMethod)
        #expect(enriched.usage.providerCost?.balanceIsWorkspace == true)
        #expect(enriched.usage.providerCost?.balanceUpdatedAt == enriched.credits?.updatedAt)
        #expect(enriched.sourceLabel == original.sourceLabel)
        #expect(enriched.strategyID == original.strategyID)
        #expect(enriched.strategyKind == original.strategyKind)
        #expect(enriched.codexResetCreditsAttempted)
        #expect(enriched.codexMonthlyLimitEnrichmentFailed)
        #expect(enriched.diagnostic == original.diagnostic)
    }

    @Test
    func `workspace URL encodes reserved account characters as one path component`() {
        let url = CodexOAuthUsageFetcher._resolveWorkspaceRemainingBalanceURLForTesting(
            configContents: #"chatgpt_base_url = "https://chatgpt.com/backend-api""#,
            accountId: "acct/a b?#%")

        #expect(url?.absoluteString ==
            "https://chatgpt.com/backend-api/accounts/acct%2Fa%20b%3F%23%25/remaining_balance")
    }

    @Test
    func `workspace URL respects a custom backend and rejects unsupported bases or empty accounts`() {
        let customURL = CodexOAuthUsageFetcher._resolveWorkspaceRemainingBalanceURLForTesting(
            configContents: #"chatgpt_base_url = "https://example.com/backend-api/""#,
            accountId: "fixture-account")
        let unsupportedURL = CodexOAuthUsageFetcher._resolveWorkspaceRemainingBalanceURLForTesting(
            configContents: #"chatgpt_base_url = "https://example.com/api/codex""#,
            accountId: "fixture-account")
        let emptyAccountURL = CodexOAuthUsageFetcher._resolveWorkspaceRemainingBalanceURLForTesting(
            configContents: #"chatgpt_base_url = "https://chatgpt.com""#,
            accountId: "")

        #expect(customURL?.absoluteString ==
            "https://example.com/backend-api/accounts/fixture-account/remaining_balance")
        #expect(unsupportedURL == nil)
        #expect(emptyAccountURL == nil)
    }
}
