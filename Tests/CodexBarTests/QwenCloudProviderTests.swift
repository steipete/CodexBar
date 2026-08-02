import Foundation
import Testing
@testable import CodexBarCore

private func qwenCloudFixture(_ name: String) throws -> Data {
    try Data(
        contentsOf: #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/QwenCloud")))
}

struct QwenCloudSettingsReaderTests {
    @Test
    func `cookie reads from environment`() {
        let cookie = QwenCloudSettingsReader.cookieHeader(environment: [
            QwenCloudSettingsReader.cookieHeaderKey: "\"login_aliyunid_ticket=ticket\"",
        ])
        #expect(cookie == "login_aliyunid_ticket=ticket")
    }

    @Test
    func `quota URL infers HTTPS scheme`() {
        let url = QwenCloudSettingsReader.quotaURL(environment: [
            QwenCloudSettingsReader.quotaURLKey: "quota.qwen-cloud.test/data/api.json",
        ])

        #expect(url?.scheme == "https")
        #expect(url?.host == "quota.qwen-cloud.test")
    }

    @Test
    func `quota URL rejects non HTTPS schemes`() {
        let httpURL = QwenCloudSettingsReader.quotaURL(environment: [
            QwenCloudSettingsReader.quotaURLKey: "http://quota.qwen-cloud.test/data/api.json",
        ])

        #expect(httpURL == nil)
    }

    @Test
    func `host override rejects non HTTPS schemes`() {
        let httpHost = QwenCloudSettingsReader.hostOverride(environment: [
            QwenCloudSettingsReader.hostKey: "http://home.qwen-cloud.test",
        ])
        let httpsHost = QwenCloudSettingsReader.hostOverride(environment: [
            QwenCloudSettingsReader.hostKey: "https://home.qwen-cloud.test",
        ])

        #expect(httpHost == nil)
        #expect(httpsHost == "https://home.qwen-cloud.test")
    }

    @Test
    func `host override normalizes bare hosts to HTTPS`() {
        let bareHost = QwenCloudSettingsReader.hostOverride(environment: [
            QwenCloudSettingsReader.hostKey: "home.qwen-cloud.test",
        ])
        let bareHostWithPort = QwenCloudSettingsReader.hostOverride(environment: [
            QwenCloudSettingsReader.hostKey: "home.qwen-cloud.test:8443",
        ])

        #expect(bareHost == "https://home.qwen-cloud.test")
        #expect(bareHostWithPort == "https://home.qwen-cloud.test:8443")
    }

    @Test
    func `bare host overrides build valid dashboard and quota URLs`() {
        let environment = [QwenCloudSettingsReader.hostKey: "qwen-cloud.test"]

        let dashboard = QwenCloudUsageFetcher.dashboardURL(environment: environment)
        #expect(dashboard.scheme == "https")
        #expect(dashboard.host == "qwen-cloud.test")
        #expect(dashboard.absoluteString.contains("/billing/subscription/token-plan-individual"))

        let quota = QwenCloudUsageFetcher.defaultQuotaURL(environment: environment)
        #expect(quota.scheme == "https")
        #expect(quota.host == "qwen-cloud.test")
        #expect(quota.absoluteString.removingPercentEncoding?.contains("personal/api/v2/usage") == true)
    }

    @Test
    func `default quota URL targets qwen data gateway usage API`() {
        let url = QwenCloudUsageFetcher.defaultQuotaURL
        #expect(url.host == "cs-data.qwencloud.com")
        #expect(url.absoluteString.removingPercentEncoding?.contains("personal/api/v2/usage") == true)
        #expect(url.absoluteString.contains("sfm_bailian"))
    }

    @Test
    func `dashboard URL targets the individual token plan page`() {
        let url = QwenCloudUsageFetcher.dashboardURL
        #expect(url.host == "home.qwencloud.com")
        #expect(url.absoluteString.contains("/billing/subscription/token-plan-individual"))
    }
}

struct QwenCloudUsageSnapshotTests {
    @Test
    func `provider labels current quota windows`() {
        let metadata = QwenCloudProviderDescriptor.descriptor.metadata

        #expect(metadata.sessionLabel == "5-hour")
        #expect(metadata.weeklyLabel == "Weekly")
        #if os(macOS)
        #expect(metadata.browserCookieOrder == [.chrome])
        #expect(QwenCloudWebFetchStrategy.browserOrder == [.chrome])
        #else
        #expect(metadata.browserCookieOrder == nil)
        #endif
    }

    @Test
    func `maps used and total quota to primary window`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = Date(timeIntervalSince1970: 1_700_100_000)
        let snapshot = QwenCloudUsageSnapshot(
            planName: "Token Plan",
            usedQuota: 250,
            totalQuota: 1000,
            remainingQuota: nil,
            resetsAt: reset,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetsAt == reset)
        #expect(usage.primary?.resetDescription == "250 / 1,000 credits used")
        #expect(usage.loginMethod(for: .qwencloud) == "Token Plan")
    }
}

@Suite(.serialized)
struct QwenCloudUsageParsingTests {
    @Test
    func `parses current token plan 5 hour and weekly usage`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let innerJSON = """
        {
          "code": 0,
          "data": {
            "per5HourPercentage": 0.03,
            "per5HourResetTime": 1700003600000,
            "per1WeekPercentage": 0.01,
            "per1WeekResetTime": 1700086400000
          },
          "success": true
        }
        """
        let payload: [String: Any] = [
            "data": [
                "DataV2": [
                    "data": innerJSON,
                ],
            ],
            "httpStatusCode": 200,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let snapshot = try QwenCloudUsageFetcher.parseUsageSnapshot(from: data, now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 3)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_700_003_600))
        #expect(usage.secondary?.usedPercent == 1)
        #expect(usage.secondary?.resetsAt == Date(timeIntervalSince1970: 1_700_086_400))
    }

    @Test
    func `parses nested equity list token plan payload`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try qwenCloudFixture("nested_equity_list")
        let snapshot = try QwenCloudUsageFetcher.parseUsageSnapshot(from: data, now: now)

        #expect(snapshot.totalQuota == 1000)
        #expect(snapshot.remainingQuota == 875)
        #expect(snapshot.usedQuota == 125)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_701_000_000))
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 12.5)
    }

    @Test
    func `parses flat subscription summary payload`() throws {
        let data = try qwenCloudFixture("flat_subscription_summary")
        let snapshot = try QwenCloudUsageFetcher.parseUsageSnapshot(from: data)

        #expect(snapshot.totalQuota == 2000)
        #expect(snapshot.remainingQuota == 1500)
        #expect(snapshot.usedQuota == 500)
    }

    @Test
    func `login payload maps to login required`() throws {
        let data = try qwenCloudFixture("login_required")
        #expect(throws: QwenCloudUsageError.loginRequired) {
            try QwenCloudUsageFetcher.parseUsageSnapshot(from: data)
        }
    }

    @Test
    func `forbidden payload maps to invalid credentials`() throws {
        let data = try qwenCloudFixture("forbidden")
        #expect(throws: QwenCloudUsageError.invalidCredentials) {
            try QwenCloudUsageFetcher.parseUsageSnapshot(from: data)
        }
    }

    @Test
    func `non json payload maps to parse failed`() {
        #expect(throws: QwenCloudUsageError.parseFailed("Invalid JSON response")) {
            try QwenCloudUsageFetcher.parseUsageSnapshot(from: Data("not-json".utf8))
        }
    }

    /// Real-world response shape returned for an authenticated Qwen Cloud account
    /// with no active individual token-plan subscription. Captured live against
    /// `home.qwencloud.com` (requestId/Uid redacted) — the API returns HTTP 200
    /// with `TotalCount: 0` and zeroed quota fields rather than an error, so the
    /// parser must not report a false subscription. Fixture: `Fixtures/QwenCloud/no_active_subscription.json`.
    @Test
    func `authenticated account with no active subscription reports no quota`() throws {
        let data = try qwenCloudFixture("no_active_subscription")
        let snapshot = try QwenCloudUsageFetcher.parseUsageSnapshot(from: data)

        // No subscription instance and zero total → no quota window to display.
        #expect(snapshot.totalQuota == 0 || snapshot.totalQuota == nil)
        #expect(snapshot.usedQuota == nil || snapshot.usedQuota == 0)
        #expect(snapshot.remainingQuota == nil || snapshot.remainingQuota == 0)
        // The primary rate window must not render a false "100% remaining" bar
        // for a non-subscribed account.
        #expect(snapshot.toUsageSnapshot().primary == nil)
    }
}

struct QwenCloudCookieHeaderTests {
    @Test
    func `builds URL scoped headers for API and dashboard`() throws {
        let cookies = [
            self.cookie(name: "login_aliyunid_ticket", value: "ticket", domain: ".qwencloud.com"),
            self.cookie(name: "login_current_pk", value: "account", domain: ".qwencloud.com"),
            self.cookie(name: "modelstudio_only", value: "modelstudio", domain: "modelstudio.console.aliyun.com"),
        ]

        let headers = try #require(QwenCloudCookieHeader.headers(from: cookies))

        #expect(headers.apiCookieHeader.contains("login_aliyunid_ticket=ticket"))
        #expect(headers.apiCookieHeader.contains("login_current_pk=account"))
        #expect(!headers.apiCookieHeader.contains("modelstudio_only=modelstudio"))
    }

    @Test
    func `cached headers preserve URL scoping`() throws {
        let headers = QwenCloudCookieHeaders(
            apiCookieHeader: "login_aliyunid_ticket=ticket; api_only=api",
            dashboardCookieHeader: "login_aliyunid_ticket=ticket; dashboard_only=dashboard")

        let cached = try #require(QwenCloudCookieHeaders(qwenCloudCachedHeader: headers.cacheQwenCloudCookieHeader()))

        #expect(cached.apiCookieHeader.contains("api_only=api"))
        #expect(!cached.apiCookieHeader.contains("dashboard_only=dashboard"))
        #expect(cached.dashboardCookieHeader.contains("dashboard_only=dashboard"))
    }

    private func cookie(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expires: Date = Date(timeIntervalSinceNow: 3600)) -> HTTPCookie
    {
        HTTPCookie(properties: [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
            .expires: expires,
            .secure: true,
        ])!
    }
}

@Suite(.serialized)
struct QwenCloudFetchTests {
    @Test
    func `fetches usage with dashboard sec token preflight`() async throws {
        let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
        let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
        let quotaConfigAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config"
        var requestedAPIs: [String] = []
        QwenCloudStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.host == "qwen-cloud.test",
               url.path == "/billing/subscription/token-plan-individual",
               request.httpMethod == "GET"
            {
                return Self.makeResponse(
                    url: url,
                    body: "<html><script>sec_token = \"qwen-html-token\";</script></html>",
                    statusCode: 200)
            }

            if url.host == "qwen-cloud.test", request.httpMethod == "POST" {
                let body = Self.requestBodyString(from: request)
                let form = try #require(URLComponents(string: "?\(body)"))
                let formValues = Dictionary(uniqueKeysWithValues: form.queryItems?.compactMap { item in
                    item.value.map { (item.name, $0) }
                } ?? [])
                #expect(formValues["sec_token"] == "qwen-html-token")
                #expect(formValues["product"] == "sfm_bailian")
                let paramsData = try #require(formValues["params"]?.data(using: .utf8))
                let params = try #require(JSONSerialization.jsonObject(with: paramsData) as? [String: Any])
                let api = try #require(params["Api"] as? String)
                let data = try #require(params["Data"] as? [String: Any])
                let cornerstone = try #require(data["cornerstoneParam"] as? [String: Any])
                #expect(cornerstone["consoleSite"] as? String == "QWENCLOUD")
                requestedAPIs.append(api)

                let json: String
                switch api {
                case usageAPI:
                    json = """
                    {
                      "data": {
                        "per5HourPercentage": 0.03,
                        "per5HourResetTime": 1700003600000,
                        "per1WeekPercentage": 0.01,
                        "per1WeekResetTime": 1700086400000
                      }
                    }
                    """
                case subscriptionAPI:
                    #expect(data["commodityCode"] as? String == "sfm_tokenplansolo_public_intl")
                    json = #"{"data":{"specCode":"standard","status":"VALID"}}"#
                case quotaConfigAPI:
                    json = """
                    {
                      "data": {
                        "lite": { "five_hour": 1000, "weekly": 10000 },
                        "standard": { "five_hour": 5000, "weekly": 50000 },
                        "pro": { "five_hour": 10000, "weekly": 100000 }
                      }
                    }
                    """
                default:
                    throw URLError(.unsupportedURL)
                }
                return Self.makeResponse(url: url, body: json, statusCode: 200)
            }

            throw URLError(.unsupportedURL)
        }
        defer {
            QwenCloudStubURLProtocol.handler = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QwenCloudStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let transport = ProviderHTTPClient(session: session)
        let snapshot = try await QwenCloudUsageFetcher.fetchUsage(
            apiCookieHeader: "login_aliyunid_ticket=ticket",
            dashboardCookieHeader: "login_aliyunid_ticket=ticket",
            environment: [QwenCloudSettingsReader.hostKey: "https://qwen-cloud.test"],
            transport: transport)

        #expect(requestedAPIs == [usageAPI, subscriptionAPI, quotaConfigAPI])
        #expect(snapshot.planName == "Standard")
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 3)
        #expect(snapshot.toUsageSnapshot().primary?.resetDescription == "150 / 5,000 credits used")
        #expect(snapshot.toUsageSnapshot().secondary?.usedPercent == 1)
        #expect(snapshot.toUsageSnapshot().secondary?.resetDescription == "500 / 50,000 credits used")
    }

    @Test
    func `login page csrf token maps to login required before API requests`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/billing/subscription/token-plan-individual" {
                return Self.makeTransportResponse(
                    url: url,
                    body: """
                    <html>
                      <a href="https://signin.aliyun.com/login">Sign in</a>
                      <script>csrfToken = "login-page-csrf";</script>
                    </html>
                    """,
                    statusCode: 200)
            }
            if url.path == "/tool/user/info.json" {
                return Self.makeTransportResponse(url: url, body: "{}", statusCode: 200)
            }
            throw URLError(.unsupportedURL)
        }

        await #expect(throws: QwenCloudUsageError.loginRequired) {
            try await QwenCloudUsageFetcher.fetchUsage(
                apiCookieHeader: "login_aliyunid_ticket=expired",
                dashboardCookieHeader: "login_aliyunid_ticket=expired",
                environment: [QwenCloudSettingsReader.hostKey: "https://qwen-cloud.test"],
                transport: transport)
        }
    }

    @Test
    func `dashboard timeout maps to network error when token fallbacks are empty`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/billing/subscription/token-plan-individual" {
                throw URLError(.timedOut)
            }
            if url.path == "/tool/user/info.json" {
                return Self.makeTransportResponse(url: url, body: "{}", statusCode: 200)
            }
            throw URLError(.unsupportedURL)
        }

        let error = await #expect(throws: QwenCloudUsageError.self) {
            try await QwenCloudUsageFetcher.fetchUsage(
                apiCookieHeader: "login_aliyunid_ticket=ticket",
                dashboardCookieHeader: "login_aliyunid_ticket=ticket",
                environment: [QwenCloudSettingsReader.hostKey: "https://qwen-cloud.test"],
                transport: transport)
        }
        guard case .networkError = error else {
            Issue.record("Expected networkError, got \(String(describing: error))")
            return
        }
    }

    @Test
    func `dashboard server failure maps to network error when token fallbacks are empty`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/billing/subscription/token-plan-individual" {
                return Self.makeTransportResponse(url: url, body: "Unavailable", statusCode: 503)
            }
            if url.path == "/tool/user/info.json" {
                return Self.makeTransportResponse(url: url, body: "{}", statusCode: 200)
            }
            throw URLError(.unsupportedURL)
        }

        let error = await #expect(throws: QwenCloudUsageError.self) {
            try await QwenCloudUsageFetcher.fetchUsage(
                apiCookieHeader: "login_aliyunid_ticket=ticket",
                dashboardCookieHeader: "login_aliyunid_ticket=ticket",
                environment: [QwenCloudSettingsReader.hostKey: "https://qwen-cloud.test"],
                transport: transport)
        }
        guard case .networkError = error else {
            Issue.record("Expected networkError, got \(String(describing: error))")
            return
        }
    }

    @Test
    func `dashboard failure still allows sec token cookie fallback`() async throws {
        let dashboardURL = try #require(URL(string: "https://qwen-cloud.test/dashboard"))
        let resolver = OneConsoleSECTokenResolver(configuration: .init(
            dashboardURL: { _ in dashboardURL },
            userInfoPath: "/tool/user/info.json",
            isLoginPage: { _ in false }))
        let transport = ProviderHTTPTransportHandler { _ in
            throw URLError(.timedOut)
        }

        let resolved = try await resolver.resolve(
            cookieHeader: "login_aliyunid_ticket=ticket; sec_token=cookie-token",
            environment: [:],
            transport: transport)

        #expect(resolved.value == "cookie-token")
        #expect(resolved.source == .cookie)
    }

    @Test
    func `user info resolver preserves sec token key priority`() async throws {
        let dashboardURL = try #require(URL(string: "https://qwen-cloud.test/dashboard"))
        let resolver = OneConsoleSECTokenResolver(configuration: .init(
            dashboardURL: { _ in dashboardURL },
            userInfoPath: "/tool/user/info.json",
            isLoginPage: { _ in false }))
        let transport = ProviderHTTPTransportHandler { request in
            guard let url = request.url else { throw URLError(.badURL) }
            if url.path == "/dashboard" {
                return Self.makeTransportResponse(url: url, body: "<html></html>", statusCode: 200)
            }
            if url.path == "/tool/user/info.json" {
                return Self.makeTransportResponse(
                    url: url,
                    body: """
                    {
                      "token": "generic-token",
                      "data": {
                        "secToken": "",
                        "nested": { "secToken": "preferred-sec-token" }
                      }
                    }
                    """,
                    statusCode: 200)
            }
            throw URLError(.unsupportedURL)
        }

        let resolved = try await resolver.resolve(
            cookieHeader: "login_aliyunid_ticket=ticket",
            environment: [:],
            transport: transport)

        #expect(resolved.value == "preferred-sec-token")
        #expect(resolved.source == .userInfo)
    }

    @Test
    func `redirect routing strips cross origin credentials and blocks preserved bodies`() throws {
        let apiURL = try #require(URL(string: "https://cs-data.qwencloud.com/data/api.json"))
        let dashboardRedirect = try #require(URL(string: "https://home.qwencloud.com/redirected"))
        let crossHostURL = try #require(URL(string: "https://signin.aliyun.com/login"))
        let insecureURL = try #require(URL(string: "http://home.qwencloud.com/login"))
        let untrustedPortURL = try #require(URL(string: "https://home.qwencloud.com:8443/login"))
        let redirectResponse = try #require(HTTPURLResponse(
            url: apiURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": dashboardRedirect.absoluteString]))
        let routing = OneConsoleCookieRouting(
            apiURL: apiURL,
            dashboardURL: dashboardRedirect,
            apiCookieHeader: "api_cookie=value",
            dashboardCookieHeader: "dashboard_cookie=value")

        var apiRequest = URLRequest(url: apiURL)
        apiRequest.httpMethod = "POST"
        apiRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        apiRequest.setValue("api_cookie=value", forHTTPHeaderField: "Cookie")
        apiRequest.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        apiRequest.setValue("Basic proxy-secret", forHTTPHeaderField: "Proxy-Authorization")
        apiRequest.setValue("api-key-secret", forHTTPHeaderField: "x-api-key")
        apiRequest.setValue("csrf-secret", forHTTPHeaderField: "x-csrf-token")
        apiRequest.setValue("xsrf-secret", forHTTPHeaderField: "x-xsrf-token")
        apiRequest.httpBody = Data("sec_token=secret".utf8)

        var crossHostRedirect = URLRequest(url: crossHostURL)
        crossHostRedirect.httpMethod = "GET"
        crossHostRedirect.setValue("old=value", forHTTPHeaderField: "Cookie")
        crossHostRedirect.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        crossHostRedirect.setValue("Basic proxy-secret", forHTTPHeaderField: "Proxy-Authorization")
        crossHostRedirect.setValue("api-key-secret", forHTTPHeaderField: "x-api-key")
        crossHostRedirect.setValue("csrf-secret", forHTTPHeaderField: "x-csrf-token")
        crossHostRedirect.setValue("xsrf-secret", forHTTPHeaderField: "x-xsrf-token")
        let routedCrossHost = try #require(routing.redirectedRequest(
            forRedirectFrom: apiRequest,
            response: redirectResponse,
            to: crossHostRedirect))
        #expect(routedCrossHost.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(routedCrossHost.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(routedCrossHost.value(forHTTPHeaderField: "Proxy-Authorization") == nil)
        #expect(routedCrossHost.value(forHTTPHeaderField: "x-api-key") == nil)
        #expect(routedCrossHost.value(forHTTPHeaderField: "x-csrf-token") == nil)
        #expect(routedCrossHost.value(forHTTPHeaderField: "x-xsrf-token") == nil)
        #expect(routedCrossHost.httpBody == nil)

        var sameHostRedirect = URLRequest(url: dashboardRedirect)
        sameHostRedirect.httpMethod = "GET"
        sameHostRedirect.setValue("old=value", forHTTPHeaderField: "Cookie")
        sameHostRedirect.setValue("csrf-secret", forHTTPHeaderField: "x-csrf-token")
        let routedDashboard = try #require(routing.redirectedRequest(
            forRedirectFrom: apiRequest,
            response: redirectResponse,
            to: sameHostRedirect))
        #expect(routedDashboard.value(forHTTPHeaderField: "Cookie") == "dashboard_cookie=value")
        #expect(routedDashboard.value(forHTTPHeaderField: "x-csrf-token") == nil)
        #expect(routedDashboard.httpBody == nil)

        for statusCode in [307, 308] {
            let preservedRedirectResponse = try #require(HTTPURLResponse(
                url: apiURL,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": crossHostURL.absoluteString]))

            var apiRedirect = URLRequest(url: apiURL)
            apiRedirect.httpMethod = "POST"
            apiRedirect.httpBody = Data("sec_token=secret".utf8)
            let routedAPI = try #require(routing.redirectedRequest(
                forRedirectFrom: apiRequest,
                response: preservedRedirectResponse,
                to: apiRedirect))
            #expect(routedAPI.value(forHTTPHeaderField: "Cookie") == "api_cookie=value")
            #expect(routedAPI.httpBody == Data("sec_token=secret".utf8))

            var externalPreservedPOST = URLRequest(url: crossHostURL)
            externalPreservedPOST.httpMethod = "POST"
            externalPreservedPOST.httpBody = Data("sec_token=secret".utf8)
            #expect(routing.redirectedRequest(
                forRedirectFrom: apiRequest,
                response: preservedRedirectResponse,
                to: externalPreservedPOST) == nil)

            var dashboardPreservedPOST = URLRequest(url: dashboardRedirect)
            dashboardPreservedPOST.httpMethod = "POST"
            dashboardPreservedPOST.httpBody = Data("sec_token=secret".utf8)
            #expect(routing.redirectedRequest(
                forRedirectFrom: apiRequest,
                response: preservedRedirectResponse,
                to: dashboardPreservedPOST) == nil)
        }

        var untrustedPortRedirect = URLRequest(url: untrustedPortURL)
        untrustedPortRedirect.setValue("old=value", forHTTPHeaderField: "Cookie")
        let routedUntrustedPort = try #require(routing.redirectedRequest(
            forRedirectFrom: apiRequest,
            response: redirectResponse,
            to: untrustedPortRedirect))
        #expect(routedUntrustedPort.value(forHTTPHeaderField: "Cookie") == nil)

        let insecureRedirect = URLRequest(url: insecureURL)
        #expect(routing.redirectedRequest(
            forRedirectFrom: apiRequest,
            response: redirectResponse,
            to: insecureRedirect) == nil)

        let notModified = try #require(HTTPURLResponse(
            url: apiURL,
            statusCode: 304,
            httpVersion: "HTTP/1.1",
            headerFields: nil))
        #expect(routing.redirectedRequest(
            forRedirectFrom: apiRequest,
            response: notModified,
            to: crossHostRedirect) == nil)
    }

    private static func makeResponse(url: URL, body: String, statusCode: Int) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
    }

    private static func makeTransportResponse(
        url: URL,
        body: String,
        statusCode: Int) -> (Data, URLResponse)
    {
        let (response, data) = self.makeResponse(url: url, body: body, statusCode: statusCode)
        return (data, response)
    }

    private static func requestBodyString(from request: URLRequest) -> String {
        if let data = request.httpBody {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let stream = request.httpBodyStream {
            stream.open()
            defer {
                stream.close()
            }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 {
                    break
                }
                data.append(buffer, count: count)
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return ""
    }
}

struct QwenCloudCookieImportValidationTests {
    #if os(macOS)
    @Test
    func `accepts passport ticket sessions`() {
        let cookies = [
            self.cookie(name: "login_aliyunid_ticket", value: "ticket", domain: ".alibabacloud.com"),
        ]
        #expect(QwenCloudCookieImport.isAuthenticatedSession(cookies: cookies))
    }

    @Test
    func `accepts qwen scoped sso sessions`() {
        let cookies = [
            self.cookie(name: "qwen_sso_ticket", value: "sso-ticket", domain: ".qwencloud.com"),
        ]
        #expect(QwenCloudCookieImport.isAuthenticatedSession(cookies: cookies))
    }

    @Test
    func `accepts current qwen cloud login tickets`() {
        let cookies = [
            self.cookie(name: "login_qwencloud_ticket", value: "ticket", domain: ".qwencloud.com"),
        ]
        #expect(QwenCloudCookieImport.isAuthenticatedSession(cookies: cookies))
    }

    @Test
    func `rejects locale and account cookies without a login ticket`() {
        // A browser profile that merely visited qwencloud.com carries locale
        // preferences, account-id markers, and CSRF cookies while logged out;
        // none of them prove an authenticated session.
        let cookies = [
            self.cookie(name: "locale_pref", value: "en-US", domain: ".qwencloud.com"),
            self.cookie(name: "login_aliyunid_pk", value: "1234567890", domain: ".qwencloud.com"),
            self.cookie(name: "login_current_pk", value: "1234567890", domain: ".home.qwencloud.com"),
            self.cookie(name: "sec_token", value: "csrf-token", domain: ".home.qwencloud.com"),
        ]
        #expect(!QwenCloudCookieImport.isAuthenticatedSession(cookies: cookies))
    }

    @Test
    func `rejects sessions without recognized cookies`() {
        let cookies = [
            self.cookie(name: "unrelated", value: "x", domain: ".example.com"),
        ]
        #expect(!QwenCloudCookieImport.isAuthenticatedSession(cookies: cookies))
    }

    private func cookie(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expires: Date = Date(timeIntervalSinceNow: 3600)) -> HTTPCookie
    {
        HTTPCookie(properties: [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
            .expires: expires,
            .secure: true,
        ])!
    }
    #endif
}

final class QwenCloudStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "home.qwencloud.com" || host == "qwen-cloud.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Opt-in live smoke test against the real Qwen Cloud console.
///
/// Disabled by default so CI / `make test` never touch the network or Keychain.
/// To run it against your own account:
///   1. Copy a `Cookie:` header from `https://home.qwencloud.com/billing/subscription/token-plan-individual`
///   2. Temporarily remove the `.disabled(...)` trait below (keep the guard)
///   3. QWEN_CLOUD_LIVE_TEST=1 QWEN_CLOUD_COOKIE='login_aliyunid_ticket=...; ...' \
///        swift test --filter QwenCloudLiveSmokeTests
@Suite(.serialized)
struct QwenCloudLiveSmokeTests {
    @Test(.disabled("Set QWEN_CLOUD_LIVE_TEST=1 and QWEN_CLOUD_COOKIE to run live Qwen Cloud checks."))
    func `live token plan usage resolves`() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QWEN_CLOUD_LIVE_TEST"] == "1" else { return }
        guard let cookie = environment["QWEN_CLOUD_COOKIE"],
              !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            Issue.record("QWEN_CLOUD_COOKIE is not set; paste a Cookie header from the Qwen Cloud billing page.")
            return
        }

        let snapshot = try await QwenCloudUsageFetcher.fetchUsage(
            apiCookieHeader: cookie,
            environment: environment)

        func describe(_ value: (some Any)?) -> String {
            value.map { "\($0)" } ?? "<nil>"
        }

        print(
            """
            [qwen-cloud-live] plan=\(describe(snapshot.planName)) \
            used=\(describe(snapshot.usedQuota)) \
            total=\(describe(snapshot.totalQuota)) \
            remaining=\(describe(snapshot.remainingQuota)) \
            resetsAt=\(describe(snapshot.resetsAt))
            """)

        // An authenticated account must not be treated as logged out.
        #expect(snapshot.updatedAt > Date(timeIntervalSince1970: 0))
        // A subscribed account reports a total; a free/empty account may legitimately be nil.
        if snapshot.totalQuota == nil {
            print("[qwen-cloud-live] No active token-plan total reported (account may have no subscription).")
        } else {
            #expect((snapshot.totalQuota ?? 0) >= 0)
        }
    }
}
