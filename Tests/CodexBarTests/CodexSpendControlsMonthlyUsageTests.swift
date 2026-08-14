import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite(.serialized)
struct CodexSpendControlsMonthlyUsageTests {
    private actor InvocationCounter {
        private var value = 0

        func increment() {
            self.value += 1
        }

        func count() -> Int {
            self.value
        }
    }

    private enum ExpectedError: Error {
        case failed
    }

    private func educationUsageJSON(
        planType: String? = "education",
        accountId: String? = "acct-123",
        includeSpendControl: Bool = true,
        individualLimit: String = "null") -> String
    {
        let plan = planType.map { #""plan_type":"\#($0)","# } ?? ""
        let account = accountId.map { #""account_id":"\#($0)","# } ?? ""
        let spendControl = includeSpendControl
            ? #", "spend_control":{"reached":false,"individual_limit":\#(individualLimit)}"#
            : ""
        return """
        {
          \(plan)
          \(account)
          "rate_limit": {
            "primary_window": {
              "used_percent": 10,
              "reset_at": 1786161204,
              "limit_window_seconds": 18000
            },
            "secondary_window": null
          },
          "credits": {"has_credits": true, "unlimited": false, "balance": "14"}
          \(spendControl)
        }
        """
    }

    private func monthlyUsageJSON(
        usage: String = "3046.4506806135178",
        limit: String = "7000",
        enforcementMode: String? = "HARD_CAP") -> String
    {
        let enforcement = enforcementMode.map { #", "enforcement_mode":"\#($0)""# } ?? ""
        return """
        {
          "current_month_usage": \(usage),
          "effective_monthly_limit": {
            "limit": \(limit)\(enforcement),
            "limit_mode": "amount_credits"
          }
        }
        """
    }

    private func decodeUsage(_ json: String) throws -> CodexUsageResponse {
        try CodexOAuthUsageFetcher._decodeUsageResponseForTesting(Data(json.utf8))
    }

    private func decodeMonthlyUsage(_ json: String) throws -> CodexSpendControlsMonthlyUsageResponse {
        try CodexOAuthUsageFetcher._decodeSpendControlsMonthlyUsageResponseForTesting(Data(json.utf8))
    }

    private func makeCredentials(accountId: String? = nil) -> CodexOAuthCredentials {
        CodexOAuthCredentials(
            accessToken: "access",
            refreshToken: "refresh",
            idToken: nil,
            accountId: accountId,
            lastRefresh: Date())
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

    @Test
    func `education usage fixture gates monthly endpoint and maps its response`() throws {
        let usage = try self.decodeUsage(self.educationUsageJSON())
        let now = Date(timeIntervalSince1970: 1_786_000_000)

        #expect(usage.accountId == "acct-123")
        #expect(usage.resolvedIndividualLimit == nil)
        #expect(usage.resolvedIndividualLimit?.codexCreditLimitSnapshot(updatedAt: now) == nil)
        #expect(usage.spendControlPresent)
        #expect(CodexSpendControlsMonthlyUsageGate.shouldFetch(response: usage))

        let monthlyUsage = try self.decodeMonthlyUsage(self.monthlyUsageJSON())
        let snapshot = try #require(monthlyUsage.codexCreditLimitSnapshot(updatedAt: now))
        #expect(abs(snapshot.used - 3046.4506806135178) < 0.000_001)
        #expect(snapshot.limit == 7000)
        #expect(abs(snapshot.remainingPercent - 56.479_276_0) < 0.000_001)
        #expect(snapshot.resetsAt == nil)
        #expect(snapshot.updatedAt == now)
    }

    @Test
    func `active and unknown enforcement modes produce a monthly limit`() throws {
        for mode in ["HARD_CAP", "SOFT_CAP", "future_mode"] {
            let response = try self.decodeMonthlyUsage(self.monthlyUsageJSON(enforcementMode: mode))
            #expect(response.codexCreditLimitSnapshot(updatedAt: Date()) != nil)
        }

        let missingMode = try self.decodeMonthlyUsage(self.monthlyUsageJSON(enforcementMode: nil))
        #expect(missingMode.codexCreditLimitSnapshot(updatedAt: Date()) != nil)
    }

    @Test
    func `inactive enforcement modes suppress the monthly limit case insensitively`() throws {
        for mode in ["NONE", "disabled", "OFF", "no_limit"] {
            let response = try self.decodeMonthlyUsage(self.monthlyUsageJSON(enforcementMode: mode))
            #expect(response.codexCreditLimitSnapshot(updatedAt: Date()) == nil)
        }
    }

    @Test
    func `missing or zero limit suppresses the monthly snapshot`() throws {
        let zero = try self.decodeMonthlyUsage(self.monthlyUsageJSON(limit: "0"))
        let missing = try self.decodeMonthlyUsage(
            #"{"current_month_usage":12,"effective_monthly_limit":{"enforcement_mode":"HARD_CAP"}}"#)

        #expect(zero.codexCreditLimitSnapshot(updatedAt: Date()) == nil)
        #expect(missing.codexCreditLimitSnapshot(updatedAt: Date()) == nil)
    }

    @Test
    func `monthly usage clamps negative usage and accepts numeric strings`() throws {
        let response = try self.decodeMonthlyUsage(self.monthlyUsageJSON(usage: #""-20""#, limit: #""7000""#))
        let snapshot = try #require(response.codexCreditLimitSnapshot(updatedAt: Date()))

        #expect(snapshot.used == 0)
        #expect(snapshot.remainingPercent == 100)
    }

    @Test
    func `consumer plans never gate the monthly endpoint`() throws {
        for plan in ["plus", "pro", "free"] {
            let response = try self.decodeUsage(self.educationUsageJSON(planType: plan))
            #expect(!CodexSpendControlsMonthlyUsageGate.shouldFetch(response: response))
        }
    }

    @Test
    func `existing education individual limit prevents a second monthly limit request`() throws {
        let individualLimit = #"{"limit":7000,"used":1000,"remaining_percent":85}"#
        let response = try self.decodeUsage(self.educationUsageJSON(individualLimit: individualLimit))

        #expect(response.resolvedIndividualLimit?.limit == 7000)
        #expect(!CodexSpendControlsMonthlyUsageGate.shouldFetch(response: response))
    }

    @Test
    func `education without spend control key does not gate the monthly endpoint`() throws {
        let response = try self.decodeUsage(self.educationUsageJSON(includeSpendControl: false))

        #expect(!response.spendControlPresent)
        #expect(!CodexSpendControlsMonthlyUsageGate.shouldFetch(response: response))
    }

    @Test
    func `missing plan does not gate the monthly endpoint`() throws {
        let response = try self.decodeUsage(self.educationUsageJSON(planType: nil))

        #expect(response.planType == nil)
        #expect(!CodexSpendControlsMonthlyUsageGate.shouldFetch(response: response))
    }

    @Test
    func `camel account id and null camel spend control retain presence`() throws {
        let response = try self.decodeUsage(#"{"accountId":"camel-id","plan_type":"edu","spendControl":null}"#)

        #expect(response.accountId == "camel-id")
        #expect(response.spendControlPresent)
        #expect(CodexSpendControlsMonthlyUsageGate.shouldFetch(response: response))
    }

    @Test
    func `O auth helper injects monthly limit and preserves existing credit data`() async throws {
        let usageJSON = self.educationUsageJSON()
        let usage = try self.decodeUsage(usageJSON)
        let original = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(usageJSON.utf8),
            credentials: self.makeCredentials())
        let payload = try self.decodeMonthlyUsage(self.monthlyUsageJSON())

        let enriched = try await CodexOAuthFetchStrategy._applySpendControlsMonthlyLimitForTesting(
            original,
            usage: usage,
            credentials: self.makeCredentials(),
            context: self.makeContext(),
            fetcher: { accountId in
                #expect(accountId == "acct-123")
                return payload
            })

        #expect(enriched.credits?.remaining == original.credits?.remaining)
        #expect(enriched.credits?.events == original.credits?.events)
        #expect(enriched.credits?.updatedAt == original.credits?.updatedAt)
        #expect(enriched.credits?.codexCreditLimit?.limit == 7000)
        #expect(enriched.sourceLabel == original.sourceLabel)
        #expect(enriched.strategyID == original.strategyID)
    }

    @Test
    func `O auth helper creates credits when monthly limit is the only credit data`() async throws {
        let usageJSON = self.educationUsageJSON().replacingOccurrences(
            of: #""credits": {"has_credits": true, "unlimited": false, "balance": "14"}"#,
            with: #""credits": {"has_credits": true, "unlimited": false, "balance": null}"#)
        let usage = try self.decodeUsage(usageJSON)
        let original = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(usageJSON.utf8),
            credentials: self.makeCredentials())
        let payload = try self.decodeMonthlyUsage(self.monthlyUsageJSON())

        let enriched = try await CodexOAuthFetchStrategy._applySpendControlsMonthlyLimitForTesting(
            original,
            usage: usage,
            credentials: self.makeCredentials(accountId: "credential-account"),
            context: self.makeContext(),
            fetcher: { accountId in
                #expect(accountId == "credential-account")
                return payload
            })

        #expect(original.credits == nil)
        #expect(enriched.credits?.remaining == 0)
        #expect(enriched.credits?.events.isEmpty == true)
        #expect(enriched.credits?.codexCreditLimit?.limit == 7000)
    }

    @Test
    func `O auth helper keeps original result on enrichment error`() async throws {
        let usageJSON = self.educationUsageJSON()
        let usage = try self.decodeUsage(usageJSON)
        let original = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(usageJSON.utf8),
            credentials: self.makeCredentials())

        let result = try await CodexOAuthFetchStrategy._applySpendControlsMonthlyLimitForTesting(
            original,
            usage: usage,
            credentials: self.makeCredentials(accountId: "credential-account"),
            context: self.makeContext(),
            fetcher: { _ in throw ExpectedError.failed })

        #expect(result.credits == original.credits)
        #expect(result.sourceLabel == original.sourceLabel)
        #expect(result.strategyID == original.strategyID)
        #expect(result.strategyKind == original.strategyKind)
        #expect(result.diagnostic == original.diagnostic)
    }

    @Test
    func `O auth helper propagates cancellation`() async throws {
        let usageJSON = self.educationUsageJSON()
        let usage = try self.decodeUsage(usageJSON)
        let original = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(usageJSON.utf8),
            credentials: self.makeCredentials())

        await #expect(throws: CancellationError.self) {
            try await CodexOAuthFetchStrategy._applySpendControlsMonthlyLimitForTesting(
                original,
                usage: usage,
                credentials: self.makeCredentials(accountId: "credential-account"),
                context: self.makeContext(),
                fetcher: { _ in throw CancellationError() })
        }
    }

    @Test
    func `O auth helper skips fetch when gate or credits setting is false`() async throws {
        let counter = InvocationCounter()
        let payload = try self.decodeMonthlyUsage(self.monthlyUsageJSON())
        let educationJSON = self.educationUsageJSON()
        let education = try self.decodeUsage(educationJSON)
        let consumerJSON = self.educationUsageJSON(planType: "plus")
        let consumer = try self.decodeUsage(consumerJSON)
        let original = try CodexOAuthFetchStrategy._mapResultForTesting(
            Data(educationJSON.utf8),
            credentials: self.makeCredentials())
        let fetcher: @Sendable (String) async throws -> CodexSpendControlsMonthlyUsageResponse = { _ in
            await counter.increment()
            return payload
        }

        _ = try await CodexOAuthFetchStrategy._applySpendControlsMonthlyLimitForTesting(
            original,
            usage: consumer,
            credentials: self.makeCredentials(accountId: "account"),
            context: self.makeContext(),
            fetcher: fetcher)
        _ = try await CodexOAuthFetchStrategy._applySpendControlsMonthlyLimitForTesting(
            original,
            usage: education,
            credentials: self.makeCredentials(accountId: "account"),
            context: self.makeContext(includeCredits: false),
            fetcher: fetcher)

        #expect(await counter.count() == 0)
    }

    @Test
    func `O auth monthly endpoint URL requires backend api base`() {
        let defaultURL = CodexOAuthUsageFetcher._resolveSpendControlsMonthlyUsageURLForTesting(
            configContents: #"chatgpt_base_url = "https://chatgpt.com/backend-api""#,
            accountId: "acct-123")
        let customURL = CodexOAuthUsageFetcher._resolveSpendControlsMonthlyUsageURLForTesting(
            configContents: #"chatgpt_base_url = "https://example.com/api/codex""#,
            accountId: "acct-123")

        #expect(defaultURL?.absoluteString ==
            "https://chatgpt.com/backend-api/accounts/acct-123/spend-controls/current-user/monthly-usage")
        #expect(customURL == nil)
    }

    @Test
    func `O auth monthly endpoint request uses bearer account and bounded timeout`() async throws {
        let payload = Data(self.monthlyUsageJSON().utf8)
        let transport = ProviderHTTPTransportStub { request in
            #expect(request.url?.absoluteString ==
                "https://chatgpt.com/backend-api/accounts/acct-123/spend-controls/current-user/monthly-usage")
            #expect(request.httpMethod == "GET")
            #expect(request.timeoutInterval == 3)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-123")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CodexBar")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (payload, response)
        }

        let response = try await CodexOAuthUsageFetcher.fetchSpendControlsMonthlyUsage(
            accessToken: "access",
            accountId: "acct-123",
            env: ["CODEX_HOME": "/tmp/codexbar-monthly-usage-fixture-home"],
            timeout: 3,
            session: transport)

        #expect(response.effectiveMonthlyLimit?.limit == 7000)
        #expect(await transport.requests().count == 1)
    }

    #if os(macOS)
    @MainActor
    @Test
    func `dashboard education path fetches and maps monthly usage in two requests`() async {
        let result = await self.fetchDashboardScenario(.educationSuccess)

        #expect(result?.codexCreditLimit?.limit == 7000)
        #expect(result?.codexCreditLimit?.used == 3046.4506806135178)
        #expect(DashboardSpendControlsURLProtocol.recordedRequests.count == 2)
    }

    @MainActor
    @Test
    func `dashboard consumer path does not fetch monthly usage`() async {
        let result = await self.fetchDashboardScenario(.consumer)

        #expect(result?.codexCreditLimit == nil)
        #expect(DashboardSpendControlsURLProtocol.recordedRequests.count == 1)
    }

    @MainActor
    @Test
    func `dashboard monthly endpoint failure keeps original data`() async {
        let result = await self.fetchDashboardScenario(.educationNotFound)

        #expect(result?.primaryLimit?.usedPercent == 10)
        #expect(result?.codexCreditLimit == nil)
        #expect(DashboardSpendControlsURLProtocol.recordedRequests.count == 2)
    }

    @Test
    func `dashboard monthly endpoint percent encodes account path component`() {
        let url = OpenAIDashboardFetcher.dashboardSpendControlsMonthlyUsageAPIRequest(
            accountId: "acct/a b",
            cookieHeader: "session=test")?.url

        #expect(url?.absoluteString.contains("/accounts/acct%2Fa%20b/spend-controls/") == true)
    }

    @MainActor
    private func fetchDashboardScenario(_ scenario: DashboardSpendControlsURLProtocol.Scenario) async
        -> OpenAIDashboardFetcher.DashboardAPIData?
    {
        DashboardSpendControlsURLProtocol.reset(scenario: scenario)
        let configuration = CodexAuthenticatedHTTPTransport.makeConfiguration()
        configuration.protocolClasses = [DashboardSpendControlsURLProtocol.self]
        let transport = CodexAuthenticatedHTTPTransport.makeClient(configuration: configuration)
        return await CodexAuthenticatedHTTPTransport.$overrideForTesting.withValue(transport) {
            await OpenAIDashboardFetcher.fetchDashboardUsageAPI(
                cookieHeader: "session=test",
                deadline: nil,
                logger: { _ in })
        }
    }
    #endif
}

#if os(macOS)
private final class DashboardSpendControlsURLProtocol: URLProtocol {
    enum Scenario {
        case educationSuccess
        case educationNotFound
        case consumer
    }

    private(set) nonisolated(unsafe) static var recordedRequests: [URLRequest] = []
    private nonisolated(unsafe) static var scenario = Scenario.educationSuccess

    static func reset(scenario: Scenario) {
        self.recordedRequests = []
        self.scenario = scenario
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recordedRequests.append(self.request)
        guard let url = self.request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let isMonthlyUsage = url.path.hasSuffix("/spend-controls/current-user/monthly-usage")
        let status: Int
        let payload: String
        if isMonthlyUsage {
            switch Self.scenario {
            case .educationSuccess:
                status = 200
                payload = """
                {"current_month_usage":3046.4506806135178,"effective_monthly_limit":{
                  "limit":7000,"enforcement_mode":"HARD_CAP","limit_mode":"amount_credits"}}
                """
            case .educationNotFound:
                status = 404
                payload = #"{"error":"not found"}"#
            case .consumer:
                status = 500
                payload = #"{"error":"unexpected monthly request"}"#
            }
        } else {
            status = 200
            let plan = Self.scenario == .consumer ? "plus" : "education"
            payload = """
            {"account_id":"acct-123","plan_type":"\(plan)","spend_control":{"individual_limit":null},
             "rate_limit":{"primary_window":{"used_percent":10,"reset_at":1786161204,
             "limit_window_seconds":18000},"secondary_window":null}}
            """
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(payload.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
