import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct ClaudePlatformPluginTests {
    private static let now = Date(timeIntervalSince1970: 1_791_849_600) // 2026-10-13 UTC
    private static let chatOrganization = "11111111-1111-4111-8111-111111111111"
    private static let apiOrganization = "22222222-2222-4222-8222-222222222222"
    private static let organizations = """
    [{"uuid":"\(chatOrganization)","name":"Synthetic Chat Organization","capabilities":["chat","claude_max"]},
     {"uuid":"\(apiOrganization)","name":"Synthetic API Org",
      "capabilities":["api","api_individual","customer_terms:standard"]}]
    """
    private static let credits = """
    {"amount":18725,"currency":"USD","balance":{"money":null,"credits":{"amount_minor":18725,"exponent":2}},
     "balance_credits":187,"amount_without_scoped_credits":6250,"auto_reload_settings":null,
     "last_paid_purchase_cents":10000,
     "tranches":[{"remaining_amount_minor_units":6250,"currency":"USD","expires_at":"2027-05-01T00:00:00Z",
       "granted_amount_minor_units":10000,"granted_at":"2026-05-01T00:00:00Z","program_id":"api_credits",
       "name":null,"id":"fixture-purchase","scope":{"kind":"unscoped","applies_to":[]}}],
     "promo_tranches":[{"remaining_amount_minor_units":12475,"currency":"USD","expires_at":"2026-10-28T00:00:00Z",
       "granted_amount_minor_units":20000,"granted_at":"2026-10-01T00:00:00Z",
       "program_id":"subscription_api_credit","name":"API credit (Max 20x)","id":"fixture-promo",
       "scope":{"kind":"scoped","applies_to":[{"product":"api"},{"product":"agent_sdk"}]}}],
     "next_expires_at":"2026-10-28T00:00:00Z"}
    """

    private static let otherAPIOrganization = "33333333-3333-4333-8333-333333333333"

    private static func credits(exponent: Int = 2, amount: Int = 18725, promo: String, tranches: String) -> String {
        """
        {"amount":\(amount),"currency":"USD","balance":{"money":null,"credits":{"amount_minor":\(amount),
         "exponent":\(exponent)}},"promo_tranches":[\(promo)],"tranches":[\(tranches)]}
        """
    }

    private static func grant(
        name: String?,
        program: String,
        remaining: Int,
        granted: Int,
        expires: String?) -> String
    {
        let name = name.map { "\"\($0)\"" } ?? "null"
        let expires = expires.map { "\"\($0)\"" } ?? "null"
        return """
        {"remaining_amount_minor_units":\(remaining),"granted_amount_minor_units":\(granted),"currency":"USD",
         "expires_at":\(expires),"program_id":"\(program)","name":\(name)}
        """
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `console credits map balance spend and expiring grants`(engine: ProviderPluginEngineKind) async throws {
        let fixture = Fixture()
        let usage = try await Self.fetch(engine, fixture: fixture)
        let cost = try #require(usage.providerCost)
        #expect(cost.balance == 187.25)
        #expect(cost.used == 187.25)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "Prepaid credits")
        #expect(cost.resetsAt == nil)

        let subscription = try #require(usage.primary)
        #expect(abs(subscription.usedPercent - 37.625) < 0.000_001)
        #expect(subscription.resetsAt == nil)
        #expect(subscription.resetDescription == "$124.75 of $200.00 left · Expires Oct 28 (UTC)")
        let purchased = try #require(usage.secondary)
        #expect(abs(purchased.usedPercent - 37.5) < 0.000_001)
        #expect(purchased.resetsAt == nil)
        #expect(purchased.resetDescription == "$62.50 of $100.00 left · Expires May 1, 2027 (UTC)")

        #expect(usage.details.map(\.title) == ["Billing"])
        #expect(usage.detailRow(label: "This month (UTC)")?.value == "$43.21")
        #expect(usage.identity?.accountOrganization == "Synthetic API Org")
        #expect(usage.identity?.accountEmail == nil)
        // Billing requests use the API organization, never the chat organization listed first.
        #expect(await fixture.paths == [
            "/api/organizations",
            "/api/organizations/\(Self.apiOrganization)/prepaid/credits",
            "/api/organizations/\(Self.apiOrganization)/current_spend",
        ])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `a forbidden api organization falls through to the next readable one`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture(
            organizations: """
            [{"uuid":"\(Self.chatOrganization)","name":"Synthetic Chat Organization","capabilities":["chat"]},
             {"uuid":"\(Self.apiOrganization)","name":"Synthetic Member Org","capabilities":["api"]},
             {"uuid":"\(Self.otherAPIOrganization)","name":"Synthetic Owner Org","capabilities":["api"]}]
            """,
            creditsStatus: [Self.apiOrganization: 403])
        let usage = try await Self.fetch(engine, fixture: fixture)
        #expect(usage.providerCost?.balance == 187.25)
        #expect(usage.identity?.accountOrganization == "Synthetic Owner Org")
        #expect(await fixture.paths == [
            "/api/organizations",
            "/api/organizations/\(Self.apiOrganization)/prepaid/credits",
            "/api/organizations/\(Self.otherAPIOrganization)/prepaid/credits",
            "/api/organizations/\(Self.otherAPIOrganization)/current_spend",
        ])
        #expect(await fixture.rejections == 0)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `subscription lane uses the soonest grant with credit and lists the rest`(
        engine: ProviderPluginEngineKind) async throws
    {
        let credits = Self.credits(
            promo: [
                Self.grant(
                    name: "API credit (Max 20x)", program: "subscription_api_credit",
                    remaining: 15000, granted: 20000, expires: "2026-11-12T00:00:00Z"),
                Self.grant(
                    name: "API credit (Pro)", program: "subscription_api_credit",
                    remaining: 0, granted: 5000, expires: "2026-10-20T00:00:00Z"),
                Self.grant(
                    name: "Launch credit", program: "promo",
                    remaining: 1000, granted: 1000, expires: "2026-10-31Tnot-a-date"),
            ].joined(separator: ","),
            tranches: Self.grant(
                name: nil, program: "api_credits", remaining: 2500, granted: 5000, expires: nil))
        let usage = try await Self.fetch(engine, fixture: Fixture(credits: credits))

        let subscription = try #require(usage.primary)
        #expect(abs(subscription.usedPercent - 25) < 0.000_001)
        #expect(subscription.resetDescription == "$150.00 of $200.00 left · Expires Nov 12 (UTC)")
        let purchased = try #require(usage.secondary)
        #expect(abs(purchased.usedPercent - 50) < 0.000_001)
        #expect(purchased.resetDescription == "$25.00 of $50.00 left")

        let others = try #require(usage.details.first { $0.title == "Other credit grants" })
        #expect(others.rows.map(\.label) == ["API credit (Pro)", "Launch credit"])
        let exhausted = others.rows[0]
        #expect(exhausted.value == "$0.00 of $50.00 left")
        #expect(exhausted.secondaryValue == "Expires Oct 20 (UTC)")
        #expect(exhausted.progress?.usedPercent == 100)
        // An unparseable expiry is unknown, not a failed refresh.
        let launch = others.rows[1]
        #expect(launch.value == "$10.00 of $10.00 left")
        #expect(launch.secondaryValue == nil)
        #expect(launch.progress?.usedPercent == 0)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `expired grants drop out and exhausted subscription credit leaves no api credit lane`(
        engine: ProviderPluginEngineKind) async throws
    {
        let credits = Self.credits(
            promo: [
                // Expiring exactly now counts as expired.
                Self.grant(
                    name: "API credit (Max 5x)", program: "subscription_api_credit",
                    remaining: 5000, granted: 10000, expires: "2026-10-13T00:00:00Z"),
                Self.grant(
                    name: "API credit (Pro)", program: "subscription_api_credit",
                    remaining: 0, granted: 5000, expires: "2026-10-20T00:00:00Z"),
            ].joined(separator: ","),
            tranches: [
                Self.grant(
                    name: nil, program: "api_credits",
                    remaining: 4000, granted: 4000, expires: "2026-10-12T00:00:00Z"),
                Self.grant(name: nil, program: "api_credits", remaining: 2500, granted: 5000, expires: nil),
            ].joined(separator: ","))
        let usage = try await Self.fetch(engine, fixture: Fixture(credits: credits))
        #expect(usage.primary == nil)
        #expect(usage.secondary?.resetDescription == "$25.00 of $50.00 left")
        let others = try #require(usage.details.first { $0.title == "Other credit grants" })
        #expect(others.rows.map(\.label) == ["API credit (Pro)"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `amounts use the reported credit exponent`(engine: ProviderPluginEngineKind) async throws {
        let credits = Self.credits(
            exponent: 3,
            amount: 187_250,
            promo: Self.grant(
                name: nil, program: "subscription_api_credit",
                remaining: 124_750, granted: 200_000, expires: "2026-10-28T00:00:00Z"),
            tranches: "")
        let usage = try await Self.fetch(engine, fixture: Fixture(credits: credits, spend: #"{"amount":43210}"#))
        #expect(usage.providerCost?.balance == 187.25)
        #expect(usage.primary?.resetDescription == "$124.75 of $200.00 left · Expires Oct 28 (UTC)")
        #expect(usage.detailRow(label: "This month (UTC)")?.value == "$43.21")
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `accounts without an api organization fail before billing requests`(
        engine: ProviderPluginEngineKind) async
    {
        let fixture = Fixture(organizations: """
        [{"uuid":"\(Self.chatOrganization)","name":"Synthetic Chat Organization","capabilities":["chat"]}]
        """)
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { error in
            let failure = error as? ProviderFetchClassifiedError
            return failure?.kind == .permissionDenied
                && failure?.message.contains("no Claude Console API organization") == true
        }
        #expect(await fixture.paths == ["/api/organizations"])
        #expect(await fixture.rejections == 0)
    }

    @Test(arguments: [401, 403], BundledPluginTestSupport.engines)
    func `rejected sessions report sign in guidance after every profile`(
        status: Int, engine: ProviderPluginEngineKind) async
    {
        let fixture = Fixture(organizationsStatus: status)
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { error in
            let failure = error as? ProviderFetchClassifiedError
            return failure?.kind == .authenticationExpired
                && failure?.message.contains("Sign in at platform.claude.com") == true
        }
        #expect(await fixture.rejections == 2)
        #expect(await fixture.sessions == 3)
    }

    @Test(
        arguments: ["/api/organizations", "/api/organizations/\(apiOrganization)/prepaid/credits"],
        BundledPluginTestSupport.engines)
    func `an unauthorized profile advances to the next profile`(
        path: String, engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture(firstSessionUnauthorizedPath: path)
        let usage = try await Self.fetch(engine, fixture: fixture)
        #expect(usage.providerCost?.balance == 187.25)
        #expect(await fixture.rejections == 1)
        #expect(await fixture.sessions == 2)
    }

    @Test(
        arguments: [
            (403, ProviderFetchClassifiedError.Kind.permissionDenied),
            (429, .rateLimited),
            (500, .providerUnavailable),
        ],
        BundledPluginTestSupport.engines)
    func `credit balance failures keep the session`(
        mapping: (status: Int, kind: ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async
    {
        let fixture = Fixture(creditsStatus: [Self.apiOrganization: mapping.status])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { error in
            (error as? ProviderFetchClassifiedError)?.kind == mapping.kind
        }
        #expect(await fixture.rejections == 0)
        #expect(await fixture.sessions == 1)
    }

    @Test(
        arguments: [
            (500, "{}"), (200, "not-json"), (200, #"{"amount":"4321"}"#), (200, #"{"amount":-1}"#),
            (401, "{}"), (403, "{}"), (429, "{}"),
        ],
        BundledPluginTestSupport.engines)
    func `unavailable spend keeps the prepaid balance`(
        spend: (status: Int, body: String), engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture(spend: spend.body, spendStatus: spend.status)
        let usage = try await Self.fetch(engine, fixture: fixture)
        let cost = try #require(usage.providerCost)
        #expect(cost.balance == 187.25)
        #expect(cost.used == 187.25)
        #expect(cost.period == "Prepaid credits")
        #expect(usage.primary != nil)
        #expect(usage.detailRow(label: "Spend")?.value == "Unavailable")
        #expect(usage.detailRow(label: "This month (UTC)") == nil)
        #expect(await fixture.rejections == 0)
    }

    @Test(
        arguments: [
            #"{"amount":null,"currency":"USD"}"#,
            #"{"amount":"18725","currency":"USD"}"#,
            #"{"amount":187.25,"currency":"USD"}"#,
            #"{"amount":1e99,"currency":"USD"}"#,
            #"{"amount":18725,"currency":"USD","tranches":{}}"#,
        ],
        BundledPluginTestSupport.engines)
    func `malformed required credit balance fails closed`(credits: String, engine: ProviderPluginEngineKind) async {
        let fixture = Fixture(credits: credits)
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .parseFailure }
        #expect(await fixture.rejections == 0)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `cancelling the optional spend request still cancels the refresh`(
        engine: ProviderPluginEngineKind) async
    {
        let fixture = Fixture(spendCancels: true)
        await #expect(throws: CancellationError.self) {
            _ = try await Self.fetch(engine, fixture: fixture)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `disabled cookies never call the broker`(engine: ProviderPluginEngineKind) async throws {
        let runtime = try BundledPluginTestSupport.runtime("claudeplatform", engine: engine, transport: Fixture())
        await #expect {
            try await runtime.fetchUsage(cookieSource: .off, cookieSessionResolver: { _, _ in
                Issue.record("Disabled cookies reached the broker")
                return nil
            })
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .missingCredential }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `automatic source retains access gated background refreshes`(engine: ProviderPluginEngineKind) throws {
        let runtime = try BundledPluginTestSupport.runtime("claudeplatform", engine: engine, transport: Fixture())
        let policy = try #require(runtime.manifest.cookiePolicy)
        #expect(policy.allowsImportAttempt(runtime: .app, interaction: .background))
        #expect(policy.cache == .nonpersistent)
        #expect(policy.requiredCookies == ["sessionKey"])
    }

    private static func fetch(_ engine: ProviderPluginEngineKind, fixture: Fixture) async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime("claudeplatform", engine: engine, transport: fixture)
        return try await runtime.fetchUsage(
            now: Self.now,
            cookieSessionResolver: { _, _ in await fixture.nextSession() },
            cookieSessionInvalidator: { _, _ in fixture.rejected.increment() })
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            self.lock.withLock { self.count }
        }

        func increment() { self.lock.withLock { self.count += 1 } }
    }

    private actor Fixture: ProviderHTTPTransport {
        let organizations: String
        let organizationsStatus: Int
        let credits: String
        let creditsStatus: [String: Int]
        let spend: String
        let spendStatus: Int
        let firstSessionUnauthorizedPath: String?
        let spendCancels: Bool
        let rejected = Counter()
        var sessions = 0
        var paths: [String] = []
        var rejections: Int {
            self.rejected.value
        }

        init(
            organizations: String = ClaudePlatformPluginTests.organizations,
            organizationsStatus: Int = 200,
            credits: String = ClaudePlatformPluginTests.credits,
            creditsStatus: [String: Int] = [:],
            spend: String = #"{"amount":4321,"resets_at":"2026-11-01T00:00:00Z"}"#,
            spendStatus: Int = 200,
            firstSessionUnauthorizedPath: String? = nil,
            spendCancels: Bool = false)
        {
            self.organizations = organizations
            self.organizationsStatus = organizationsStatus
            self.credits = credits
            self.creditsStatus = creditsStatus
            self.spend = spend
            self.spendStatus = spendStatus
            self.firstSessionUnauthorizedPath = firstSessionUnauthorizedPath
            self.spendCancels = spendCancels
        }

        func nextSession() -> ProviderPluginCookieSession? {
            self.sessions += 1
            guard self.sessions <= 2 else { return nil }
            return .init(
                header: "sessionKey=sk-ant-sid01-synthetic-\(self.sessions)",
                source: "Synthetic",
                origin: "https://platform.claude.com")
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(url.host == "platform.claude.com")
            #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("synthetic-\(self.sessions)") == true)
            self.paths.append(url.path)
            let components = url.path.split(separator: "/").map(String.init)
            var status = 200
            var body: String
            switch (components.count, components.last) {
            case (2, "organizations"):
                status = self.organizationsStatus
                body = self.organizations
            case (5, "credits") where components[3] == "prepaid":
                status = self.creditsStatus[components[2]] ?? 200
                body = self.credits
            case (4, "current_spend"):
                if self.spendCancels { throw URLError(.cancelled) }
                status = self.spendStatus
                body = self.spend
            default:
                Issue.record("Unexpected fixture request \(url.path)")
                throw URLError(.badURL)
            }
            if self.sessions == 1, url.path == self.firstSessionUnauthorizedPath { status = 401 }
            if status != 200 {
                body = #"{"type":"error","error":{"type":"permission_error","message":"Invalid authorization"}}"#
            }
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
        }
    }
}
