import Foundation
import Testing
@testable import CodexBarCore

private func alibabaTokenPlanFixture(_ name: String) throws -> Data {
    try Data(
        contentsOf: #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/AlibabaTokenPlan")))
}

struct AlibabaTokenPlanSettingsReaderTests {
    @Test
    func `cookie reads from environment`() {
        let cookie = AlibabaTokenPlanSettingsReader.cookieHeader(environment: [
            AlibabaTokenPlanSettingsReader.cookieHeaderKey: "\"login_aliyunid_ticket=ticket\"",
        ])
        #expect(cookie == "login_aliyunid_ticket=ticket")
    }

    @Test
    func `quota URL infers HTTPS scheme`() {
        let url = AlibabaTokenPlanSettingsReader.quotaURL(environment: [
            AlibabaTokenPlanSettingsReader.quotaURLKey: "quota.token-plan.test/data/api.json",
        ])

        #expect(url?.scheme == "https")
        #expect(url?.host == "quota.token-plan.test")
    }

    @Test
    func `quota URL rejects non HTTPS schemes`() {
        let httpURL = AlibabaTokenPlanSettingsReader.quotaURL(environment: [
            AlibabaTokenPlanSettingsReader.quotaURLKey: "http://quota.token-plan.test/data/api.json",
        ])
        let ftpURL = AlibabaTokenPlanSettingsReader.quotaURL(environment: [
            AlibabaTokenPlanSettingsReader.quotaURLKey: "ftp://quota.token-plan.test/data/api.json",
        ])

        #expect(httpURL == nil)
        #expect(ftpURL == nil)
    }

    @Test
    func `host override rejects non HTTPS schemes`() {
        let httpHost = AlibabaTokenPlanSettingsReader.hostOverride(environment: [
            AlibabaTokenPlanSettingsReader.hostKey: "http://dashboard.token-plan.test",
        ])
        let httpsHost = AlibabaTokenPlanSettingsReader.hostOverride(environment: [
            AlibabaTokenPlanSettingsReader.hostKey: "https://dashboard.token-plan.test",
        ])
        let bareHost = AlibabaTokenPlanSettingsReader.hostOverride(environment: [
            AlibabaTokenPlanSettingsReader.hostKey: "dashboard.token-plan.test",
        ])

        #expect(httpHost == nil)
        #expect(httpsHost == "dashboard.token-plan.test")
        #expect(bareHost == "dashboard.token-plan.test")
    }

    @Test
    func `default quota URL targets subscription summary API`() {
        let url = AlibabaTokenPlanUsageFetcher.defaultQuotaURL
        #expect(url.host == "modelstudio.console.alibabacloud.com")
        #expect(url.absoluteString.contains("GetSubscriptionSummary"))
        #expect(url.absoluteString.contains("BssOpenAPI-V3"))
    }

    @Test
    func `default quota URL for china mainland targets bailian`() {
        let url = AlibabaTokenPlanUsageFetcher.defaultQuotaURL(region: .chinaMainland)
        #expect(url.host == "bailian.console.aliyun.com")
        #expect(url.absoluteString.contains("GetSubscriptionSummary"))
        #expect(url.absoluteString.contains("BssOpenAPI-V3"))
    }

    @Test
    func `personal variants target their rolling window hosts without changing Team routes`() {
        let internationalTeam = AlibabaTokenPlanUsageFetcher.defaultQuotaURL(region: .international)
        let mainlandTeam = AlibabaTokenPlanUsageFetcher.defaultQuotaURL(region: .chinaMainland)
        let internationalPersonal = AlibabaTokenPlanUsageFetcher.defaultQuotaURL(region: .internationalPersonal)
        let mainlandPersonal = AlibabaTokenPlanUsageFetcher.defaultQuotaURL(region: .chinaMainlandPersonal)

        #expect(internationalTeam.host == "modelstudio.console.alibabacloud.com")
        #expect(mainlandTeam.host == "bailian.console.aliyun.com")
        #expect(internationalTeam.absoluteString.contains("GetSubscriptionSummary"))
        #expect(mainlandTeam.absoluteString.contains("GetSubscriptionSummary"))
        #expect(internationalPersonal.host == "bailian-singapore-cs.alibabacloud.com")
        #expect(mainlandPersonal.host == "bailian-cs.console.aliyun.com")
        #expect(internationalPersonal.absoluteString.removingPercentEncoding?.contains("personal/api/v2/usage") == true)
        #expect(mainlandPersonal.absoluteString.removingPercentEncoding?.contains("personal/api/v2/usage") == true)
        #expect(!internationalPersonal.absoluteString.contains("GetSubscriptionSummary"))
        #expect(!mainlandPersonal.absoluteString.contains("GetSubscriptionSummary"))
    }
}

struct AlibabaTokenPlanCookieHeaderTests {
    @Test
    func `builds URL scoped headers for API and dashboard`() throws {
        let cookies = [
            self.cookie(name: "login_aliyunid_ticket", value: "ticket", domain: ".alibabacloud.com"),
            self.cookie(name: "login_current_pk", value: "account", domain: ".alibabacloud.com"),
            self.cookie(name: "sec_token", value: "shared", domain: ".console.alibabacloud.com"),
            self.cookie(name: "sec_token", value: "dashboard", domain: "modelstudio.console.alibabacloud.com"),
            self.cookie(name: "bailian_only", value: "bailian", domain: "bailian.console.aliyun.com"),
        ]

        let headers = try #require(AlibabaTokenPlanCookieHeader.headers(from: cookies))

        #expect(headers.apiCookieHeader.contains("login_aliyunid_ticket=ticket"))
        #expect(headers.apiCookieHeader.contains("login_current_pk=account"))
        #expect(headers.apiCookieHeader.contains("sec_token=dashboard"))
        #expect(!headers.apiCookieHeader.contains("bailian_only=bailian"))
        #expect(headers.dashboardCookieHeader.contains("sec_token=dashboard"))
        #expect(!headers.dashboardCookieHeader.contains("bailian_only=bailian"))
    }

    @Test
    func `builds URL scoped headers for china mainland region`() throws {
        let cookies = [
            self.cookie(name: "login_aliyunid_ticket", value: "ticket", domain: ".aliyun.com"),
            self.cookie(name: "login_current_pk", value: "account", domain: ".aliyun.com"),
            self.cookie(name: "sec_token", value: "shared", domain: ".console.aliyun.com"),
            self.cookie(name: "sec_token", value: "dashboard", domain: "bailian.console.aliyun.com"),
            self.cookie(name: "modelstudio_only", value: "modelstudio", domain: "modelstudio.console.alibabacloud.com"),
        ]

        let headers = try #require(AlibabaTokenPlanCookieHeader.headers(from: cookies, region: .chinaMainland))

        #expect(headers.apiCookieHeader.contains("login_aliyunid_ticket=ticket"))
        #expect(headers.apiCookieHeader.contains("login_current_pk=account"))
        #expect(headers.apiCookieHeader.contains("sec_token=dashboard"))
        #expect(!headers.apiCookieHeader.contains("modelstudio_only=modelstudio"))
        #expect(headers.dashboardCookieHeader.contains("sec_token=dashboard"))
        #expect(!headers.dashboardCookieHeader.contains("modelstudio_only=modelstudio"))
    }

    @Test
    func `mainland Personal rebuilds cookies for the quota host`() throws {
        let cookies = [
            self.cookie(name: "parent", value: "shared", domain: ".console.aliyun.com"),
            self.cookie(name: "dashboard_only", value: "dashboard", domain: "bailian.console.aliyun.com"),
            self.cookie(name: "quota_only", value: "quota", domain: "bailian-cs.console.aliyun.com"),
            self.cookie(name: "collision", value: "dashboard", domain: "bailian.console.aliyun.com"),
            self.cookie(name: "collision", value: "quota", domain: "bailian-cs.console.aliyun.com"),
        ]

        let headers = try #require(AlibabaTokenPlanCookieHeader.headers(
            from: cookies,
            region: .chinaMainlandPersonal))

        #expect(headers.apiCookieHeader.contains("parent=shared"))
        #expect(headers.apiCookieHeader.contains("quota_only=quota"))
        #expect(headers.apiCookieHeader.contains("collision=quota"))
        #expect(!headers.apiCookieHeader.contains("dashboard_only=dashboard"))
        #expect(headers.dashboardCookieHeader.contains("parent=shared"))
        #expect(headers.dashboardCookieHeader.contains("dashboard_only=dashboard"))
        #expect(headers.dashboardCookieHeader.contains("collision=dashboard"))
        #expect(!headers.dashboardCookieHeader.contains("quota_only=quota"))
    }

    @Test
    func `international Personal rebuilds cookies for the quota host`() throws {
        let cookies = [
            self.cookie(name: "parent", value: "shared", domain: ".alibabacloud.com"),
            self.cookie(
                name: "dashboard_only",
                value: "dashboard",
                domain: "modelstudio.console.alibabacloud.com"),
            self.cookie(
                name: "quota_only",
                value: "quota",
                domain: "bailian-singapore-cs.alibabacloud.com"),
        ]

        let headers = try #require(AlibabaTokenPlanCookieHeader.headers(
            from: cookies,
            region: .internationalPersonal))

        #expect(headers.apiCookieHeader.contains("parent=shared"))
        #expect(headers.apiCookieHeader.contains("quota_only=quota"))
        #expect(!headers.apiCookieHeader.contains("dashboard_only=dashboard"))
        #expect(headers.dashboardCookieHeader.contains("parent=shared"))
        #expect(headers.dashboardCookieHeader.contains("dashboard_only=dashboard"))
        #expect(!headers.dashboardCookieHeader.contains("quota_only=quota"))
    }

    @Test
    func `cached token plan headers preserve URL scoping`() throws {
        let headers = AlibabaTokenPlanCookieHeaders(
            apiCookieHeader: "login_aliyunid_ticket=ticket; api_only=api",
            dashboardCookieHeader: "login_aliyunid_ticket=ticket; dashboard_only=dashboard")

        let cached = try #require(
            AlibabaTokenPlanCookieHeaders(alibabaTokenPlanCachedHeader: headers.cacheAlibabaTokenPlanCookieHeader()))

        #expect(cached.apiCookieHeader.contains("api_only=api"))
        #expect(!cached.apiCookieHeader.contains("dashboard_only=dashboard"))
        #expect(cached.dashboardCookieHeader.contains("dashboard_only=dashboard"))
        #expect(!cached.dashboardCookieHeader.contains("api_only=api"))
    }

    @Test
    func `builds headers from environment scoped URLs`() throws {
        let cookies = [
            self.cookie(name: "login_aliyunid_ticket", value: "ticket", domain: ".token-plan.test"),
            self.cookie(name: "api_only", value: "api", domain: "quota.token-plan.test"),
            self.cookie(name: "dashboard_only", value: "dashboard", domain: "dashboard.token-plan.test"),
            self.cookie(name: "prod_api_only", value: "prod-api", domain: "modelstudio.console.alibabacloud.com"),
            self.cookie(
                name: "prod_dashboard_only",
                value: "prod-dashboard",
                domain: "modelstudio.console.alibabacloud.com"),
        ]

        let headers = try #require(AlibabaTokenPlanCookieHeader.headers(
            from: cookies,
            environment: [
                AlibabaTokenPlanSettingsReader.quotaURLKey: "https://quota.token-plan.test/data/api.json",
                AlibabaTokenPlanSettingsReader.hostKey: "https://dashboard.token-plan.test",
            ]))

        #expect(headers.apiCookieHeader.contains("login_aliyunid_ticket=ticket"))
        #expect(headers.apiCookieHeader.contains("api_only=api"))
        #expect(!headers.apiCookieHeader.contains("prod_api_only=prod-api"))
        #expect(headers.dashboardCookieHeader.contains("dashboard_only=dashboard"))
        #expect(!headers.dashboardCookieHeader.contains("prod_dashboard_only=prod-dashboard"))
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

struct AlibabaTokenPlanUsageSnapshotTests {
    @Test
    func `maps used and total quota to primary window`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reset = Date(timeIntervalSince1970: 1_700_100_000)
        let snapshot = AlibabaTokenPlanUsageSnapshot(
            planName: "TOKEN PLAN",
            usedQuota: 250,
            totalQuota: 1000,
            remainingQuota: nil,
            resetsAt: reset,
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.resetsAt == reset)
        #expect(usage.primary?.resetDescription == "250 / 1,000 credits used")
        #expect(usage.loginMethod(for: .alibabatokenplan) == "TOKEN PLAN")
    }

    @Test
    func `does not create primary window from balance only`() {
        let snapshot = AlibabaTokenPlanUsageSnapshot(
            planName: "TOKEN PLAN",
            usedQuota: nil,
            totalQuota: nil,
            remainingQuota: 700,
            resetsAt: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.loginMethod(for: .alibabatokenplan) == "TOKEN PLAN")
    }

    @Test
    func `emits a weekly window when 5 hour usage is absent`() {
        let snapshot = AlibabaTokenPlanUsageSnapshot(
            planName: "Personal",
            usedQuota: nil,
            totalQuota: nil,
            remainingQuota: nil,
            resetsAt: nil,
            weeklyUsedPercent: 10,
            weeklyTotalQuota: 40000,
            weeklyResetsAt: Date(timeIntervalSince1970: 1_785_234_900),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(usage.secondary?.usedPercent == 10)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(usage.secondary?.resetDescription == "4,000 / 40,000 credits used")
    }
}

@Suite(.serialized)
struct AlibabaTokenPlanUsageParsingTests {
    @Test
    func `shared Personal parser maps issue documented rolling windows and tier quotas`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = try AlibabaTokenPlanPersonalUsageParser.parse(
            from: alibabaTokenPlanFixture("personal_usage"),
            subscriptionData: alibabaTokenPlanFixture("personal_subscription"),
            quotaConfigData: alibabaTokenPlanFixture("personal_quota_config"),
            now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.fiveHourTotalQuota == 12000)
        #expect(snapshot.weeklyTotalQuota == 40000)
        #expect(abs((usage.primary?.usedPercent ?? -.infinity) - 0.09973083333333333) < 0.000_000_001)
        #expect(usage.primary?.windowMinutes == 5 * 60)
        #expect(usage.primary?.resetsAt == Date(timeIntervalSince1970: 1_784_813_220))
        #expect(abs((usage.secondary?.usedPercent ?? -.infinity) - 0.03014725) < 0.000_000_001)
        #expect(usage.secondary?.windowMinutes == 7 * 24 * 60)
        #expect(usage.secondary?.resetsAt == Date(timeIntervalSince1970: 1_785_234_900))
        #expect(usage.loginMethod(for: .alibabatokenplan) == "Pro")
    }

    @Test
    func `shared Personal parser accepts weekly only responses`() throws {
        let json = """
        {
          "data": {
            "DataV2": {
              "data": {
                "success": true,
                "data": {
                  "per1WeekPercentage": 0.10007527475,
                  "per1WeekResetTime": 1785234900000
                }
              }
            }
          },
          "successResponse": true
        }
        """

        let snapshot = try AlibabaTokenPlanPersonalUsageParser.parse(
            from: Data(json.utf8),
            subscriptionData: nil,
            quotaConfigData: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary == nil)
        #expect(abs((usage.secondary?.usedPercent ?? -.infinity) - 10.007527475) < 0.000_000_001)
        #expect(usage.secondary?.resetsAt == Date(timeIntervalSince1970: 1_785_234_900))
    }

    @Test
    func `Personal login error maps to login required`() {
        let json = """
        {
          "data": {
            "success": false,
            "errorCode": "BailianGateway.Login.NotLogined",
            "errorMsg": "BailianGateway.Login.NotLogined"
          },
          "httpStatusCode": "200"
        }
        """

        #expect(throws: AlibabaTokenPlanUsageError.loginRequired) {
            try AlibabaTokenPlanPersonalUsageParser.parse(
                from: Data(json.utf8),
                subscriptionData: nil,
                quotaConfigData: nil,
                now: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    @Test
    func `parses subscription summary payload`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let json = """
        {
          "Success": true,
          "Data": {
            "TotalCount": 1,
            "TotalValue": 1000,
            "TotalSurplusValue": 875,
            "NearestExpireDate": 1701000000000
          },
          "Code": "200"
        }
        """

        let snapshot = try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8), now: now)

        #expect(snapshot.planName == "TOKEN PLAN")
        #expect(snapshot.usedQuota == 125)
        #expect(snapshot.totalQuota == 1000)
        #expect(snapshot.remainingQuota == 875)
        #expect(snapshot.resetsAt == Date(timeIntervalSince1970: 1_701_000_000))
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 12.5)
    }

    @Test
    func `parses nested subscription summary body`() throws {
        let body = """
        {
          "success": true,
          "data": {
            "totalCount": 1,
            "totalSurplusValue": 750,
            "totalValue": 1000
          }
        }
        """
        let payload = ["successResponse": ["body": body]]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let snapshot = try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: data)

        #expect(snapshot.planName == "TOKEN PLAN")
        #expect(snapshot.usedQuota == 250)
        #expect(snapshot.remainingQuota == 750)
        #expect(snapshot.totalQuota == 1000)
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 25)
    }

    @Test
    func `empty subscription summary stays visible without quota window`() throws {
        let json = """
        {
          "Success": true,
          "Data": {
            "TotalCount": 0
          }
        }
        """

        let snapshot = try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))

        #expect(snapshot.planName == nil)
        #expect(snapshot.totalQuota == nil)
        #expect(snapshot.toUsageSnapshot().primary == nil)
    }

    @Test
    func `login payload maps to login required`() {
        let json = """
        {
          "code": "ConsoleNeedLogin",
          "message": "You need to log in.",
          "successResponse": false
        }
        """

        #expect(throws: AlibabaTokenPlanUsageError.loginRequired) {
            try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func `post only token payload maps to login required`() {
        let json = """
        {
          "code": "PostonlyOrTokenError",
          "message": "Your request has expired. Please refresh the page.",
          "successResponse": false
        }
        """

        #expect(throws: AlibabaTokenPlanUsageError.loginRequired) {
            try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func `nested unsuccessful subscription summary maps to API error`() throws {
        let body = """
        {
          "success": false,
          "message": "Subscription lookup failed"
        }
        """
        let payload = ["successResponse": ["body": body]]
        let data = try JSONSerialization.data(withJSONObject: payload)

        #expect(throws: AlibabaTokenPlanUsageError.apiError("Subscription lookup failed")) {
            try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: data)
        }
    }

    @Test
    func `forbidden payload maps to invalid credentials`() {
        let json = """
        {
          "statusCode": 403,
          "message": "Forbidden"
        }
        """

        #expect(throws: AlibabaTokenPlanUsageError.invalidCredentials) {
            try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func `failed forbidden payload maps to invalid credentials`() {
        let json = """
        {
          "successResponse": false,
          "statusCode": 403,
          "message": "Forbidden"
        }
        """

        #expect(throws: AlibabaTokenPlanUsageError.invalidCredentials) {
            try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(json.utf8))
        }
    }

    @Test
    func `html login payload maps to login required`() {
        let html = """
        <html>
          <body>Please login to Alibaba Cloud</body>
        </html>
        """

        #expect(throws: AlibabaTokenPlanUsageError.loginRequired) {
            try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data(html.utf8))
        }
    }

    @Test
    func `non json payload maps to parse failed`() {
        #expect(throws: AlibabaTokenPlanUsageError.parseFailed("Invalid JSON response")) {
            try AlibabaTokenPlanUsageFetcher.parseUsageSnapshot(from: Data("not-json".utf8))
        }
    }

    @Test
    func `mainland Personal fetch resolves SEC token and omits hardcoded workspace agent`() async throws {
        defer {
            AlibabaTokenPlanStubURLProtocol.handler = nil
        }
        let usageBody = try #require(String(data: alibabaTokenPlanFixture("personal_usage"), encoding: .utf8))
        let subscriptionBody = try #require(
            String(data: alibabaTokenPlanFixture("personal_subscription"), encoding: .utf8))
        let quotaBody = try #require(
            String(data: alibabaTokenPlanFixture("personal_quota_config"), encoding: .utf8))

        AlibabaTokenPlanStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.host == "bailian.console.aliyun.com", request.httpMethod == "GET" {
                #expect(request.value(forHTTPHeaderField: "Cookie") == "dashboard_only=dashboard")
                if url.path == "/tool/user/info.json" {
                    let json = """
                    {
                      "code": "200",
                      "data": {
                        "secToken": "personal-sec-token"
                      },
                      "successResponse": true
                    }
                    """
                    return Self.makeResponse(url: url, body: json, statusCode: 200)
                }
                return Self.makeResponse(url: url, body: "<html></html>", statusCode: 200)
            }

            #expect(url.host == "bailian-cs.console.aliyun.com")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "quota_only=quota")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://bailian.console.aliyun.com")
            let body = Self.requestBodyString(from: request)
            #expect(body.contains("sec_token=personal-sec-token"))
            #expect(!body.contains("switchAgent"))
            #expect(body.removingPercentEncoding?.contains("cornerstoneParam") == true)

            let api = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "api" })?
                .value
            switch api {
            case "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage":
                return Self.makeResponse(url: url, body: usageBody, statusCode: 200)
            case "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription":
                #expect(body.removingPercentEncoding?.contains("sfm_tokenplansolo_public_cn") == true)
                return Self.makeResponse(url: url, body: subscriptionBody, statusCode: 200)
            case "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/quota-config":
                return Self.makeResponse(url: url, body: quotaBody, statusCode: 200)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlibabaTokenPlanStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let snapshot = try await AlibabaTokenPlanUsageFetcher.fetchUsage(
            apiCookieHeader: "quota_only=quota",
            dashboardCookieHeader: "dashboard_only=dashboard",
            region: .chinaMainlandPersonal,
            environment: [:],
            session: session)

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.toUsageSnapshot().primary != nil)
        #expect(snapshot.toUsageSnapshot().secondary != nil)
    }

    @Test
    func `Personal fetch continues without SEC token when preflight cannot resolve one`() async throws {
        defer {
            AlibabaTokenPlanStubURLProtocol.handler = nil
        }
        let usageBody = try #require(String(data: alibabaTokenPlanFixture("personal_usage"), encoding: .utf8))

        AlibabaTokenPlanStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.host == "bailian.console.aliyun.com", request.httpMethod == "GET" {
                return Self.makeResponse(url: url, body: "<html></html>", statusCode: 200)
            }

            #expect(url.host == "bailian-cs.console.aliyun.com")
            let body = Self.requestBodyString(from: request)
            #expect(!body.contains("sec_token"))
            let api = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "api" })?
                .value
            switch api {
            case "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage":
                return Self.makeResponse(url: url, body: usageBody, statusCode: 200)
            default:
                return Self.makeResponse(
                    url: url,
                    body: "{\"code\":\"200\",\"successResponse\":true}",
                    statusCode: 200)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlibabaTokenPlanStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let snapshot = try await AlibabaTokenPlanUsageFetcher.fetchUsage(
            apiCookieHeader: "quota_only=quota",
            dashboardCookieHeader: "dashboard_only=dashboard",
            region: .chinaMainlandPersonal,
            environment: [:],
            session: session)

        #expect(snapshot.fiveHourUsedPercent != nil)
        #expect(snapshot.weeklyUsedPercent != nil)
    }

    @Test
    func `nested workspace authorization failure remains a provider error instead of API error 200`() throws {
        // Live envelope observed for Personal/Solo requests missing valid
        // workspace state (issue #2500): the outer envelope claims success
        // while the nested frame carries the real gateway error.
        let payload: [String: Any] = [
            "code": "200",
            "data": [
                "success": false,
                "httpStatus": 200,
                "errorCode": "BailianGateway.Workspace.NotAuthorised",
                "api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
                "errorMsg": "BailianGateway.Workspace.NotAuthorised",
            ],
            "httpStatusCode": "200",
            "requestId": "676df096-861c-4d38-974c-b93f2f16083e",
            "successResponse": true,
        ]

        #expect(throws: AlibabaTokenPlanUsageError.apiError("BailianGateway.Workspace.NotAuthorised")) {
            try AlibabaTokenPlanUsageFetcher.throwIfErrorPayload(payload)
        }
    }

    @Test
    func `nested gateway failure surfaces the real error message`() throws {
        let payload: [String: Any] = [
            "code": "200",
            "data": [
                "success": false,
                "httpStatus": 200,
                "errorCode": "BailianGateway.Quota.ServiceUnavailable",
                "errorMsg": "quota service unavailable",
            ],
            "httpStatusCode": "200",
            "successResponse": true,
        ]

        #expect(throws: AlibabaTokenPlanUsageError.apiError("quota service unavailable")) {
            try AlibabaTokenPlanUsageFetcher.throwIfErrorPayload(payload)
        }
    }

    @Test
    func `SEC token preflight falls back to user info`() async throws {
        defer {
            AlibabaTokenPlanStubURLProtocol.handler = nil
        }

        let hostOverride = "https://alibaba-token-plan.test:9443"
        let environment: [String: String] = [
            AlibabaTokenPlanSettingsReader.hostKey: hostOverride,
        ]
        let expectedReferer = AlibabaTokenPlanUsageFetcher.dashboardURL(
            region: .international,
            environment: environment).absoluteString

        AlibabaTokenPlanStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.host == "alibaba-token-plan.test",
               url.path == "/ap-southeast-1/",
               request.httpMethod == "GET"
            {
                #expect(url.port == 9443)
                return Self.makeResponse(url: url, body: "<html></html>", statusCode: 200)
            }

            if url.host == "alibaba-token-plan.test",
               url.path == "/tool/user/info.json",
               request.httpMethod == "GET"
            {
                #expect(url.port == 9443)
                #expect(request.value(forHTTPHeaderField: "Cookie") == "login_aliyunid_ticket=ticket; raw_only=keep")
                #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
                let json = """
                {
                  "code": "200",
                  "data": {
                    "secToken": "user-info-token"
                  },
                  "successResponse": true
                }
                """
                return Self.makeResponse(url: url, body: json, statusCode: 200)
            }

            if url.host == "alibaba-token-plan.test", request.httpMethod == "POST" {
                #expect(request.value(forHTTPHeaderField: "Cookie") == "login_aliyunid_ticket=ticket; raw_only=keep")
                #expect(request.value(forHTTPHeaderField: "Origin") == "https://modelstudio.console.alibabacloud.com")
                #expect(request.value(forHTTPHeaderField: "Referer") == expectedReferer)
                let body = Self.requestBodyString(from: request)
                #expect(body.contains("sec_token=user-info-token"))
                #expect(body.contains("GetSubscriptionSummary"))
                #expect(body.contains("BssOpenAPI-V3"))
                #expect(body.contains("ProductCode"))
                #expect(body.contains("sfm_tokenplanteams_dp_intl"))
                let json = """
                {
                  "Success": true,
                  "Data": {
                    "TotalCount": 1,
                    "TotalValue": 1000,
                    "TotalSurplusValue": 900
                  }
                }
                """
                return Self.makeResponse(url: url, body: json, statusCode: 200)
            }

            throw URLError(.unsupportedURL)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlibabaTokenPlanStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let snapshot = try await AlibabaTokenPlanUsageFetcher.fetchUsage(
            apiCookieHeader: "login_aliyunid_ticket=ticket; raw_only=keep",
            dashboardCookieHeader: "login_aliyunid_ticket=ticket; raw_only=keep",
            environment: environment,
            session: session)

        #expect(snapshot.planName == "TOKEN PLAN")
    }

    @Test
    func `SEC token preflight uses injected session`() async throws {
        AlibabaTokenPlanStubURLProtocol.handler = { request in
            guard let url = request.url else { throw URLError(.badURL) }

            if url.host == "session-token.test", request.httpMethod == "GET" {
                return Self.makeResponse(
                    url: url,
                    body: "<html><script>sec_token = \"session-html-token\";</script></html>",
                    statusCode: 200)
            }

            if url.host == "session-token.test", request.httpMethod == "POST" {
                let body = Self.requestBodyString(from: request)
                #expect(body.contains("sec_token=session-html-token"))
                let json = """
                {
                  "Success": true,
                  "Data": {
                    "TotalCount": 1,
                    "TotalValue": 1000,
                    "TotalSurplusValue": 900
                  }
                }
                """
                return Self.makeResponse(url: url, body: json, statusCode: 200)
            }

            throw URLError(.unsupportedURL)
        }
        defer {
            AlibabaTokenPlanStubURLProtocol.handler = nil
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AlibabaTokenPlanStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let snapshot = try await AlibabaTokenPlanUsageFetcher.fetchUsage(
            apiCookieHeader: "login_aliyunid_ticket=ticket",
            dashboardCookieHeader: "login_aliyunid_ticket=ticket",
            environment: [AlibabaTokenPlanSettingsReader.hostKey: "https://session-token.test"],
            session: session)

        #expect(snapshot.planName == "TOKEN PLAN")
    }

    @Test
    func `redirect preserves cookie only for same host HTTPS requests`() throws {
        let sourceURL = try #require(URL(string: "https://bailian.console.aliyun.com/data/api.json"))
        let sameHostURL = try #require(URL(string: "https://bailian.console.aliyun.com/redirected"))
        let crossHostURL = try #require(URL(string: "https://signin.aliyun.com/login"))
        let insecureURL = try #require(URL(string: "http://bailian.console.aliyun.com/redirected"))
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: nil))

        var sameHostRequest = URLRequest(url: sameHostURL)
        sameHostRequest.setValue("old=value", forHTTPHeaderField: "Cookie")
        let sameHostRedirect = try #require(AlibabaTokenPlanUsageFetcher.redirectedRequest(
            response: response,
            request: sameHostRequest,
            cookieHeader: "login_aliyunid_ticket=ticket"))
        #expect(sameHostRedirect.value(forHTTPHeaderField: "Cookie") == "login_aliyunid_ticket=ticket")

        var crossHostRequest = URLRequest(url: crossHostURL)
        crossHostRequest.setValue("old=value", forHTTPHeaderField: "Cookie")
        let crossHostRedirect = try #require(AlibabaTokenPlanUsageFetcher.redirectedRequest(
            response: response,
            request: crossHostRequest,
            cookieHeader: "login_aliyunid_ticket=ticket"))
        #expect(crossHostRedirect.value(forHTTPHeaderField: "Cookie") == nil)

        let insecureRedirect = AlibabaTokenPlanUsageFetcher.redirectedRequest(
            response: response,
            request: URLRequest(url: insecureURL),
            cookieHeader: "login_aliyunid_ticket=ticket")
        #expect(insecureRedirect == nil)
    }

    @Test
    func `dashboard redirect preserves dashboard cookie header`() throws {
        let sourceURL = try #require(URL(string: "https://bailian.console.aliyun.com/cn-beijing"))
        let targetURL = try #require(URL(string: "https://bailian.console.aliyun.com/redirected"))
        let response = try #require(HTTPURLResponse(
            url: sourceURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: nil))
        var request = URLRequest(url: targetURL)
        request.setValue("api_only=wrong", forHTTPHeaderField: "Cookie")

        let redirected = try #require(AlibabaTokenPlanUsageFetcher.redirectedRequest(
            response: response,
            request: request,
            cookieHeader: "dashboard_only=keep"))

        #expect(redirected.value(forHTTPHeaderField: "Cookie") == "dashboard_only=keep")
    }

    private static func makeResponse(url: URL, body: String, statusCode: Int) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (response, Data(body.utf8))
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

struct AlibabaTokenPlanCLIUsageTests {
    @Test
    func `parses both independent quota windows from sanitized CLI output`() throws {
        let now = Date(timeIntervalSince1970: 1_787_000_000)
        let data = Data(#"""
        {
            "per5HourPercentage": 0.25,
            "per5HourResetTime": 1787000400000,
            "per1WeekPercentage": 0.70,
            "per1WeekResetTime": 1787001180000,
            "ignored": "not imported"
        }
        """#.utf8)

        let snapshot = try AlibabaTokenPlanCLIUsageParser.parse(data, now: now)

        #expect(snapshot.fiveHourUsedPercent == 25)
        #expect(snapshot.fiveHourResetsAt == Date(timeIntervalSince1970: 1_787_000_400))
        #expect(snapshot.weeklyUsedPercent == 70)
        #expect(snapshot.weeklyResetsAt == Date(timeIntervalSince1970: 1_787_001_180))
        #expect(snapshot.updatedAt == now)
        #expect(snapshot.toUsageSnapshot().primary?.remainingPercent == 75)
        #expect(snapshot.toUsageSnapshot().secondary?.remainingPercent == 30)
    }

    @Test
    func `accepts either valid window independently`() throws {
        let weeklyOnly = try AlibabaTokenPlanCLIUsageParser.parse(Data(#"""
        {
            "per5HourPercentage": "invalid",
            "per5HourResetTime": 1787000400000,
            "per1WeekPercentage": 0.70
        }
        """#.utf8))
        #expect(weeklyOnly.fiveHourUsedPercent == nil)
        #expect(weeklyOnly.fiveHourResetsAt == nil)
        #expect(weeklyOnly.weeklyUsedPercent == 70)

        let fiveHourOnly = try AlibabaTokenPlanCLIUsageParser.parse(Data(#"""
        {
            "per5HourPercentage": 0.10,
            "per1WeekPercentage": 1.5,
            "per1WeekResetTime": 1787001180000
        }
        """#.utf8))
        #expect(fiveHourOnly.fiveHourUsedPercent == 10)
        #expect(fiveHourOnly.weeklyUsedPercent == nil)
        #expect(fiveHourOnly.weeklyResetsAt == nil)
    }

    @Test
    func `rejects payload without a valid allowlisted quota window`() {
        #expect(throws: AlibabaTokenPlanCLIUsageError.invalidOutput) {
            try AlibabaTokenPlanCLIUsageParser.parse(Data(#"""
            {
                "per5HourPercentage": true,
                "per1WeekPercentage": -0.1,
                "percentage": 0.5
            }
            """#.utf8))
        }
    }

    @Test
    func `maps all provider regions to Bailian CLI argv without a shell`() {
        #expect(AlibabaTokenPlanCLIUsageFetcher.arguments(region: .chinaMainland) == [
            "usage", "token-plan", "--console-region", "cn-beijing",
            "--console-site", "domestic", "--output", "json",
        ])
        #expect(AlibabaTokenPlanCLIUsageFetcher.arguments(region: .chinaMainlandPersonal) ==
            AlibabaTokenPlanCLIUsageFetcher.arguments(region: .chinaMainland))
        #expect(AlibabaTokenPlanCLIUsageFetcher.arguments(region: .international) == [
            "usage", "token-plan", "--console-region", "ap-southeast-1",
            "--console-site", "international", "--output", "json",
        ])
        #expect(AlibabaTokenPlanCLIUsageFetcher.arguments(region: .internationalPersonal) ==
            AlibabaTokenPlanCLIUsageFetcher.arguments(region: .international))
    }

    @Test
    func `detects only an executable bl on PATH`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alibaba-token-plan-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("bl")
        try Data("#!/bin/sh\n".utf8).write(to: binary)

        #expect(AlibabaTokenPlanCLIUsageFetcher.resolveBinary(environment: ["PATH": directory.path]) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        #expect(AlibabaTokenPlanCLIUsageFetcher.resolveBinary(environment: ["PATH": directory.path]) == binary.path)
    }

    @Test
    func `cancelled CLI probe surfaces CancellationError instead of commandFailed`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alibaba-token-plan-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("bl")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)

        let task = Task {
            try await AlibabaTokenPlanCLIUsageFetcher.fetch(
                region: .chinaMainland,
                environment: ["PATH": directory.path])
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func `descriptor offers Auto CLI and Web sources`() {
        #expect(AlibabaTokenPlanProviderDescriptor.descriptor.fetchPlan.sourceModes == [.auto, .cli, .web])
        #expect(AlibabaTokenPlanProviderDescriptor.descriptor.cli.isBrowserSupportExempt(
            sourceMode: .auto,
            environment: nil,
            settings: nil))
        #expect(AlibabaTokenPlanProviderDescriptor.descriptor.cli.isBrowserSupportExempt(
            sourceMode: .cli,
            environment: nil,
            settings: nil))
    }
}

@Suite(.serialized)
struct AlibabaTokenPlanWebStrategyTests {
    private struct StubClaudeFetcher: ClaudeUsageFetching {
        func loadLatestUsage(model _: String) async throws -> ClaudeUsageSnapshot {
            throw ClaudeUsageError.parseFailed("stub")
        }

        func debugRawProbe(model _: String) async -> String {
            "stub"
        }

        func detectVersion() -> String? {
            nil
        }
    }

    @Test
    func `Auto orders CLI before Web while explicit modes stay strict`() async throws {
        let auto = await AlibabaTokenPlanProviderDescriptor.resolveStrategies(
            context: self.context(region: .chinaMainlandPersonal, sourceMode: .auto))
        let cli = await AlibabaTokenPlanProviderDescriptor.resolveStrategies(
            context: self.context(region: .chinaMainlandPersonal, sourceMode: .cli))
        let web = await AlibabaTokenPlanProviderDescriptor.resolveStrategies(
            context: self.context(region: .chinaMainlandPersonal, sourceMode: .web))

        #expect(auto.map(\.id) == ["alibaba-token-plan.cli", "alibaba-token-plan.web"])
        #expect(cli.map(\.id) == ["alibaba-token-plan.cli"])
        #expect(web.map(\.id) == ["alibaba-token-plan.web"])
        let cliStrategy = AlibabaTokenPlanCLIFetchStrategy { _, _ in
            throw AlibabaTokenPlanCLIUsageError.commandFailed
        }
        #expect(cliStrategy.shouldFallback(
            on: AlibabaTokenPlanCLIUsageError.commandFailed,
            context: self.context(region: .chinaMainlandPersonal, sourceMode: .auto)))
        #expect(!cliStrategy.shouldFallback(
            on: AlibabaTokenPlanCLIUsageError.commandFailed,
            context: self.context(region: .chinaMainlandPersonal, sourceMode: .cli)))

        let success = AlibabaTokenPlanCLIFetchStrategy { region, _ in
            #expect(region == .chinaMainlandPersonal)
            return AlibabaTokenPlanUsageSnapshot(
                planName: "Token Plan",
                usedQuota: nil,
                totalQuota: nil,
                remainingQuota: nil,
                resetsAt: nil,
                weeklyUsedPercent: 70,
                updatedAt: Date(timeIntervalSince1970: 1_787_000_000))
        }
        let result = try await success.fetch(
            self.context(region: .chinaMainlandPersonal, sourceMode: .cli))
        #expect(result.sourceLabel == "cli")
        #expect(result.strategyID == "alibaba-token-plan.cli")
    }

    private func clearCookieCaches() {
        CookieHeaderCache.clear(provider: .alibabatokenplan)
        for region in AlibabaTokenPlanAPIRegion.allCases {
            CookieHeaderCache.clear(provider: .alibabatokenplan, scope: region.cookieCacheScope)
        }
    }

    @Test
    func `workspace permission failure preserves cached browser cookies`() async {
        await self.withIsolatedCookieCache {
            self.clearCookieCaches()
            defer { self.clearCookieCaches() }

            let region = AlibabaTokenPlanAPIRegion.chinaMainlandPersonal
            let cachedHeader = "login_aliyunid_ticket=valid-ticket; gateway=personal"
            CookieHeaderCache.store(
                provider: .alibabatokenplan,
                scope: region.cookieCacheScope,
                cookieHeader: cachedHeader,
                sourceLabel: "Personal fixture")

            let strategy = AlibabaTokenPlanWebFetchStrategy { _, _, _ in
                throw AlibabaTokenPlanUsageError.apiError("BailianGateway.Workspace.NotAuthorised")
            }

            await #expect(throws: AlibabaTokenPlanUsageError.apiError(
                "BailianGateway.Workspace.NotAuthorised"))
            {
                _ = try await strategy.fetch(self.context(region: region))
            }
            #expect(CookieHeaderCache.load(
                provider: .alibabatokenplan,
                scope: region.cookieCacheScope)?.cookieHeader == cachedHeader)
        }
    }

    @Test
    func `auto web strategy surfaces cookie import errors`() async throws {
        try await self.withIsolatedCookieCache {
            let strategy = AlibabaTokenPlanWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                alibabaTokenPlan: ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = ProviderFetchContext(
                runtime: .cli,
                sourceMode: .web,
                includeCredits: false,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: [:],
                settings: settings,
                fetcher: UsageFetcher(environment: [:]),
                claudeFetcher: StubClaudeFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0))

            self.clearCookieCaches()
            defer { self.clearCookieCaches() }

            try await AlibabaCodingPlanCookieImporter.withImportSessionOverrideForTesting { _, _ in
                throw AlibabaCodingPlanSettingsError.missingCookie(
                    details: "macOS Keychain denied access to Chrome Safe Storage.")
            } operation: {
                #expect(await strategy.isAvailable(context))

                do {
                    _ = try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeader(context: context, allowCached: false)
                    Issue.record("Expected cookie import failure to be surfaced")
                } catch let error as AlibabaTokenPlanSettingsError {
                    guard case let .missingCookie(details) = error else {
                        Issue.record("Expected missingCookie, got \(error)")
                        return
                    }
                    #expect(details == "macOS Keychain denied access to Chrome Safe Storage.")
                    #expect(error.localizedDescription.contains("Alibaba Token Plan"))
                    #expect(!error.localizedDescription.contains("Alibaba Coding Plan"))
                }
            }
        }
    }

    @Test
    func `auto web strategy imports subscription scoped token plan cookies`() throws {
        try self.withIsolatedCookieCache {
            let strategy = AlibabaTokenPlanWebFetchStrategy()
            let settings = ProviderSettingsSnapshot.make(
                alibabaTokenPlan: ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let context = ProviderFetchContext(
                runtime: .cli,
                sourceMode: .web,
                includeCredits: false,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: [:],
                settings: settings,
                fetcher: UsageFetcher(environment: [:]),
                claudeFetcher: StubClaudeFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0))

            self.clearCookieCaches()
            defer { self.clearCookieCaches() }

            let headers = try AlibabaCodingPlanCookieImporter.withImportSessionOverrideForTesting { _, _ in
                AlibabaCodingPlanCookieImporter.SessionInfo(
                    cookies: [
                        self.cookie(name: "login_aliyunid_ticket", value: "ticket", domain: ".alibabacloud.com"),
                        self.cookie(name: "login_current_pk", value: "account", domain: ".alibabacloud.com"),
                        self.cookie(
                            name: "dashboard_only",
                            value: "dashboard",
                            domain: "modelstudio.console.alibabacloud.com"),
                        self.cookie(
                            name: "bailian_only",
                            value: "bailian",
                            domain: "bailian.console.aliyun.com"),
                        self.cookie(name: "aliyun_only", value: "aliyun", domain: ".aliyun.com"),
                    ],
                    sourceLabel: "Chrome Default")
            } operation: {
                try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeaders(context: context, allowCached: false)
            }

            #expect(headers.apiCookieHeader == headers.dashboardCookieHeader)
            #expect(headers.apiCookieHeader.contains("dashboard_only=dashboard"))
            #expect(!headers.apiCookieHeader.contains("bailian_only=bailian"))
            #expect(!headers.apiCookieHeader.contains("aliyun_only=aliyun"))
            #expect(headers.dashboardCookieHeader.contains("dashboard_only=dashboard"))
            #expect(!headers.dashboardCookieHeader.contains("bailian_only=bailian"))
            #expect(!headers.dashboardCookieHeader.contains("aliyun_only=aliyun"))

            let cachedHeaders = try AlibabaCodingPlanCookieImporter.withImportSessionOverrideForTesting { _, _ in
                throw AlibabaCodingPlanSettingsError.missingCookie(details: "unexpected import")
            } operation: {
                try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeaders(
                    context: context,
                    allowCached: true)
            }
            #expect(cachedHeaders.apiCookieHeader == headers.apiCookieHeader)
            #expect(cachedHeaders.dashboardCookieHeader == headers.dashboardCookieHeader)
            #expect(strategy.id == "alibaba-token-plan.web")
        }
    }

    @Test
    func `auto web strategy scopes imported cookies to environment overrides`() throws {
        try self.withIsolatedCookieCache {
            let settings = ProviderSettingsSnapshot.make(
                alibabaTokenPlan: ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings(
                    cookieSource: .auto,
                    manualCookieHeader: nil))
            let environment = [
                AlibabaTokenPlanSettingsReader.quotaURLKey: "https://quota.token-plan.test/data/api.json",
                AlibabaTokenPlanSettingsReader.hostKey: "https://dashboard.token-plan.test",
            ]
            let context = ProviderFetchContext(
                runtime: .cli,
                sourceMode: .web,
                includeCredits: false,
                webTimeout: 1,
                webDebugDumpHTML: false,
                verbose: false,
                env: environment,
                settings: settings,
                fetcher: UsageFetcher(environment: environment),
                claudeFetcher: StubClaudeFetcher(),
                browserDetection: BrowserDetection(cacheTTL: 0))

            self.clearCookieCaches()
            defer { self.clearCookieCaches() }

            let headers = try AlibabaCodingPlanCookieImporter.withImportSessionOverrideForTesting { _, _ in
                AlibabaCodingPlanCookieImporter.SessionInfo(
                    cookies: [
                        self.cookie(name: "login_aliyunid_ticket", value: "ticket", domain: ".token-plan.test"),
                        self.cookie(name: "api_only", value: "api", domain: "quota.token-plan.test"),
                        self.cookie(name: "dashboard_only", value: "dashboard", domain: "dashboard.token-plan.test"),
                        self.cookie(name: "prod_api_only", value: "prod-api", domain: "bailian.console.aliyun.com"),
                        self.cookie(
                            name: "prod_dashboard_only",
                            value: "prod-dashboard",
                            domain: "bailian.console.aliyun.com"),
                    ],
                    sourceLabel: "Chrome Default")
            } operation: {
                try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeaders(context: context, allowCached: false)
            }

            #expect(headers.apiCookieHeader.contains("api_only=api"))
            #expect(!headers.apiCookieHeader.contains("prod_api_only=prod-api"))
            #expect(headers.dashboardCookieHeader.contains("dashboard_only=dashboard"))
            #expect(!headers.dashboardCookieHeader.contains("prod_dashboard_only=prod-dashboard"))
        }
    }

    @Test
    func `cached browser cookies stay isolated by gateway region`() throws {
        try self.withIsolatedCookieCache {
            self.clearCookieCaches()
            defer { self.clearCookieCaches() }
            CookieHeaderCache.store(
                provider: .alibabatokenplan,
                scope: AlibabaTokenPlanAPIRegion.international.cookieCacheScope,
                cookieHeader: "login_aliyunid_ticket=intl-ticket; gateway=intl",
                sourceLabel: "International fixture")
            CookieHeaderCache.store(
                provider: .alibabatokenplan,
                scope: AlibabaTokenPlanAPIRegion.chinaMainland.cookieCacheScope,
                cookieHeader: "login_aliyunid_ticket=cn-ticket; gateway=cn",
                sourceLabel: "China fixture")
            try AlibabaCodingPlanCookieImporter.withImportSessionOverrideForTesting { _, _ in
                throw AlibabaCodingPlanSettingsError.missingCookie(details: "unexpected import")
            } operation: {
                let context = self.context(region: .international)
                let international = try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeaders(
                    context: context,
                    allowCached: true,
                    region: .international)
                let china = try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeaders(
                    context: context,
                    allowCached: true,
                    region: .chinaMainland)

                #expect(international.apiCookieHeader.contains("gateway=intl"))
                #expect(!international.apiCookieHeader.contains("gateway=cn"))
                #expect(china.apiCookieHeader.contains("gateway=cn"))
                #expect(!china.apiCookieHeader.contains("gateway=intl"))
            }
        }
    }

    @Test
    func `legacy unscoped cache migrates only to China gateway`() throws {
        try self.withIsolatedCookieCache {
            self.clearCookieCaches()
            defer { self.clearCookieCaches() }
            CookieHeaderCache.store(
                provider: .alibabatokenplan,
                cookieHeader: "login_aliyunid_ticket=legacy; gateway=legacy-cn",
                sourceLabel: "Legacy fixture")
            let context = self.context(region: .international)
            let international = try AlibabaCodingPlanCookieImporter.withImportSessionOverrideForTesting { _, _ in
                AlibabaCodingPlanCookieImporter.SessionInfo(
                    cookies: [
                        self.cookie(
                            name: "login_aliyunid_ticket",
                            value: "intl",
                            domain: ".alibabacloud.com"),
                        self.cookie(
                            name: "gateway",
                            value: "intl",
                            domain: "modelstudio.console.alibabacloud.com"),
                    ],
                    sourceLabel: "International fixture")
            } operation: {
                try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeaders(
                    context: context,
                    allowCached: true,
                    region: .international)
            }

            let china = try AlibabaCodingPlanCookieImporter.withImportSessionOverrideForTesting { _, _ in
                throw AlibabaCodingPlanSettingsError.missingCookie(details: "unexpected China import")
            } operation: {
                try AlibabaTokenPlanWebFetchStrategy.resolveCookieHeaders(
                    context: context,
                    allowCached: true,
                    region: .chinaMainland)
            }

            #expect(international.apiCookieHeader.contains("gateway=intl"))
            #expect(!international.apiCookieHeader.contains("gateway=legacy-cn"))
            #expect(china.apiCookieHeader.contains("gateway=legacy-cn"))
            #expect(CookieHeaderCache.load(provider: .alibabatokenplan) == nil)
            #expect(CookieHeaderCache.load(
                provider: .alibabatokenplan,
                scope: AlibabaTokenPlanAPIRegion.chinaMainland.cookieCacheScope) != nil)
        }
    }

    private func withIsolatedCookieCache<T>(_ operation: () throws -> T) rethrows -> T {
        try KeychainCacheStore.withServiceOverrideForTesting(
            "alibaba-token-plan-web-strategy-tests-\(UUID().uuidString)",
            operation: {
                try KeychainCacheStore.withImplicitTestStoreForTesting(operation: operation)
            })
    }

    private func withIsolatedCookieCache<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await KeychainCacheStore.withServiceOverrideForTesting(
            "alibaba-token-plan-web-strategy-tests-\(UUID().uuidString)",
            operation: {
                try await KeychainCacheStore.withImplicitTestStoreForTesting(operation: operation)
            })
    }

    private func context(
        region: AlibabaTokenPlanAPIRegion,
        sourceMode: ProviderSourceMode = .web) -> ProviderFetchContext
    {
        let settings = ProviderSettingsSnapshot.make(
            alibabaTokenPlan: ProviderSettingsSnapshot.AlibabaTokenPlanProviderSettings(
                cookieSource: .auto,
                manualCookieHeader: nil,
                apiRegion: region))
        return ProviderFetchContext(
            runtime: .cli,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(environment: [:]),
            claudeFetcher: StubClaudeFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0))
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

final class AlibabaTokenPlanStubURLProtocol: URLProtocol {
    private static let _handlerBox = LockIsolated<((URLRequest) throws -> (HTTPURLResponse, Data))?>(nil)
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { Self._handlerBox.value }
        set { Self._handlerBox.setValue(newValue) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "bailian.console.aliyun.com" ||
            host == "bailian-cs.console.aliyun.com" ||
            host == "bailian-singapore-cs.alibabacloud.com" ||
            host == "alibaba-token-plan.test" ||
            host == "session-token.test"
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
