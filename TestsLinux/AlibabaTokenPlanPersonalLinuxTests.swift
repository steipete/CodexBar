import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// Payload shapes captured from home.qwencloud.com's "Token Plan (Individual)" console.
private enum Fixtures {
    static let usage = Data("""
    {"code":"200","data":{"DataV2":{"ret":["SUCCESS::OK"],"data":{"msg":"Success.","code":"SUCCESS",
    "data":{"per5HourPercentage":0.010549299152142857,"per1WeekResetTime":1785066000000,
    "per5HourResetTime":1784479200000,"per1WeekPercentage":0.0029538037626},"success":true}},
    "success":true,"httpStatus":200,"errorCode":"","errorMsg":""},"successResponse":true}
    """.utf8)

    static let subscription = Data("""
    {"code":"200","data":{"DataV2":{"data":{"msg":"Success.","code":"SUCCESS",
    "data":{"instanceCode":"sfm_tokenplansolo_public_intl-sg-x1","specCode":"lite","remainingDays":31,
    "startTime":1784460830000,"endTime":1787155200000,"autoRenewFlag":false,"status":"VALID"},
    "success":true}},"success":true,"httpStatus":200,"errorMsg":""},"successResponse":true}
    """.utf8)

    static let quotaConfig = Data("""
    {"code":"200","data":{"DataV2":{"data":{"msg":"Success.","code":"SUCCESS",
    "data":{"standard":{"five_hour":3000.0,"weekly":10000.0},"lite":{"five_hour":700.0,"weekly":2500.0},
    "pro":{"five_hour":12000.0,"weekly":40000.0}},"success":true}},
    "success":true,"httpStatus":200,"errorMsg":""},"successResponse":true}
    """.utf8)

    static let gatewayFailure = Data("""
    {"code":"200","data":{"success":false,"errorCode":"ConsoleNeedLogin","errorMsg":"Please log in."},
    "successResponse":false}
    """.utf8)
}

struct AlibabaTokenPlanPersonalAPITests {
    @Test
    func `parses rolling window percentages as fractions of one`() throws {
        let usage = try AlibabaTokenPlanPersonalAPI.parseUsage(from: Fixtures.usage)

        #expect(abs(usage.fiveHourPercent - 1.0549299152142857) < 0.000_001)
        #expect(abs(usage.weeklyPercent - 0.29538037626) < 0.000_001)
        #expect(usage.fiveHourResetsAt == Date(timeIntervalSince1970: 1_784_479_200))
        #expect(usage.weeklyResetsAt == Date(timeIntervalSince1970: 1_785_066_000))
    }

    @Test
    func `parses subscription tier and status`() throws {
        let subscription = try AlibabaTokenPlanPersonalAPI.parseSubscription(from: Fixtures.subscription)

        #expect(subscription.specCode == "lite")
        #expect(subscription.status == "VALID")
    }

    @Test
    func `plan name reflects tier and flags a lapsed subscription`() {
        #expect(AlibabaTokenPlanPersonalAPI.planName(specCode: "lite", status: "VALID") == "Token Plan Lite")
        #expect(AlibabaTokenPlanPersonalAPI.planName(specCode: "LITE", status: nil) == "Token Plan Lite")
        #expect(AlibabaTokenPlanPersonalAPI.planName(specCode: nil, status: nil) == "Token Plan")
        #expect(
            AlibabaTokenPlanPersonalAPI.planName(specCode: "pro", status: "EXPIRED") ==
                "Token Plan Pro (EXPIRED)")
        // Unknown tiers pass through verbatim rather than being mangled by capitalization.
        #expect(AlibabaTokenPlanPersonalAPI.planName(specCode: "ultra_x1", status: nil) == "Token Plan ultra_x1")
    }

    @Test
    func `tier lookup is case insensitive`() throws {
        let config = try AlibabaTokenPlanPersonalAPI.parseQuotaConfig(from: Fixtures.quotaConfig)

        #expect(AlibabaTokenPlanPersonalAPI.tier(for: "LITE", in: config)?.fiveHour == 700)
        #expect(AlibabaTokenPlanPersonalAPI.tier(for: "nope", in: config) == nil)
        #expect(AlibabaTokenPlanPersonalAPI.tier(for: nil, in: config) == nil)
    }

    @Test
    func `quota config throws rather than silently returning nothing`() {
        let renamed = Data("""
        {"code":"200","data":{"DataV2":{"data":{"code":"SUCCESS",
        "data":{"lite":{"fiveHour":700.0,"weekly":2500.0}},"success":true}},
        "success":true,"errorMsg":""},"successResponse":true}
        """.utf8)

        #expect(throws: AlibabaTokenPlanUsageError.self) {
            try AlibabaTokenPlanPersonalAPI.parseQuotaConfig(from: renamed)
        }
    }

    @Test
    func `parses credit ceilings for every tier`() throws {
        let config = try AlibabaTokenPlanPersonalAPI.parseQuotaConfig(from: Fixtures.quotaConfig)

        #expect(config["lite"]?.fiveHour == 700)
        #expect(config["lite"]?.weekly == 2500)
        #expect(config["pro"]?.fiveHour == 12000)
        #expect(config.count == 3)
    }

    /// Stale sessions must classify as `.loginRequired`, otherwise the descriptor never treats
    /// them as a credential failure and never clears/re-imports the cookie cache.
    @Test
    func `classifies stale sessions as login required`() {
        #expect(throws: AlibabaTokenPlanUsageError.loginRequired) {
            try AlibabaTokenPlanPersonalAPI.parseUsage(from: Fixtures.gatewayFailure)
        }
    }

    @Test
    func `classifies a login html body as login required`() {
        let html = Data("<!DOCTYPE html><html><body><form action=\"/login\">Sign in</form></body></html>".utf8)

        #expect(throws: AlibabaTokenPlanUsageError.loginRequired) {
            try AlibabaTokenPlanPersonalAPI.parseUsage(from: html)
        }
    }

    @Test
    func `reports genuine api errors with their message`() {
        let failure = Data("""
        {"code":"500","data":{"success":false,"errorCode":"InternalError","errorMsg":"Backend exploded."},
        "successResponse":false}
        """.utf8)

        #expect(throws: AlibabaTokenPlanUsageError.apiError("Backend exploded.")) {
            try AlibabaTokenPlanPersonalAPI.parseUsage(from: failure)
        }
    }

    @Test
    func `surfaces root level failures instead of masking them as parse errors`() {
        let rootFailure = Data("""
        {"code":"403","message":"Forbidden by policy.","successResponse":false,"data":null}
        """.utf8)

        #expect(throws: AlibabaTokenPlanUsageError.apiError("Forbidden by policy.")) {
            try AlibabaTokenPlanPersonalAPI.parseUsage(from: rootFailure)
        }
    }

    /// The REST-layer envelope is where a stale session most often surfaces.
    @Test
    func `classifies an inner envelope login failure as login required`() {
        let innerFailure = Data("""
        {"code":"200","data":{"DataV2":{"data":{"code":"NeedLogin","msg":"Session expired.",
        "success":false}},"success":true,"errorMsg":""},"successResponse":true}
        """.utf8)

        #expect(throws: AlibabaTokenPlanUsageError.loginRequired) {
            try AlibabaTokenPlanPersonalAPI.parseUsage(from: innerFailure)
        }
    }

    @Test
    func `reports an inner envelope api error with its message`() {
        let innerFailure = Data("""
        {"code":"200","data":{"DataV2":{"data":{"code":"Throttled","msg":"Too many requests.",
        "success":false}},"success":true,"errorMsg":""},"successResponse":true}
        """.utf8)

        #expect(throws: AlibabaTokenPlanUsageError.apiError("Too many requests.")) {
            try AlibabaTokenPlanPersonalAPI.parseUsage(from: innerFailure)
        }
    }

    /// A gateway can drop the envelope entirely and return a bare auth error with no success flag;
    /// that must still reach the cookie re-import path rather than degrading to a parse error.
    @Test
    func `classifies an envelope-less auth error as login required`() {
        let bare = Data("""
        {"code":"401","data":{"errorCode":"ConsoleNeedLogin","errorMsg":"Please log in."}}
        """.utf8)

        #expect(throws: AlibabaTokenPlanUsageError.loginRequired) {
            try AlibabaTokenPlanPersonalAPI.parseUsage(from: bare)
        }
    }

    @Test
    func `a genuinely malformed body is still a parse failure`() {
        let malformed = Data("""
        {"code":"200","data":{"unexpected":"shape"},"successResponse":true}
        """.utf8)

        #expect(throws: AlibabaTokenPlanUsageError.parseFailed("Missing DataV2 payload")) {
            try AlibabaTokenPlanPersonalAPI.parseUsage(from: malformed)
        }
    }

    @Test
    func `missing usage percentages are a parse failure`() {
        let empty = Data("""
        {"code":"200","data":{"DataV2":{"data":{"code":"SUCCESS","data":{},"success":true}},
        "success":true,"errorMsg":""},"successResponse":true}
        """.utf8)

        #expect(throws: AlibabaTokenPlanUsageError.self) {
            try AlibabaTokenPlanPersonalAPI.parseUsage(from: empty)
        }
    }

    @Test
    func `form body escapes plus so it is not decoded as a space`() throws {
        let body = AlibabaTokenPlanUsageFetcher.formEncodedBody([URLQueryItem(name: "sec_token", value: "ab+c")])
        let text = try #require(String(data: body, encoding: .utf8))

        #expect(text == "sec_token=ab%2Bc")
    }

    @Test
    func `builds the console gateway url per endpoint`() throws {
        let url = try #require(AlibabaTokenPlanPersonalAPI.requestURL(
            baseURLString: AlibabaTokenPlanAPIRegion.qwenCloudPersonal.quotaAPIBaseURLString,
            endpoint: .usage))

        #expect(url.host == "cs-data.qwencloud.com")
        #expect(url.path == "/data/api.json")
        let query = try #require(url.query)
        #expect(query.contains("product=sfm_bailian"))
        #expect(query.contains("action=IntlBroadScopeAspnGateway"))
        #expect(url.absoluteString.contains("tokenplan/personal/api/v2/usage"))
    }

    @Test
    func `request body carries sec token region and tunneled api path`() throws {
        let body = AlibabaTokenPlanPersonalAPI.requestBody(
            endpoint: .quotaConfig,
            region: .qwenCloudPersonal,
            secToken: "abc123")
        let text = try #require(String(data: body, encoding: .utf8))

        #expect(text.contains("sec_token=abc123"))
        #expect(text.contains("region=ap-southeast-1"))
        #expect(text.contains("QWENCLOUD"))
        #expect(text.contains("quota-config"))
    }

    @Test
    func `omits sec token when unavailable`() throws {
        let body = AlibabaTokenPlanPersonalAPI.requestBody(
            endpoint: .usage,
            region: .qwenCloudPersonal,
            secToken: nil)
        let text = try #require(String(data: body, encoding: .utf8))

        #expect(!text.contains("sec_token"))
    }
}

struct AlibabaTokenPlanPersonalSnapshotTests {
    @Test
    func `maps rolling windows to primary and secondary`() {
        let now = Date(timeIntervalSince1970: 1_784_461_000)
        let reset5h = Date(timeIntervalSince1970: 1_784_479_200)
        let resetWeek = Date(timeIntervalSince1970: 1_785_066_000)
        let snapshot = AlibabaTokenPlanUsageSnapshot(
            planName: "Token Plan Lite",
            quota: .rollingWindows(
                fiveHour: AlibabaTokenPlanRollingWindow(
                    usedPercent: 10,
                    totalCredits: 700,
                    resetsAt: reset5h),
                weekly: AlibabaTokenPlanRollingWindow(
                    usedPercent: 20,
                    totalCredits: 2500,
                    resetsAt: resetWeek)),
            updatedAt: now)

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 10)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt == reset5h)
        #expect(usage.primary?.resetDescription == "70 / 700 credits used")
        #expect(usage.secondary?.usedPercent == 20)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt == resetWeek)
        #expect(usage.secondary?.resetDescription == "500 / 2,500 credits used")
        #expect(usage.loginMethod(for: .alibabatokenplan) == "Token Plan Lite")
    }

    @Test
    func `omits credit detail when the tier ceiling is unknown`() {
        let snapshot = AlibabaTokenPlanUsageSnapshot(
            planName: "TOKEN PLAN",
            quota: .rollingWindows(
                fiveHour: AlibabaTokenPlanRollingWindow(usedPercent: 5, totalCredits: nil, resetsAt: nil),
                weekly: AlibabaTokenPlanRollingWindow(usedPercent: 7, totalCredits: nil, resetsAt: nil)),
            updatedAt: Date(timeIntervalSince1970: 1_784_461_000))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 5)
        #expect(usage.primary?.resetDescription == nil)
        #expect(usage.secondary?.usedPercent == 7)
    }

    @Test
    func `credit pool still renders a single monthly window`() {
        let reset = Date(timeIntervalSince1970: 1_700_100_000)
        let snapshot = AlibabaTokenPlanUsageSnapshot(
            planName: "TOKEN PLAN",
            quota: .creditPool(used: 250, total: 1000, remaining: nil, resetsAt: reset),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.primary?.windowMinutes == 43200)
        #expect(usage.secondary == nil)
    }
}

struct AlibabaTokenPlanCookieScopingTests {
    private static func cookie(name: String, domain: String, path: String = "/") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: "v-\(name)",
            .domain: domain,
            .path: path,
        ])!
    }

    /// Qwen's console and data gateway are sibling hosts, so a host-scoped console cookie must
    /// still reach the gateway request.
    @Test
    func `personal region unions console and gateway cookies`() throws {
        let cookies = [
            Self.cookie(name: "login_qwencloud_ticket", domain: "home.qwencloud.com"),
            Self.cookie(name: "cna", domain: ".qwencloud.com"),
        ]

        let headers = try #require(AlibabaTokenPlanCookieHeader.headers(
            from: cookies,
            region: .qwenCloudPersonal,
            environment: [:]))

        #expect(headers.apiCookieHeader.contains("login_qwencloud_ticket"))
        #expect(headers.apiCookieHeader.contains("cna"))
    }

    /// Regression guard: for intl/cn both hosts are identical, so the union must be a strict
    /// no-op and dashboard path-scoped cookies must not leak into the api header.
    @Test
    func `team regions keep api and dashboard cookies separately scoped`() throws {
        let cookies = [
            Self.cookie(name: "shared", domain: "bailian.console.aliyun.com"),
            Self.cookie(name: "dashboard_only", domain: "bailian.console.aliyun.com", path: "/cn-beijing"),
        ]

        let headers = try #require(AlibabaTokenPlanCookieHeader.headers(
            from: cookies,
            region: .chinaMainland,
            environment: [:]))

        #expect(headers.apiCookieHeader.contains("shared"))
        #expect(!headers.apiCookieHeader.contains("dashboard_only"))
        #expect(headers.dashboardCookieHeader.contains("dashboard_only"))
    }
}

struct AlibabaTokenPlanLinuxGatingTests {
    @Test
    func `manual cookies let the token plan run without macOS web support`() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .alibabatokenplan,
            settings: ProviderSettingsSnapshot.make(
                alibabaTokenPlan: .init(
                    cookieSource: .manual,
                    manualCookieHeader: "login_qwencloud_ticket=test",
                    apiRegion: .qwenCloudPersonal))))
    }

    @Test
    func `browser cookie import still requires macOS web support`() {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .alibabatokenplan,
            environment: [:],
            settings: ProviderSettingsSnapshot.make(
                alibabaTokenPlan: .init(cookieSource: .auto, manualCookieHeader: nil))))
    }

    /// `ALIBABA_TOKEN_PLAN_COOKIE` is honored even when the configured source is `auto`, so it has
    /// to open the gate by itself — otherwise that documented setup stays unusable on Linux.
    @Test
    func `an environment cookie alone opens the gate`() {
        #expect(!CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .alibabatokenplan,
            environment: [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "login_qwencloud_ticket=test"],
            settings: ProviderSettingsSnapshot.make(
                alibabaTokenPlan: .init(cookieSource: .auto, manualCookieHeader: nil))))
    }

    @Test
    func `an empty environment cookie does not open the gate`() {
        #expect(CodexBarCLI.sourceModeRequiresWebSupport(
            .web,
            provider: .alibabatokenplan,
            environment: [AlibabaTokenPlanSettingsReader.cookieHeaderKey: "   "],
            settings: ProviderSettingsSnapshot.make(
                alibabaTokenPlan: .init(cookieSource: .auto, manualCookieHeader: nil))))
    }

    @Test
    func `personal region targets the qwen cloud console`() {
        let region = AlibabaTokenPlanAPIRegion.qwenCloudPersonal
        #expect(region.rawValue == "qwen")
        #expect(region.gatewayBaseURLString == "https://home.qwencloud.com")
        #expect(region.quotaAPIBaseURLString == "https://cs-data.qwencloud.com")
        #expect(region.currentRegionID == "ap-southeast-1")
        #expect(region.tokenPlanProductCode == nil)
        #expect(region.usesPersonalTokenPlanAPI)
    }

    @Test
    func `personal region is manual-cookie only`() {
        #expect(!AlibabaTokenPlanAPIRegion.qwenCloudPersonal.supportsBrowserCookieImport)
        #expect(AlibabaTokenPlanAPIRegion.international.supportsBrowserCookieImport)
        #expect(AlibabaTokenPlanAPIRegion.chinaMainland.supportsBrowserCookieImport)
    }

    @Test
    func `personal gateway url honours a host override`() {
        let overridden = AlibabaTokenPlanUsageFetcher.resolveQuotaURL(
            region: .qwenCloudPersonal,
            environment: [AlibabaTokenPlanSettingsReader.hostKey: "cs-data.qwencloud.com"])
        #expect(overridden.host == "cs-data.qwencloud.com")

        let defaulted = AlibabaTokenPlanUsageFetcher.resolveQuotaURL(
            region: .qwenCloudPersonal,
            environment: [:])
        #expect(defaulted.host == "cs-data.qwencloud.com")
        #expect(defaulted.absoluteString.contains("tokenplan/personal/api/v2/usage"))
    }

    @Test
    func `team regions keep their commodity codes and console hosts`() {
        #expect(AlibabaTokenPlanAPIRegion.international.tokenPlanProductCode == "sfm_tokenplanteams_dp_intl")
        #expect(AlibabaTokenPlanAPIRegion.chinaMainland.tokenPlanProductCode == "sfm_tokenplanteams_dp_cn")
        #expect(!AlibabaTokenPlanAPIRegion.international.usesPersonalTokenPlanAPI)
        #expect(
            AlibabaTokenPlanAPIRegion.international.quotaAPIBaseURLString ==
                "https://modelstudio.console.alibabacloud.com")
    }
}
