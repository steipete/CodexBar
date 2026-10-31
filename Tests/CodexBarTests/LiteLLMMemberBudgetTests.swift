import Foundation
import Testing
@testable import CodexBarCore

struct LiteLLMMemberBudgetTests {
    private static let key = #"{"info":{"user_id":"user-1","team_id":"team-1","spend":96.0,"max_budget":null}}"#

    private static func user(
        userBudget: String = "null",
        membershipBudget: String = "null",
        membershipSpend: String = "96.0",
        memberships: String? = nil) -> String
    {
        let rows = memberships ?? """
        [{
          "user_id": "user-1", "spend": \(membershipSpend),
          "litellm_budget_table": {"max_budget": \(membershipBudget), "budget_reset_at": "2026-11-20T00:00:00Z"}
        }]
        """
        return """
        {
          "user_id": "user-1",
          "user_info": {"user_id": "user-1", "max_budget": \(userBudget), "spend": 140.0},
          "teams": [{
            "team_id": "team-1", "team_alias": "Platform", "max_budget": 5000.0, "spend": 1200.0,
            "budget_reset_at": "2026-11-15T00:00:00Z",
            "team_memberships": \(rows)
          }]
        }
        """
    }

    private static func team(
        memberBudget: String =
            #"{"max_budget": 250.0, "budget_duration": "30d", "budget_reset_at": "2026-11-01T00:00:00Z"}"#,
        teamID: String = "team-1",
        memberships: String = "[]") -> String
    {
        """
        {
          "team_id": "\(teamID)",
          "team_info": {
            "team_id": "\(teamID)", "team_alias": "Platform", "max_budget": 5000.0, "spend": 1200.0,
            "team_member_budget_table": \(memberBudget)
          },
          "team_memberships": \(memberships)
        }
        """
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) {
            self.lock.withLock { self.paths.append(path) }
        }

        var all: [String] {
            self.lock.withLock { self.paths }
        }
    }

    private static func fetch(
        user: String,
        team: String? = nil,
        teamStatus: Int = 200,
        key: String = LiteLLMMemberBudgetTests.key,
        engine: ProviderPluginEngineKind) async throws -> (UsageSnapshot, [String])
    {
        let requests = Requests()
        let transport = ProviderHTTPTransportHandler { request in
            let path = try #require(request.url?.path)
            requests.record(path)
            let body: String
            var status = 200
            switch path {
            case "/key/info": body = key
            case "/user/info": body = user
            case "/team/info":
                body = team ?? "{}"
                status = teamStatus
            default: body = "{}"
            }
            return (Data(body.utf8), HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let snapshot = try await BundledPluginTestSupport.runtime("litellm", engine: engine, transport: transport)
            .fetchUsage(
                settings: ["LITELLM_BASE_URL": "https://proxy.example.com"],
                secrets: ["LITELLM_API_KEY": "fixture-key"],
                now: Date(timeIntervalSince1970: 1))
        return (snapshot, requests.all)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `team default member budget becomes the personal budget`(engine: ProviderPluginEngineKind) async throws {
        let (snapshot, paths) = try await Self.fetch(user: Self.user(), team: Self.team(), engine: engine)
        #expect(paths == ["/key/info", "/user/info", "/team/info"])
        let primary = try #require(snapshot.primary)
        #expect(abs(primary.usedPercent - 38.4) < 0.000001)
        #expect(primary.resetDescription == "$96.00 / $250.00")
        #expect(primary.resetsAt == ISO8601DateParser.parse("2026-11-01T00:00:00Z"))
        #expect(snapshot.providerCost?.used == 96)
        #expect(snapshot.providerCost?.limit == 250)
        #expect(snapshot.providerCost?.period == "Personal budget")
        let secondary = try #require(snapshot.secondary)
        #expect(secondary.resetDescription == "Team Platform: $1,200.00 / $5,000.00")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a member's own team budget wins and needs no team request`(engine: ProviderPluginEngineKind) async throws {
        let (snapshot, paths) = try await Self.fetch(
            user: Self.user(membershipBudget: "40.0", membershipSpend: "10.0"), team: Self.team(), engine: engine)
        #expect(paths == ["/key/info", "/user/info"])
        let primary = try #require(snapshot.primary)
        #expect(primary.usedPercent == 25)
        #expect(primary.resetDescription == "$10.00 / $40.00")
        #expect(primary.resetsAt == ISO8601DateParser.parse("2026-11-20T00:00:00Z"))
        #expect(snapshot.providerCost?.limit == 40)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a configured personal budget is untouched`(engine: ProviderPluginEngineKind) async throws {
        let (snapshot, paths) = try await Self.fetch(
            user: Self.user(userBudget: "300.0"), team: Self.team(), engine: engine)
        #expect(paths == ["/key/info", "/user/info"])
        #expect(snapshot.primary?.resetDescription == "$140.00 / $300.00")
        #expect(snapshot.providerCost?.limit == 300)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `no member budget keeps spend only`(engine: ProviderPluginEngineKind) async throws {
        for team in [
            Self.team(memberBudget: "null"),
            Self.team(memberBudget: #"{"max_budget": null}"#),
            Self.team(memberBudget: #"{"max_budget": 0}"#),
            Self.team(teamID: "team-other"),
            #"{"team_id":"team-1"}"#,
        ] {
            let (snapshot, paths) = try await Self.fetch(user: Self.user(), team: team, engine: engine)
            #expect(paths == ["/key/info", "/user/info", "/team/info"])
            #expect(snapshot.primary == nil)
            #expect(snapshot.providerCost?.period == "Personal spend")
            #expect(snapshot.providerCost?.used == 140)
            #expect(snapshot.secondary != nil)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines, [401, 403, 404, 429, 500, 503])
    func `team info failures never discard the budgets already read`(
        engine: ProviderPluginEngineKind, status: Int) async throws
    {
        let (snapshot, paths) = try await Self.fetch(
            user: Self.user(), team: #"{"detail":"nope"}"#, teamStatus: status, engine: engine)
        #expect(paths.first == "/key/info" && paths.contains("/team/info"))
        #expect(snapshot.primary == nil)
        #expect(snapshot.secondary?.resetDescription == "Team Platform: $1,200.00 / $5,000.00")
        #expect(snapshot.providerCost?.period == "Personal spend")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a key without a team does not look for a member budget`(engine: ProviderPluginEngineKind) async throws {
        let (snapshot, paths) = try await Self.fetch(
            user: Self.user(),
            team: Self.team(),
            key: #"{"info":{"user_id":"user-1","spend":96.0}}"#,
            engine: engine)
        #expect(paths == ["/key/info", "/user/info"])
        #expect(snapshot.primary == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `user-wide spend is never used for a member budget`(engine: ProviderPluginEngineKind) async throws {
        // $140 across every team, but no spend row for this team anywhere: nothing correctly scoped to show.
        let (snapshot, _) = try await Self.fetch(
            user: Self.user(memberships: "[]"), team: Self.team(), engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost?.period == "Personal spend")
        #expect(snapshot.providerCost?.used == 140)
        #expect(snapshot.secondary != nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `member spend missing from user info is read from team info memberships`(
        engine: ProviderPluginEngineKind) async throws
    {
        // user_info.spend is 140 (all teams); only $10 was spent in this team.
        let teamMemberships = """
        [{"user_id": "someone-else", "spend": 999.0, "team_id": "team-1"},
         {"user_id": "user-1", "spend": 10.0, "team_id": "team-1"}]
        """
        let (snapshot, paths) = try await Self.fetch(
            user: Self.user(memberships: "[]"), team: Self.team(memberships: teamMemberships), engine: engine)
        #expect(paths == ["/key/info", "/user/info", "/team/info"])
        let primary = try #require(snapshot.primary)
        #expect(primary.usedPercent == 4)
        #expect(primary.resetDescription == "$10.00 / $250.00")
        #expect(snapshot.providerCost?.used == 10)
        #expect(snapshot.providerCost?.limit == 250)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `team info membership rows for other users or teams are ignored`(
        engine: ProviderPluginEngineKind) async throws
    {
        let teamMemberships = """
        [{"user_id": "user-1", "spend": 10.0, "team_id": "team-other"},
         {"user_id": "someone-else", "spend": 20.0, "team_id": "team-1"}]
        """
        let (snapshot, _) = try await Self.fetch(
            user: Self.user(memberships: "[]"), team: Self.team(memberships: teamMemberships), engine: engine)
        #expect(snapshot.primary == nil)
        #expect(snapshot.providerCost?.period == "Personal spend")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `user info membership rows from another team are ignored`(engine: ProviderPluginEngineKind) async throws {
        let memberships = """
        [{"user_id": "user-1", "team_id": "team-other", "spend": 90.0,
          "litellm_budget_table": {"max_budget": 100.0}}]
        """
        let fallback = #"[{"user_id":"user-1","team_id":"team-1","spend":10.0}]"#
        let (snapshot, paths) = try await Self.fetch(
            user: Self.user(memberships: memberships),
            team: Self.team(memberships: fallback),
            engine: engine)
        #expect(paths == ["/key/info", "/user/info", "/team/info"])
        #expect(snapshot.primary?.usedPercent == 4)
        #expect(snapshot.providerCost?.used == 10)
        #expect(snapshot.providerCost?.limit == 250)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `fallback member overrides precede defaults without replacing user overrides`(
        engine: ProviderPluginEngineKind) async throws
    {
        let memberships = """
        [{"user_id":"user-1","team_id":"team-1","spend":10.0,
          "litellm_budget_table":{"max_budget":40.0,"budget_reset_at":"2026-11-09T00:00:00Z"}}]
        """
        let (fallback, _) = try await Self.fetch(
            user: Self.user(memberships: "[]"), team: Self.team(memberships: memberships), engine: engine)
        #expect(fallback.primary?.usedPercent == 25)
        #expect(fallback.providerCost?.limit == 40)
        #expect(fallback.primary?.resetsAt == ISO8601DateParser.parse("2026-11-09T00:00:00Z"))

        let (own, _) = try await Self.fetch(
            user: Self.user(membershipBudget: "20.0", membershipSpend: "null"),
            team: Self.team(memberships: memberships),
            engine: engine)
        #expect(own.primary?.usedPercent == 50)
        #expect(own.providerCost?.limit == 20)
    }
}
