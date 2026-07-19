import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CopilotBudgetWebFetcherTests {
    @Test
    func `maps positive copilot budgets to extra rate windows`() {
        let budgets: [CopilotBudgetWebFetcher.Budget] = [
            .init(
                id: "product-budget",
                budgetProductSkus: ["copilot"],
                budgetAmount: 100,
                currentAmount: 15),
            .init(
                id: "agent-budget",
                budgetProductSkus: ["copilot_agent_premium_request"],
                budgetAmount: 20,
                currentAmount: 5),
            .init(
                id: "zero-budget",
                budgetProductSkus: ["spark_premium_request"],
                budgetAmount: 0,
                currentAmount: 0),
        ]

        let windows = CopilotBudgetWebFetcher.extraRateWindows(
            from: budgets,
            now: Date(timeIntervalSince1970: 1_780_358_400))

        #expect(windows.map(\.id) == ["copilot-budget-product-budget", "copilot-budget-agent-budget"])
        #expect(windows.map(\.title) == ["Budget - Copilot", "Budget - Copilot Agent Premium Requests"])
        #expect(windows[0].window.usedPercent == 15)
        #expect(windows[1].window.usedPercent == 25)
        #expect(windows.allSatisfy { $0.window.resetsAt != nil })
    }

    @Test
    func `decodes github web budget response shape`() throws {
        let data = Data("""
        {
          "payload": {
            "budgets": [
              {
                "uuid": "budget-1",
                "targetName": "Example",
                "pricingTargetType": "BundlePricing",
                "pricingTargetId": "premium_requests",
                "targetAmount": 30.0,
                "currentAmount": 0.0
              }
            ],
            "has_next_page": false
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(CopilotBudgetWebFetcher.BudgetResponse.self, from: data)
        let budget = try #require(response.budgets.first)
        #expect(response.hasNextPage == false)
        #expect(budget.id == "budget-1")
        #expect(budget.budgetEntityName == "Example")
        #expect(budget.budgetAmount == 30)
        #expect(budget.currentAmount == 0)

        let windows = CopilotBudgetWebFetcher.extraRateWindows(
            from: response.budgets,
            now: Date(timeIntervalSince1970: 1_780_358_400))
        #expect(windows.map(\.title) == ["Budget - All Premium Request SKUs"])
        #expect(windows.first?.window.usedPercent == 0)
    }

    @Test
    func `ignores malformed embedded minus amounts`() throws {
        let data = Data("""
        {
          "budgets": [
            {
              "uuid": "budget-1",
              "pricingTargetId": "premium_requests",
              "targetAmount": "1-5",
              "currentAmount": "$5.00"
            },
            {
              "uuid": "budget-2",
              "pricingTargetId": "premium_requests",
              "targetAmount": "-$15.00",
              "currentAmount": "$5.00"
            }
          ]
        }
        """.utf8)

        let response = try JSONDecoder().decode(CopilotBudgetWebFetcher.BudgetResponse.self, from: data)

        #expect(response.budgets.map(\.budgetAmount) == [0, -15])
        #expect(CopilotBudgetWebFetcher.extraRateWindows(
            from: response.budgets,
            now: Date(timeIntervalSince1970: 1_780_358_400)).isEmpty)
    }

    @Test
    func `normalizes documented copilot billing names`() {
        #expect(CopilotBudgetWebFetcher.normalizedBillingIdentifier("Copilot") == "copilot")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Copilot Premium Request") ==
                "copilot_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Copilot Agent Premium Request") ==
                "copilot_agent_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Spark Premium Request") ==
                "spark_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Premium requests") ==
                "copilot_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Bundled premium request budget") ==
                "copilot_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("Copilot cloud agent premium requests") ==
                "copilot_agent_premium_request")
        #expect(
            CopilotBudgetWebFetcher.normalizedBillingIdentifier("coding_agent_premium_request") ==
                "copilot_agent_premium_request")
    }

    @Test
    func `extracts github fetch nonce from html`() {
        let html = #"<meta name="x-fetch-nonce" content="v2:abc-123">"#
        #expect(CopilotBudgetWebFetcher.extractFetchNonce(from: html) == "v2:abc-123")
    }

    @Test
    func `extracts github web identity from html`() throws {
        let html = """
        <meta name="octolytics-actor-id" content="123">
        <meta content = "octocat" name = "user-login">
        """

        let identity = try #require(CopilotBudgetWebFetcher.extractGitHubWebIdentity(from: html))

        #expect(identity.id == "123")
        #expect(identity.login == "octocat")
        #expect(CopilotBudgetWebFetcher.webIdentity(identity, matches: "github:user:123"))
        #expect(CopilotBudgetWebFetcher.webIdentity(identity, matches: "OctoCat"))
        #expect(!CopilotBudgetWebFetcher.webIdentity(identity, matches: "github:user:456"))
    }

    @Test
    func `missing github web identity with expected account maps to unknown account mismatch`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                Issue.record("Missing identity should not reach budget JSON endpoint")
                return (Data(#"{"budgets":[],"has_next_page":false}"#.utf8), response)
            }
            return (Data(#"<meta name="x-fetch-nonce" content="nonce">"#.utf8), response)
        }
        let fetcher = CopilotBudgetWebFetcher(
            cookieHeaderOverride: "user_session=missing-identity",
            expectedGitHubAccountIdentifier: "github:user:123",
            transport: transport)

        do {
            _ = try await fetcher.fetchBudgetWindows()
            Issue.record("Expected account mismatch")
        } catch let error as CopilotBudgetWebFetcher.Error {
            #expect(error == .accountMismatch(expected: "github:user:123", actual: nil))
        }

        #expect(await transport.requests().count == 1)
    }

    @Test
    func `invalid github budget page html encoding maps to invalid response`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                Issue.record("Invalid HTML encoding should not reach budget JSON endpoint")
                return (Data(#"{"budgets":[],"has_next_page":false}"#.utf8), response)
            }
            return (Data([0xC3, 0x28]), response)
        }
        let fetcher = CopilotBudgetWebFetcher(
            cookieHeaderOverride: "user_session=invalid-html",
            expectedGitHubAccountIdentifier: "github:user:123",
            transport: transport)

        do {
            _ = try await fetcher.fetchBudgetWindows()
            Issue.record("Expected invalid response")
        } catch let error as CopilotBudgetWebFetcher.Error {
            #expect(error == .invalidResponse)
        }

        #expect(await transport.requests().count == 1)
    }

    @Test
    func `manual budget cookie for different github account is ignored before budget request`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                Issue.record("Mismatched cookie should not reach budget JSON endpoint")
                return (Data(#"{"budgets":[],"has_next_page":false}"#.utf8), response)
            }
            return (
                Data("""
                <meta name="x-fetch-nonce" content="nonce">
                <meta name="octolytics-actor-id" content="456">
                <meta name="user-login" content="otheruser">
                """.utf8),
                response)
        }
        let fetcher = CopilotBudgetWebFetcher(
            cookieHeaderOverride: "user_session=other",
            expectedGitHubAccountIdentifier: "github:user:123",
            transport: transport)

        do {
            _ = try await fetcher.fetchBudgetWindows()
            Issue.record("Expected account mismatch")
        } catch let error as CopilotBudgetWebFetcher.Error {
            #expect(error == .accountMismatch(expected: "github:user:123", actual: "otheruser"))
        }

        #expect(await transport.requests().count == 1)
    }

    @Test
    func `manual budget cookie with matching github account appends budget windows`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                return (
                    Data("""
                    {
                      "budgets": [
                        {
                          "uuid": "budget-1",
                          "pricingTargetId": "premium_requests",
                          "targetAmount": 100.0,
                          "currentAmount": 40.0
                        }
                      ],
                      "has_next_page": false
                    }
                    """.utf8),
                    response)
            }
            return (
                Data("""
                <meta name="x-fetch-nonce" content="nonce">
                <meta name="octolytics-actor-id" content="123">
                <meta name="user-login" content="octocat">
                """.utf8),
                response)
        }
        let fetcher = CopilotBudgetWebFetcher(
            cookieHeaderOverride: "user_session=matching",
            expectedGitHubAccountIdentifier: "github:user:123",
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_780_358_400) })

        let windows = try await fetcher.fetchBudgetWindows()

        #expect(windows.map(\.id) == ["copilot-budget-budget-1"])
        #expect(windows.first?.window.usedPercent == 40)
        #expect(await transport.requests().count == 2)
    }

    @Test
    func `mismatched manual budget cookie leaves normal copilot usage unchanged`() async {
        let registered = URLProtocol.registerClass(CopilotBudgetBindingStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(CopilotBudgetBindingStubURLProtocol.self)
            }
            CopilotBudgetBindingStubURLProtocol.reset()
        }
        CopilotBudgetBindingStubURLProtocol.reset()
        CopilotBudgetBindingStubURLProtocol.handler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.host == "api.github.com", url.path == "/copilot_internal/user" {
                return Self.stubResponse(
                    url: url,
                    data: Data("""
                    {
                      "quota_snapshots": {
                        "premium_interactions": {
                          "entitlement": 300,
                          "remaining": 240,
                          "percent_remaining": 80,
                          "quota_id": "premium"
                        }
                      },
                      "copilot_plan": "pro"
                    }
                    """.utf8))
            }
            if url.host == "api.github.com", url.path == "/user" {
                return Self.stubResponse(
                    url: url,
                    data: Data(#"{"id":123,"login":"expecteduser"}"#.utf8))
            }
            if url.host == "github.com", url.path == "/settings/billing/budgets", url.query == nil {
                return Self.stubResponse(
                    url: url,
                    data: Data("""
                    <meta name="x-fetch-nonce" content="nonce">
                    <meta name="octolytics-actor-id" content="456">
                    <meta name="user-login" content="otheruser">
                    """.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return Self.stubResponse(url: url, data: Data("{}".utf8), statusCode: 404)
        }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .copilot)
        let settings = ProviderSettingsSnapshot.make(copilot: .init(
            apiToken: "selected-token",
            selectedAccountExternalIdentifier: "github:user:123",
            budgetExtrasEnabled: true,
            budgetCookieSource: .manual,
            manualBudgetCookieHeader: "user_session=other"))
        let context = Self.makeFetchContext(settings: settings)

        let outcome = await descriptor.fetchPlan.fetchOutcome(context: context, provider: .copilot)

        guard case let .success(result) = outcome.result else {
            Issue.record("Expected Copilot usage fetch to succeed")
            return
        }
        #expect(result.usage.primary?.usedPercent == 20)
        #expect(result.usage.extraRateWindows == nil)
        #expect(CopilotBudgetBindingStubURLProtocol.requests().contains {
            $0.url?.query?.contains("page=") == true
        } == false)
    }

    @Test
    func `stale selected account identifier is ignored for budget cookie binding`() async {
        let registered = URLProtocol.registerClass(CopilotBudgetBindingStubURLProtocol.self)
        defer {
            if registered {
                URLProtocol.unregisterClass(CopilotBudgetBindingStubURLProtocol.self)
            }
            CopilotBudgetBindingStubURLProtocol.reset()
        }
        CopilotBudgetBindingStubURLProtocol.reset()
        CopilotBudgetBindingStubURLProtocol.handler = { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            if url.host == "api.github.com", url.path == "/copilot_internal/user" {
                return Self.stubResponse(
                    url: url,
                    data: Data("""
                    {
                      "quota_snapshots": {
                        "premium_interactions": {
                          "entitlement": 300,
                          "remaining": 240,
                          "percent_remaining": 80,
                          "quota_id": "premium"
                        }
                      },
                      "copilot_plan": "pro"
                    }
                    """.utf8))
            }
            if url.host == "api.github.com", url.path == "/user" {
                return Self.stubResponse(
                    url: url,
                    data: Data(#"{"id":999,"login":"newuser"}"#.utf8))
            }
            if url.host == "github.com", url.path == "/settings/billing/budgets", url.query == nil {
                return Self.stubResponse(
                    url: url,
                    data: Data("""
                    <meta name="x-fetch-nonce" content="nonce">
                    <meta name="octolytics-actor-id" content="123">
                    <meta name="user-login" content="olduser">
                    """.utf8))
            }
            Issue.record("Unexpected request: \(url.absoluteString)")
            return Self.stubResponse(url: url, data: Data("{}".utf8), statusCode: 404)
        }
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .copilot)
        let settings = ProviderSettingsSnapshot.make(copilot: .init(
            apiToken: "new-selected-token",
            selectedAccountExternalIdentifier: "github:user:123",
            budgetExtrasEnabled: true,
            budgetCookieSource: .manual,
            manualBudgetCookieHeader: "user_session=old-browser-account"))
        let context = Self.makeFetchContext(settings: settings)

        let outcome = await descriptor.fetchPlan.fetchOutcome(context: context, provider: .copilot)

        guard case let .success(result) = outcome.result else {
            Issue.record("Expected Copilot usage fetch to succeed")
            return
        }
        #expect(result.usage.primary?.usedPercent == 20)
        #expect(result.usage.extraRateWindows == nil)
        #expect(CopilotBudgetBindingStubURLProtocol.requests().contains {
            $0.url?.path == "/user"
        })
        #expect(CopilotBudgetBindingStubURLProtocol.requests().contains {
            $0.url?.query?.contains("page=") == true
        } == false)
    }

    @Test
    func `invalid github budget JSON maps to invalid response`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                return (Data("{".utf8), response)
            }
            return (Data(#"<meta name="x-fetch-nonce" content="nonce">"#.utf8), response)
        }
        let fetcher = CopilotBudgetWebFetcher(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_780_358_400) })

        do {
            _ = try await fetcher.fetchBudgetWindows(cookieHeader: "user_session=abc")
            Issue.record("Expected invalidResponse")
        } catch let error as CopilotBudgetWebFetcher.Error {
            #expect(error == .invalidResponse)
        }
    }

    @Test
    func `cached cookie non auth errors do not fall back to browser import`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.store(provider: .copilot, cookieHeader: "user_session=cached", sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .copilot) }

        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 500,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            return (Data("{}".utf8), response)
        }
        let fetcher = CopilotBudgetWebFetcher(transport: transport)

        do {
            _ = try await fetcher.fetchBudgetWindows()
            Issue.record("Expected badStatus")
        } catch let error as CopilotBudgetWebFetcher.Error {
            #expect(error == .badStatus(500))
        }

        #expect(await transport.requests().count == 2)
        #expect(CookieHeaderCache.load(provider: .copilot)?.cookieHeader == "user_session=cached")
    }

    @Test
    func `cached cookie account mismatch clears cache before browser fallback`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.store(provider: .copilot, cookieHeader: "user_session=cached", sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .copilot) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                Issue.record("Mismatched cached cookie should not reach budget JSON endpoint")
                return (Data(#"{"budgets":[],"has_next_page":false}"#.utf8), response)
            }
            return (
                Data("""
                <meta name="x-fetch-nonce" content="nonce">
                <meta name="octolytics-actor-id" content="456">
                <meta name="user-login" content="otheruser">
                """.utf8),
                response)
        }
        let fetcher = CopilotBudgetWebFetcher(
            expectedGitHubAccountIdentifier: "github:user:123",
            browserDetection: BrowserDetection(homeDirectory: temp.path, cacheTTL: 0),
            transport: transport)

        do {
            _ = try await fetcher.fetchBudgetWindows()
            Issue.record("Expected browser fallback to exhaust without a session")
        } catch let error as CopilotBudgetWebFetcher.Error {
            #expect(error == .noSessionCookie)
        }

        #expect(await transport.requests().count == 1)
        #expect(CookieHeaderCache.load(provider: .copilot) == nil)
    }

    @Test
    func `cached cookie missing identity clears cache before browser fallback`() async throws {
        KeychainCacheStore.setTestStoreForTesting(true)
        defer { KeychainCacheStore.setTestStoreForTesting(false) }
        CookieHeaderCache.store(provider: .copilot, cookieHeader: "user_session=cached", sourceLabel: "Chrome")
        defer { CookieHeaderCache.clear(provider: .copilot) }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                Issue.record("Unverifiable cached cookie should not reach budget JSON endpoint")
                return (Data(#"{"budgets":[],"has_next_page":false}"#.utf8), response)
            }
            return (Data(#"<meta name="x-fetch-nonce" content="nonce">"#.utf8), response)
        }
        let fetcher = CopilotBudgetWebFetcher(
            expectedGitHubAccountIdentifier: "github:user:123",
            browserDetection: BrowserDetection(homeDirectory: temp.path, cacheTTL: 0),
            transport: transport)

        do {
            _ = try await fetcher.fetchBudgetWindows()
            Issue.record("Expected browser fallback to exhaust without a session")
        } catch let error as CopilotBudgetWebFetcher.Error {
            #expect(error == .noSessionCookie)
        }

        #expect(await transport.requests().count == 1)
        #expect(CookieHeaderCache.load(provider: .copilot) == nil)
    }

    @Test
    func `budget page request omits content type on get`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: "HTTP/1.1",
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            if request.url?.query?.contains("page=") == true {
                return (Data(#"{"budgets":[],"has_next_page":false}"#.utf8), response)
            }
            return (Data(#"<meta name="x-fetch-nonce" content="nonce">"#.utf8), response)
        }
        let fetcher = CopilotBudgetWebFetcher(transport: transport)

        _ = try await fetcher.fetchBudgetWindows(cookieHeader: "user_session=abc")

        let pageRequest = try #require(await transport.requests().first { $0.url?.query?.contains("page=") == true })
        #expect(pageRequest.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    private static func makeFetchContext(settings: ProviderSettingsSnapshot) -> ProviderFetchContext {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .api,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private static func stubResponse(
        url: URL,
        data: Data,
        statusCode: Int = 200) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }
}

final class CopilotBudgetBindingStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static let _handlerBox = LockIsolated<(@Sendable (URLRequest) throws -> (Data, URLResponse))?>(nil)
    static var handler: (@Sendable (URLRequest) throws -> (Data, URLResponse))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    private nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    static func reset() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.handler = nil
        self.recordedRequests = []
    }

    static func requests() -> [URLRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.recordedRequests
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard self.hasHandler else { return false }
        guard request.url?.scheme == "https" else { return false }
        switch (request.url?.host, request.url?.path) {
        case ("api.github.com", "/copilot_internal/user"),
             ("api.github.com", "/user"),
             ("github.com", "/settings/billing/budgets"):
            return true
        default:
            return false
        }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(self.request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (data, response) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension CopilotBudgetBindingStubURLProtocol {
    fileprivate static var hasHandler: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.handler != nil
    }
}
