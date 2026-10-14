import Foundation
import Testing
@testable import CodexBarCore

struct LangdockPluginTests {
    static let profile = ProviderBrowserProfile(browserID: "edge", profileID: "/synthetic/Edge/Profile 2")
    static let profiles = [
        Self.profile,
        ProviderBrowserProfile(browserID: "chrome", profileID: "/synthetic/Chrome/Profile 2"),
        ProviderBrowserProfile(browserID: "safari", profileID: "/synthetic/Safari/Personal/Cookies.binarycookies"),
    ]
    static let plan = """
    {"sessionUsageLimitsEnabled":true,"sessionUsagePercent":12.5,
     "sessionResetsAt":"2026-09-25T12:00:00.123Z","weeklyUsagePercent":104.2,
     "weeklyResetsAt":"2026-09-28T12:00:00Z"}
    """

    static func body(_ plan: String) -> String {
        "[{\"result\":{\"data\":{\"json\":{\"hasIncludedUsageLimits\":true,\"planUsage\":\(plan)}}}}]"
    }

    static func record(
        _ value: String = "synthetic-account-a",
        name: String = "auth_token",
        domain: String = "app.langdock.com",
        path: String = "/") throws -> ProviderPluginCookieRecord
    {
        try ProviderPluginCookieRecord(cookie: #require(HTTPCookie(properties: [
            .domain: domain, .path: path, .name: name, .value: value, .secure: "TRUE",
        ])))
    }

    static func broker(
        _ runtime: ProviderPluginRuntime,
        profile: ProviderBrowserProfile = Self.profile,
        reader: @escaping ProviderPluginSelectedProfile.Reader = { _ in try [Self.record()] })
        -> ProviderPluginCookieBroker
    {
        var settings = CookieProviderSettings()
        settings.selectedBrowserProfile = profile
        return ProviderPluginCookieBroker(
            provider: .langdock,
            domains: runtime.manifest.cookieDomains,
            settings: settings,
            batches: { _, _ in Issue.record("Must not import another profile or cached header"); return nil },
            jarImporter: { _ in Issue.record("Must not enumerate other profiles"); return nil },
            policy: runtime.manifest.cookiePolicy,
            profileReader: reader)
    }

    static func fetch(
        _ body: String,
        code: Int = 200,
        now: Date = Date(),
        profile: ProviderBrowserProfile = Self.profile,
        engine: ProviderPluginEngineKind = .automatic)
        async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "langdock",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                let url = try #require(request.url)
                #expect(url.host == "app.langdock.com")
                #expect(url.path == "/api/trpc/usageSettings.getPersonalUsage")
                #expect(request.value(forHTTPHeaderField: "Cookie") == "auth_token=synthetic-account-a")
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                #expect(query?.first { $0.name == "batch" }?.value == "1")
                #expect(query?.first { $0.name == "input" }?
                    .value == #"{"0":{"json":null,"meta":{"values":["undefined"],"v":1}}}"#)
                return try (
                    Data(body.utf8),
                    #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)))
            })
        return try await runtime.fetchResult(cookies: Self.broker(runtime, profile: profile), now: now).usage
    }

    @Test(arguments: BundledPluginTestSupport.engines, Self.profiles)
    func `session weekly overage and reset dates match the contributor fixture`(
        engine: ProviderPluginEngineKind, profile: ProviderBrowserProfile) async throws
    {
        let usage = try await Self.fetch(Self.body(Self.plan), profile: profile, engine: engine)
        #expect(usage.primary?.usedPercent == 12.5)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.primary?.resetsAt != nil)
        #expect(usage.secondary?.usedPercent == 104.2)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.secondary?.resetsAt != nil)
        #expect(usage.dataConfidence == .percentOnly)
        #expect(usage.browserSessionOwner?.profile == profile)
        #expect(usage.identity?.accountID == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `weekly only and zero remain distinct from missing included limits`(
        engine: ProviderPluginEngineKind) async throws
    {
        let weekly = try await Self.fetch(
            Self.body(#"{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":0}"#),
            engine: engine)
        #expect(weekly.primary == nil)
        #expect(weekly.secondary?.usedPercent == 0)
        #expect(weekly.secondary?.resetsAt == nil)
        for payload in [Self.body("null"), #"[{"result":{"data":{"json":{"hasIncludedUsageLimits":false}}}}]"#] {
            let missing = try await Self.fetch(payload, engine: engine)
            #expect(missing.primary == nil)
            #expect(missing.secondary == nil)
            #expect(missing.details.first?.rows.first?.value == "No included usage limits available")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, [
        "[]", "[{},{}]", #"[{"result":{"data":null}}]"#, #"[{"error":{}}]"#,
        #"[{"error":{"json":{"data":{"code":403}}}}]"#,
        body(#"{"sessionUsageLimitsEnabled":true,"weeklyUsagePercent":4}"#),
        body(#"{"sessionUsageLimitsEnabled":true,"sessionUsagePercent":"5","weeklyUsagePercent":4}"#),
        body(#"{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":"4"}"#),
        body(#"{"sessionUsageLimitsEnabled":false,"weeklyUsagePercent":4,"weeklyResetsAt":"tomorrow"}"#),
    ])
    func `malformed envelopes percentages and dates fail instead of fabricating zero`(
        engine: ProviderPluginEngineKind, body: String) async throws
    {
        let error = try #require(await #expect(throws: ProviderBrowserSessionFailure.self) {
            try await Self.fetch(body, engine: engine)
        })
        #expect((error.underlyingError as? ProviderFetchClassifiedError)?.kind == .parseFailure)
    }

    @Test(arguments: BundledPluginTestSupport.engines, [401, 403, 429, 503, 400])
    func `HTTP and trpc failures keep the same error taxonomy`(
        engine: ProviderPluginEngineKind,
        status: Int) async throws
    {
        let cases: [Int: (String, ProviderFetchClassifiedError.Kind)] = [
            401: ("UNAUTHORIZED", .authenticationExpired), 403: ("FORBIDDEN", .permissionDenied),
            429: ("TOO_MANY_REQUESTS", .rateLimited), 503: ("INTERNAL_SERVER_ERROR", .providerUnavailable),
            400: ("BAD_REQUEST", .apiFailure),
        ]
        let (code, expected) = try #require(cases[status])
        for (body, http) in [("{}", status), ("[{\"error\":{\"json\":{\"data\":{\"code\":\"\(code)\"}}}}]", 200)] {
            let error = try #require(await #expect(throws: ProviderBrowserSessionFailure.self) {
                try await Self.fetch(body, code: http, engine: engine)
            })
            #expect((error.underlyingError as? ProviderFetchClassifiedError)?.kind == expected)
        }
    }
}
