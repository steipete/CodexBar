import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct MusePluginTests {
    static let account = #"""
    {
      "api_key":"LLM|fixture-inference-key", "payment_method":"Visa-0000",
      "require_payment":false, "is_subs_active":true, "user_email":"ada@example.com",
      "subs_tier_name":"Muse Code Power Usage",
      "subs_usage":{
        "window":{"used_percent":96,"window_duration_mins":300,"resets_at":1788599502},
        "weekly":{"used_percent":40,"resets_at":1788739200}
      }
    }
    """#

    static let activeWithoutWindows = #"""
    {"is_subs_active":true,"user_email":"ada@example.com","subs_tier_name":"Muse Code Power Usage"}
    """#

    static let activeWithNullWindows = #"""
    {
      "is_subs_active":true, "user_email":"ada@example.com",
      "subs_tier_name":"Muse Code Power Usage", "subs_usage":null
    }
    """#

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reported subscription windows retain their identity and resets`(
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(Self.account, engine: engine)
        #expect(snapshot.primary?.usedPercent == 96)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: 1_788_599_502))
        #expect(snapshot.secondary?.usedPercent == 40)
        #expect(snapshot.secondary?.windowMinutes == 10080)
        #expect(snapshot.secondary?.resetsAt == Date(timeIntervalSince1970: 1_788_739_200))
        #expect(snapshot.identity?.providerID == .muse)
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        #expect(snapshot.dataConfidence == .exact)
        #expect(snapshot.providerCost == nil)
        #expect(!snapshot.details.flatMap(\.rows).contains { $0.value.contains("Visa") || $0.value.contains("LLM|") })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `JSON request sends only the device credential and fixed API version`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                #expect(request.url?.absoluteString == "https://api.meta.ai/muse-code/key")
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dca:fixture-token")
                #expect(request.value(forHTTPHeaderField: "x-api-version") == "1.0.0")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                #expect(request.timeoutInterval == 15)
                #expect(request.httpBody == Data("{}".utf8))
                return try Self.response(request, body: Self.account)
            })
        _ = try await runtime.fetchUsage(secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `inference keys never reach the mint endpoint`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                Issue.record("Inference credential reached the transport")
                return try Self.response(request, body: Self.account)
            })
        await Self.expectFailure(.authenticationExpired) {
            try await runtime.fetchUsage(secrets: ["MUSE_DEVICE_TOKEN": "LLM|fixture-token"])
        }
    }

    @Test(arguments: ["{}", "<html>Sign in</html>", ""], BundledPluginTestSupport.engines)
    func `unauthorized text responses retain login recovery`(body: String, engine: ProviderPluginEngineKind) async {
        await Self.expectFailure(.authenticationExpired) {
            try await Self.fetch(body, engine: engine, status: 401)
        }
    }

    @Test(arguments: [
        #"{"require_payment":true,"is_subs_active":false}"#,
        #"{"is_subs_active":false,"subs_usage":null}"#,
    ], BundledPluginTestSupport.engines)
    func `inactive subscriptions and missing billing never invent quotas`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.permissionDenied) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: [Self.activeWithoutWindows, Self.activeWithNullWindows], BundledPluginTestSupport.engines)
    func `active login without quota windows keeps plan identity`(
        body: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary == nil)
        #expect(snapshot.dataConfidence == .unknown)
        #expect(snapshot.identity?.accountEmail == "ada@example.com")
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        let rows = snapshot.details.flatMap(\.rows)
        #expect(rows.contains { $0.label == "Plan" && $0.value == "Muse Code Power Usage" })
        #expect(rows.contains { $0.label == "Quota" && $0.value.contains("login response") })
        #expect(!rows.contains { $0.label == "5 hours" || $0.label == "Weekly" })
    }

    @Test(arguments: [#"{"is_subs_active":true,"subs_usage":"window"}"#], BundledPluginTestSupport.engines)
    func `non-object quota payload remains a parse failure`(
        body: String,
        engine: ProviderPluginEngineKind) async
    {
        await Self.expectFailure(.parseFailure) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: ["1e30", "0", "-1", "true", "\"300\""], BundledPluginTestSupport.engines)
    func `invalid durations fail without trapping`(value: String, engine: ProviderPluginEngineKind) async {
        let body = Self.account.replacingOccurrences(
            of: "\"window_duration_mins\":300",
            with: "\"window_duration_mins\":\(value)")
        await Self.expectFailure(.parseFailure) { try await Self.fetch(body, engine: engine) }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unrepresentable resets preserve reported usage`(engine: ProviderPluginEngineKind) async throws {
        let body = Self.account.replacingOccurrences(of: "1788599502", with: "1e30")
        let snapshot = try await Self.fetch(body, engine: engine)
        #expect(snapshot.primary?.usedPercent == 96)
        #expect(snapshot.primary?.resetsAt == nil)
        #expect(snapshot.secondary?.resetsAt != nil)
    }

    static let teamID = "424242424242"
    static let teams = #"{"teams":[{"team_id":424242424242,"team_name":"My Team"}]}"#
    static let me = #"{"userId":"1","email":"Ada@Example.com","accountType":"META_ACCOUNT"}"#
    /// The fixture clock; reset times are relative to it.
    static let now = 1_790_341_873

    /// A dev.meta.ai team quota. The login fixture reports "Muse Code Power Usage".
    static func quota(
        tier: String = "Muse Code Power Usage",
        windowUsed: String = "0",
        windowResetsAt: Int? = nil,
        weeklyUsed: String = "9043782620",
        weeklyResetsAt: Int = 1_790_553_600) -> String
    {
        let window = windowResetsAt.map { #","window_resets_at":\#($0)"# } ?? ""
        return #"{"subscription_quota":{"tier_id":"1","tier":"\#(tier)","as_of":\#(Self.now),"#
            + #""window_weighted_limit":"20000000000","window_duration_secs":18000,"#
            + #""weekly_weighted_limit":"60000000000","weekly_resets_at":\#(weeklyResetsAt),"#
            + #""window_weighted_used":"\#(windowUsed)","weekly_weighted_used":"\#(weeklyUsed)"\#(window)}}"#
    }

    static func web(quota: String) -> @Sendable (String) -> (String, Int) {
        { path in
            switch path {
            case "/api/auth/me": (Self.me, 200)
            case "/api/portal/teams": (Self.teams, 200)
            case "/api/portal/teams/\(Self.teamID)/subscription-quota": (quota, 200)
            default: ("{}", 404)
            }
        }
    }

    /// dev.meta.ai sessions can report a blank email; the session user's team membership then carries it.
    static let blankEmailMe = #"{"userId":"1001","displayName":"1001","email":""}"#

    static func members(userID: String = "1001", email: String = "Ada@Example.com") -> String {
        #"{"members":[{"member_id":"9","user_id":"\#(userID)","name":"Ada","email":"\#(email)","role":"owner"}]}"#
    }

    static func blankEmailWeb(members: (String, Int)) -> @Sendable (String) -> (String, Int) {
        { path in
            switch path {
            case "/api/auth/me": (Self.blankEmailMe, 200)
            case "/api/portal/teams/\(Self.teamID)/members": members
            default: Self.web(quota: Self.quota())(path)
            }
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a blank session email is resolved from the session user's team membership`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(
            engine: engine,
            requests: requests,
            web: Self.blankEmailWeb(members: (Self.members(), 200)))
        #expect(result.sourceLabel == "oauth+web")
        #expect(result.usage.secondary != nil)
        #expect(requests.all.filter { $0.url?.host == "dev.meta.ai" }.map { $0.url?.path ?? "" } == [
            "/api/auth/me",
            "/api/portal/teams",
            "/api/portal/teams/\(Self.teamID)/members",
            "/api/portal/teams/\(Self.teamID)/subscription-quota",
        ])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a blank session email lists teams for selection once membership matches the login`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(
            engine: engine,
            teamID: nil,
            requests: requests,
            web: Self.blankEmailWeb(members: (Self.members(), 200)))
        let teams = try #require(result.usage.details.first { $0.title == "Browser teams" })
        #expect(teams.rows.contains { $0.label == "My Team" && $0.value == Self.teamID })
        #expect(!requests.all.contains { $0.url?.path.hasSuffix("/subscription-quota") == true })
    }

    @Test(arguments: [
        (Self.members(email: "bob@example.com"), 200),
        // The login's email belongs to another member, not to the session user.
        (
            #"{"members":[{"user_id":"2002","email":"ada@example.com"},"#
                + #"{"user_id":"1001","email":"bob@example.com"}]}"#,
            200),
        (Self.members(userID: "2002"), 200),
        (#"{"error":"Forbidden"}"#, 403),
    ], BundledPluginTestSupport.engines)
    func `a blank session email without the login's membership supplies no teams or quota`(
        members: (body: String, status: Int),
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let rejected = RequestLog()
        let result = try await Self.fetchWithWeb(
            engine: engine,
            requests: requests,
            rejected: rejected,
            web: Self.blankEmailWeb(members: members))
        #expect(result.usage.secondary == nil)
        #expect(!result.usage.details.contains { $0.title == "Browser teams" })
        #expect(!requests.all.contains { $0.url?.path.hasSuffix("/subscription-quota") == true })
        // A forbidden member list is a role limit, not an expired session.
        #expect(rejected.domains.isEmpty)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a blank session email without the login's membership lists no teams when none is selected`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(
            engine: engine,
            teamID: nil,
            requests: requests,
            web: Self.blankEmailWeb(members: (Self.members(email: "bob@example.com"), 200)))
        #expect(!result.usage.details.contains { $0.title == "Browser teams" })
        #expect(requests.all.contains { $0.url?.path == "/api/portal/teams/\(Self.teamID)/members" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a blank session email binds through the first team when the selected team is not visible`(
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(
            engine: engine,
            teamID: "999",
            requests: requests,
            web: Self.blankEmailWeb(members: (Self.members(), 200)))
        let teams = try #require(result.usage.details.first { $0.title == "Browser teams" })
        #expect(teams.rows.contains {
            $0.label == "Status" && $0.value == "The selected browser team is not visible to this session"
        })
        #expect(teams.rows.contains { $0.label == "My Team" && $0.value == Self.teamID })
        #expect(result.usage.secondary == nil)
        #expect(!requests.all.contains { $0.url?.path.hasSuffix("/subscription-quota") == true })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `an unbound session without a team list does not end the search for a matching session`(
        engine: ProviderPluginEngineKind) async throws
    {
        let blankWeb = Self.blankEmailWeb(members: (Self.members(), 200))
        let (result, _) = try await Self.fetchWithSessions(
            engine: engine,
            teamID: nil,
            first: { path in path == "/api/auth/me" ? (Self.blankEmailMe, 200) : ("{}", 200) },
            second: blankWeb)
        let teams = try #require(result.usage.details.first { $0.title == "Browser teams" })
        #expect(teams.rows.contains { $0.label == "My Team" && $0.value == Self.teamID })
    }

    @Test(arguments: [
        (Self.members(), 403),
        (Self.members(email: "bob@example.com"), 200),
    ], BundledPluginTestSupport.engines)
    func `a session matched by email is tried before a blank email session spends its membership check`(
        members: (body: String, status: Int),
        engine: ProviderPluginEngineKind) async throws
    {
        let (result, requests) = try await Self.fetchWithSessions(
            engine: engine,
            teamID: Self.teamID,
            first: Self.blankEmailWeb(members: members),
            second: Self.web(quota: Self.quota()))
        #expect(result.sourceLabel == "oauth+web")
        #expect(result.usage.secondary != nil)
        #expect(requests.value.filter { $0.session == "first" }.map(\.path) == ["/api/auth/me"])
    }

    /// Two Automatic browser sessions, "first" then "second", each answering dev.meta.ai paths on its own.
    static func fetchWithSessions(
        engine: ProviderPluginEngineKind,
        teamID: String?,
        first: @escaping @Sendable (String) -> (String, Int),
        second: @escaping @Sendable (String) -> (String, Int)) async throws
        -> (ProviderPluginResult, LockIsolated<[(session: String, path: String)]>)
    {
        let next = LockIsolated(0)
        let requests = LockIsolated<[(session: String, path: String)]>([])
        let runtime = try BundledPluginTestSupport.runtime(
            "muse", engine: engine, transport: ProviderHTTPTransportHandler { request in
                guard request.url?.host == "dev.meta.ai" else {
                    return try Self.response(request, body: Self.activeWithoutWindows)
                }
                let path = request.url?.path ?? ""
                let session = request.value(forHTTPHeaderField: "Cookie") == "session=first" ? "first" : "second"
                requests.setValue(requests.value + [(session, path)])
                let (body, code) = (session == "first" ? first : second)(path)
                return try Self.response(request, body: body, status: code)
            })
        let result = try await runtime.fetchResult(
            settings: teamID.map { ["MUSE_WEB_TEAM_ID": $0] } ?? [:],
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            now: Date(timeIntervalSince1970: TimeInterval(Self.now)),
            cookieSource: .auto,
            cookieSessionResolver: { _, _ in
                let index = next.value
                next.setValue(index + 1)
                guard index < 2 else { return nil }
                let name = index == 0 ? "first" : "second"
                return ProviderPluginCookieSession(
                    header: "session=\(name)", source: "fixture", origin: "https://dev.meta.ai", id: name)
            },
            cookieSessionInvalidator: { _, _ in },
            cookieResolver: { _, _ in "session=first" })
        return (result, requests)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `selected team quota fills omitted login quotas`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let quota = Self.quota(windowUsed: "4000000000", windowResetsAt: Self.now + 3600)
        let result = try await Self.fetchWithWeb(engine: engine, requests: requests, web: Self.web(quota: quota))
        let snapshot = result.usage
        #expect(result.sourceLabel == "oauth+web")
        #expect(snapshot.primary?.usedPercent == 20)
        #expect(snapshot.primary?.windowMinutes == 300)
        #expect(snapshot.primary?.resetsAt == Date(timeIntervalSince1970: TimeInterval(Self.now + 3600)))
        let weekly = try #require(snapshot.secondary)
        #expect(abs(weekly.usedPercent - 15.07297103) < 0.0001)
        #expect(weekly.windowMinutes == 10080)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_790_553_600))
        // The team is user-selected, so the reading is not reported as the CLI login's own exact usage.
        #expect(snapshot.dataConfidence == .estimated)
        #expect(snapshot.identity?.loginMethod == "Muse Code Power Usage")
        let browser = try #require(snapshot.details.first { $0.title == "Browser team quota (dev.meta.ai)" })
        #expect(browser.rows.contains { $0.label == "Team" && $0.value == "My Team" })
        #expect(browser.rows.contains { $0.label == "Weekly" && $0.value == "15%" })
        let login = try #require(snapshot.details.first { $0.title == "Muse Code subscription" })
        #expect(!login.rows.contains { $0.label == "Quota" })
        let web = requests.all.filter { $0.url?.host == "dev.meta.ai" }
        #expect(web.map { $0.url?.path ?? "" } == [
            "/api/auth/me",
            "/api/portal/teams",
            "/api/portal/teams/\(Self.teamID)/subscription-quota",
        ])
        #expect(web.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == "llama_dev_sess=fixture"
                && $0.value(forHTTPHeaderField: "Authorization") == nil
        })
    }

    @Test(arguments: [
        (Self.quota(), "idle"),
        (Self.quota(windowUsed: "4000000000", windowResetsAt: Self.now - 60), "expired"),
    ], BundledPluginTestSupport.engines)
    func `idle and expired five hour windows carry no usage or reset`(
        fixture: (quota: String, name: String),
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetchWithWeb(engine: engine, web: Self.web(quota: fixture.quota))
        #expect(result.sourceLabel == "oauth+web")
        #expect(result.usage.primary?.usedPercent == 0)
        #expect(result.usage.primary?.resetsAt == nil)
        #expect(result.usage.secondary != nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a weekly quota past its reset withholds the whole browser reading`(
        engine: ProviderPluginEngineKind) async throws
    {
        let quota = Self.quota(windowUsed: "4000000000", windowResetsAt: Self.now + 3600, weeklyResetsAt: Self.now - 60)
        let result = try await Self.fetchWithWeb(engine: engine, web: Self.web(quota: quota))
        #expect(result.sourceLabel == nil)
        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
    }

    @Test(arguments: ["\"invalid\"", "1e30", "-1", "true", "null"], BundledPluginTestSupport.engines)
    func `invalid five hour resets never invent an idle window`(
        reset: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let quota = Self.quota(windowUsed: "4000000000", windowResetsAt: Self.now + 3600)
            .replacingOccurrences(of: "\"window_resets_at\":\(Self.now + 3600)", with: "\"window_resets_at\":\(reset)")
        let result = try await Self.fetchWithWeb(engine: engine, web: Self.web(quota: quota))
        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.dataConfidence == .unknown)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `selected quota retains the team list for settings`(engine: ProviderPluginEngineKind) async throws {
        let result = try await Self.fetchWithWeb(engine: engine, web: Self.web(quota: Self.quota()))
        let teams = try #require(result.usage.details.first { $0.title == "Browser teams" })
        #expect(teams.rows.contains { $0.label == "My Team" && $0.value == Self.teamID })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a session without teams reads no quota`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(engine: engine, requests: requests) { path in
            switch path {
            case "/api/auth/me": (Self.me, 200)
            case "/api/portal/teams": (#"{"teams":[]}"#, 200)
            default: (Self.quota(), 200)
            }
        }
        #expect(result.usage.secondary == nil)
        #expect(!requests.all.contains { $0.url?.path.hasSuffix("/subscription-quota") == true })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `reported login quotas never read the browser session`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(
            engine: engine,
            account: Self.account,
            requests: requests,
            web: Self.web(quota: Self.quota()))
        #expect(result.sourceLabel == nil)
        #expect(result.usage.primary?.usedPercent == 96)
        #expect(!requests.all.contains { $0.url?.host == "dev.meta.ai" })
    }

    @Test(arguments: [String?.none, "  "], BundledPluginTestSupport.engines)
    func `without a selected team the visible teams are listed and no quota is read`(
        teamID: String?,
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(
            engine: engine,
            teamID: teamID,
            requests: requests,
            web: Self.web(quota: Self.quota()))
        #expect(result.sourceLabel == nil)
        #expect(result.usage.secondary == nil)
        #expect(!requests.all.contains { $0.url?.path.hasSuffix("/subscription-quota") == true })
        let teams = try #require(result.usage.details.first { $0.title == "Browser teams" })
        #expect(teams.rows.contains { $0.label == "My Team" && $0.value == Self.teamID })
        #expect(teams.rows.contains { $0.label == "Status" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a team the session cannot see is never queried`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(
            engine: engine,
            teamID: "123",
            requests: requests,
            web: { path in
                path == "/api/portal/teams/123/subscription-quota"
                    ? (Self.quota(), 200)
                    : Self.web(quota: Self.quota())(path)
            })
        #expect(result.usage.secondary == nil)
        #expect(!requests.all.contains { $0.url?.path.hasSuffix("/subscription-quota") == true })
        let teams = try #require(result.usage.details.first { $0.title == "Browser teams" })
        #expect(teams.rows.contains { $0.label == "My Team" })
    }

    @Test(arguments: [
        #"{"teams":[{"team_id":"11","team_name":"Alpha"},{"team_id":"22","team_name":"Beta"}]}"#,
        #"{"teams":[{"team_id":"22","team_name":"Beta"},{"team_id":"11","team_name":"Alpha"}]}"#,
    ], BundledPluginTestSupport.engines)
    func `the selected team decides the quota regardless of list order`(
        teams: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let result = try await Self.fetchWithWeb(engine: engine, teamID: "22") { path in
            switch path {
            case "/api/auth/me": (Self.me, 200)
            case "/api/portal/teams": (teams, 200)
            case "/api/portal/teams/11/subscription-quota": (Self.quota(weeklyUsed: "6000000000"), 200)
            case "/api/portal/teams/22/subscription-quota": (Self.quota(weeklyUsed: "48000000000"), 200)
            default: ("{}", 404)
            }
        }
        #expect(result.usage.secondary?.usedPercent == 80)
        let browser = try #require(result.usage.details.first { $0.title == "Browser team quota (dev.meta.ai)" })
        #expect(browser.rows.contains { $0.label == "Team" && $0.value == "Beta" })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a team quota for a different plan is not shown`(engine: ProviderPluginEngineKind) async throws {
        let quota = Self.quota(tier: "Muse Code Everyday Usage")
        let result = try await Self.fetchWithWeb(engine: engine, web: Self.web(quota: quota))
        #expect(result.sourceLabel == nil)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.identity?.loginMethod == "Muse Code Power Usage")
    }

    @Test(arguments: [
        (#"{"error":"Not authenticated"}"#, 401),
        (#"{"subscription_quota":null}"#, 200),
        (
            Self.quota().replacingOccurrences(
                of: #""window_weighted_limit":"20000000000""#,
                with: #""window_weighted_limit":"0""#),
            200),
        ("<html>", 200),
        (Self.quota().replacingOccurrences(of: "18000", with: "1e30"), 200),
    ], BundledPluginTestSupport.engines)
    func `unusable web quotas keep the login response result`(
        quota: (body: String, status: Int),
        engine: ProviderPluginEngineKind) async throws
    {
        let rejected = RequestLog()
        let result = try await Self.fetchWithWeb(engine: engine, rejected: rejected) { path in
            switch path {
            case "/api/auth/me": (Self.me, 200)
            case "/api/portal/teams": (Self.teams, 200)
            default: quota
            }
        }
        #expect(result.sourceLabel == nil)
        #expect(result.usage.primary == nil)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.identity?.loginMethod == "Muse Code Power Usage")
        #expect(result.usage.details.flatMap(\.rows).contains { $0.label == "Quota" })
        #expect(rejected.domains == (quota.status == 401 ? ["dev.meta.ai"] : []))
    }

    @Test(arguments: [#"{"email":"bob@example.com"}"#, #"{"email":""}"#], BundledPluginTestSupport.engines)
    func `a browser session for another account never supplies quotas`(
        me: String,
        engine: ProviderPluginEngineKind) async throws
    {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(engine: engine, requests: requests) { path in
            switch path {
            case "/api/auth/me": (me, 200)
            case "/api/portal/teams": (Self.teams, 200)
            default: (Self.quota(), 200)
            }
        }
        #expect(result.usage.secondary == nil)
        #expect(result.usage.identity?.accountEmail == "ada@example.com")
        #expect(!requests.all.contains { $0.url?.path.hasPrefix("/api/portal") == true })
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `disabled browser cookies never contact dev meta ai`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let result = try await Self.fetchWithWeb(
            engine: engine,
            cookieSource: .off,
            requests: requests,
            web: Self.web(quota: Self.quota()))
        #expect(result.usage.secondary == nil)
        #expect(!requests.all.contains { $0.url?.host == "dev.meta.ai" })
    }

    @Test(arguments: [200, 401, 403], BundledPluginTestSupport.engines)
    func `wrong account and rejected sessions advance to the matching account`(
        firstStatus: Int,
        engine: ProviderPluginEngineKind) async throws
    {
        let next = LockIsolated(0)
        let rejected = LockIsolated<[String]>([])
        let runtime = try BundledPluginTestSupport.runtime(
            "muse", engine: engine, transport: ProviderHTTPTransportHandler { request in
                guard request.url?.host == "dev.meta.ai" else {
                    return try Self.response(request, body: Self.activeWithoutWindows)
                }
                if request.value(forHTTPHeaderField: "Cookie") == "session=first" {
                    #expect(request.url?.path == "/api/auth/me")
                    return try Self.response(request, body: #"{"email":"other@example.com"}"#, status: firstStatus)
                }
                let (body, code) = Self.web(quota: Self.quota())(request.url?.path ?? "")
                return try Self.response(request, body: body, status: code)
            })
        let result = try await runtime.fetchResult(
            settings: ["MUSE_WEB_TEAM_ID": Self.teamID],
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            now: Date(timeIntervalSince1970: TimeInterval(Self.now)),
            cookieSource: .auto,
            cookieSessionResolver: { domain, _ in
                #expect(domain == "dev.meta.ai")
                let index = next.value
                next.setValue(index + 1)
                guard index < 2 else { return nil }
                let name = index == 0 ? "first" : "matching"
                return ProviderPluginCookieSession(
                    header: "session=\(name)", source: "fixture", origin: "https://dev.meta.ai", id: name)
            },
            cookieSessionInvalidator: { _, id in rejected.setValue(rejected.value + [id]) },
            cookieResolver: { _, _ in "session=first" })
        #expect(result.sourceLabel == "oauth+web")
        #expect(result.usage.secondary != nil)
        #expect(rejected.value == (firstStatus == 200 ? [] : ["first"]))
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `browser session retries stay within the request budget`(engine: ProviderPluginEngineKind) async throws {
        let requests = RequestLog()
        let runtime = try BundledPluginTestSupport.runtime(
            "muse", engine: engine, transport: ProviderHTTPTransportHandler { request in
                requests.append(request)
                return try Self.response(
                    request,
                    body: request.url?.host == "dev.meta.ai"
                        ? #"{"email":"other@example.com"}"# : Self.activeWithoutWindows)
            })
        let result = try await runtime.fetchResult(
            settings: ["MUSE_WEB_TEAM_ID": Self.teamID],
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            cookieSource: .auto,
            cookieSessionResolver: { _, _ in
                ProviderPluginCookieSession(header: "session=fixture", source: "fixture", origin: "https://dev.meta.ai")
            })
        #expect(requests.all.filter { $0.url?.host == "dev.meta.ai" }.count == 5)
        #expect(result.usage.secondary == nil)
        #expect(result.usage.dataConfidence == .unknown)
    }

    @Test(arguments: [
        (ProviderConfig?.none, String?.none),
        (ProviderConfig(id: .muse, cookieSource: .auto), nil),
        (ProviderConfig(id: .muse, cookieSource: .auto, workspaceID: " 22 "), "22"),
    ])
    func `the browser team comes only from the configured team ID`(
        config: ProviderConfig?,
        expected: String?) throws
    {
        let contribution = try #require(MuseProviderDescriptor.descriptor.settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(config: config, account: nil)))
        let settings = ProviderSettingsSnapshot(contributions: [contribution])
        #expect(settings[MuseProviderSettingsKey.self]?.webTeamID == expected)
    }

    @Test(arguments: [
        (ProviderConfig?.none, ProviderCookieSource.off),
        (ProviderConfig(id: .muse), .off),
        (ProviderConfig(id: .muse, cookieHeader: "llama_dev_sess=fixture"), .manual),
        (ProviderConfig(id: .muse, cookieSource: .auto), .auto),
    ])
    func `browser session access stays off until configured`(
        config: ProviderConfig?,
        expected: ProviderCookieSource) throws
    {
        let contribution = try #require(MuseProviderDescriptor.descriptor.settingsSection
            .credentialContribution(context: ProviderCredentialSettingsContext(config: config, account: nil)))
        let settings = ProviderSettingsSnapshot(contributions: [contribution])
        #expect(settings[MuseProviderSettingsKey.self]?.cookieSource == expected)
    }

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        private var rejectedDomains: [String] = []
        var all: [URLRequest] {
            self.lock.withLock { self.requests }
        }

        var domains: [String] {
            self.lock.withLock { self.rejectedDomains }
        }

        func append(_ request: URLRequest) {
            self.lock.withLock { self.requests.append(request) }
        }

        func reject(_ domain: String) {
            self.lock.withLock { self.rejectedDomains.append(domain) }
        }
    }

    static func fetchWithWeb(
        engine: ProviderPluginEngineKind,
        account: String = Self.activeWithoutWindows,
        cookieSource: ProviderCookieSource = .auto,
        teamID: String? = Self.teamID,
        requests: RequestLog = RequestLog(),
        rejected: RequestLog = RequestLog(),
        web: @escaping @Sendable (String) -> (String, Int)) async throws -> ProviderPluginResult
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                requests.append(request)
                guard request.url?.host == "dev.meta.ai" else {
                    return try Self.response(request, body: account)
                }
                let (body, status) = web(request.url?.path ?? "")
                return try Self.response(request, body: body, status: status)
            })
        return try await runtime.fetchResult(
            settings: teamID.map { ["MUSE_WEB_TEAM_ID": $0] } ?? [:],
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            now: Date(timeIntervalSince1970: TimeInterval(Self.now)),
            cookieSource: cookieSource,
            cookieInvalidator: { rejected.reject($0) },
            cookieResolver: { _, domain in
                #expect(domain == "dev.meta.ai")
                return "llama_dev_sess=fixture"
            })
    }

    static func fetch(
        _ body: String,
        engine: ProviderPluginEngineKind,
        status: Int = 200) async throws -> UsageSnapshot
    {
        let runtime = try BundledPluginTestSupport.runtime(
            "muse",
            engine: engine,
            transport: ProviderHTTPTransportHandler { request in
                try Self.response(request, body: body, status: status)
            })
        return try await runtime.fetchUsage(
            secrets: ["MUSE_DEVICE_TOKEN": "dca:fixture-token"],
            now: Date(timeIntervalSince1970: 1_788_580_000))
    }

    private static func response(
        _ request: URLRequest,
        body: String,
        status: Int = 200) throws -> (Data, URLResponse)
    {
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]))
        return (Data(body.utf8), response)
    }

    private static func expectFailure(
        _ kind: ProviderFetchClassifiedError.Kind,
        operation: () async throws -> UsageSnapshot) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected \(kind.rawValue)")
        } catch let error as ProviderFetchClassifiedError {
            #expect(error.kind == kind)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }
    }
}
