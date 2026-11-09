import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct GoogleDeveloperPluginTests {
    private static let email = "someone@example.com"
    private static let token = "fixture-at-token:+/="
    private static let otherBenefit = "[3,1,null,null,null,null,null,null,[2]]"
    /// Expires Nov 7, 2027 and granted Nov 7, 2026, both at 12:00 UTC, so time zones from UTC-11 to UTC+11
    /// show the same day.
    private static let appliedCredit = """
    [19,2,null,null,null,null,null,null,[1],[null,[1825588800,0],0,2,"",null,
     [["USD",100],["USD",87,500000000],"billingAccounts/000000-AAAAAA-BBBBBB",5,1],
     "00000000-0000-0000-0000-000000000000","00000000-0000-0000-0000-000000000000",
     null,null,null,null,null,null,22,[1794052800,0]],false,null,
     ["$100.00 monthly Gen AI & Cloud credits","Start building.",null,"Manage credits","Apply"],
     [13,21,22,26],null,true,"Remaining balance: $87.50","Expiring on: Nov 7, 2027"]
    """
    private static let unappliedCredit = "[19,2,null,null,null,null,null,null,[1],[null,null,0,2]]"

    private static func benefits(_ entries: String...) -> String {
        "[[\(entries.joined(separator: ","))]]"
    }

    private static func credit(billing: String, expiry: String = "[1825588800,0]") -> String {
        "[19,2,null,null,null,null,null,null,[1],[null,\(expiry),0,2,\"\",null,\(billing)]]"
    }

    struct Account {
        var email: String? = GoogleDeveloperPluginTests.email
        var token: String? = GoogleDeveloperPluginTests.token
        var pageStatus = 200
        var benefits = GoogleDeveloperPluginTests.benefits(GoogleDeveloperPluginTests.otherBenefit)
        var postStatus = 200
        var envelope: String?
    }

    private static let applied = Account(benefits: Self.benefits(Self.otherBenefit, Self.appliedCredit))
    private static let unapplied = Account(benefits: Self.benefits(Self.unappliedCredit))
    private static let noCredit = Account()

    @Test(arguments: BundledPluginTestSupport.engines)
    func `applied credit maps the remaining grant expiry and billing account`(
        engine: ProviderPluginEngineKind) async throws
    {
        let fixture = Fixture([[Self.applied]])
        let usage = try await Self.fetch(engine, fixture: fixture)
        let primary = try #require(usage.primary)
        #expect(abs(primary.usedPercent - 12.5) < 0.000_001)
        #expect(primary.resetDescription == "$87.50 of $100.00 left · Expires Nov 7, 2027")
        let cost = try #require(usage.providerCost)
        #expect(cost.used == 87.5)
        #expect(cost.balance == 87.5)
        #expect(cost.currencyCode == "USD")
        #expect(cost.period == "Monthly credit")
        #expect(usage.detailRow(label: "Billing account")?.value == "000000-AAAAAA-BBBBBB")
        #expect(usage.detailRow(label: "Granted")?.value == "Nov 7, 2026")
        #expect(usage.identity?.accountEmail == Self.email)
        #expect(usage.identity?.loginMethod == "Browser session")
        #expect(await fixture.requests == ["GET 1/0", "POST 1/0"])
        #expect(await fixture.rejections == 0)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `the first applied credit wins after accounts without one or with an RPC error`(
        engine: ProviderPluginEngineKind) async throws
    {
        let errored = Account(envelope: ")]}'\n\n40\n[[\"wrb.fr\",\"Ro0AYc\",null,null,null,[3],\"generic\"]]")
        var unapplied = Self.unapplied
        unapplied.email = "second@example.com"
        var applied = Self.applied
        applied.email = #"third\u0040example.com"#
        let fixture = Fixture([[errored, unapplied, applied, Self.applied]])
        let usage = try await Self.fetch(engine, fixture: fixture)
        #expect(usage.providerCost?.balance == 87.5)
        #expect(usage.identity?.accountEmail == "third@example.com")
        #expect(await fixture.requests == ["GET 1/0", "POST 1/0", "GET 1/1", "POST 1/1", "GET 1/2", "POST 1/2"])
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `an unapplied credit stops at the first signed-in profile`(
        engine: ProviderPluginEngineKind) async throws
    {
        var other = Self.noCredit
        other.email = "other@example.com"
        let fixture = Fixture([[other, Self.unapplied], [other, Self.unapplied]])
        let usage = try await Self.fetch(engine, fixture: fixture)
        #expect(usage.primary == nil)
        #expect(usage.providerCost == nil)
        let status = try #require(usage.detailRow(label: "Status"))
        #expect(status.value == "Not applied")
        #expect(status.secondaryValue == "Apply it at me.developers.google.com/benefits")
        #expect(usage.identity?.accountEmail == Self.email)
        #expect(await fixture.requests == ["GET 1/0", "POST 1/0", "GET 1/1", "POST 1/1", "GET 1/2"])
    }

    @Test(
        arguments: [benefits(otherBenefit), "[]"],
        BundledPluginTestSupport.engines)
    func `accounts without the credit benefit explain the subscription requirement`(
        benefits: String, engine: ProviderPluginEngineKind) async
    {
        let fixture = Fixture([[Account(benefits: benefits)]])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { error in
            let failure = error as? ProviderFetchClassifiedError
            return failure?.kind == .permissionDenied && failure?.message.contains("Google AI Pro or Ultra") == true
        }
        #expect(await fixture.rejections == 0)
        #expect(await fixture.sessions == 1)
    }

    @Test(arguments: ["repeat", "no email", "cap"], BundledPluginTestSupport.engines)
    func `account traversal stops at a repeated email a missing email or eight accounts`(
        stop: String, engine: ProviderPluginEngineKind) async
    {
        let accounts: [Account] = switch stop {
        case "repeat": [Self.noCredit, Self.noCredit]
        case "no email": [Self.noCredit, Account(email: nil)]
        default: (0..<9).map { Account(email: "user\($0)@example.com") }
        }
        let fixture = Fixture([accounts])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .permissionDenied }
        let requests = await fixture.requests
        #expect(requests.count(where: { $0.hasPrefix("GET") }) == (stop == "cap" ? 8 : 2))
        #expect(requests.count(where: { $0.hasPrefix("POST") }) == (stop == "cap" ? 8 : 1))
        #expect(await fixture.rejections == 0)
    }

    @Test(arguments: ["redirect", "unauthorized", "missing at"], BundledPluginTestSupport.engines)
    func `signed out sessions are rejected before any benefits request`(
        signedOut: String, engine: ProviderPluginEngineKind) async
    {
        let account = switch signedOut {
        case "redirect": Account(pageStatus: 302)
        case "unauthorized": Account(pageStatus: 401)
        default: Account(token: nil)
        }
        let fixture = Fixture([[account], [account]])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { error in
            let failure = error as? ProviderFetchClassifiedError
            return failure?.kind == .authenticationExpired
                && failure?.message.contains("Sign in at me.developers.google.com") == true
        }
        #expect(await fixture.requests == ["GET 1/0", "GET 2/0"])
        #expect(await fixture.rejections == 2)
        #expect(await fixture.sessions == 3)
    }

    @Test(
        arguments: [
            (Account(pageStatus: 429), ProviderFetchClassifiedError.Kind.rateLimited),
            (Account(postStatus: 500), .providerUnavailable),
            (
                Account(postStatus: 400, envelope: ")]}'\n\n25\n[[\"er\",null,null,null,null,400,null,null,null,3]]"),
                .apiFailure),
        ],
        BundledPluginTestSupport.engines)
    func `request failures keep the session`(
        mapping: (account: Account, kind: ProviderFetchClassifiedError.Kind), engine: ProviderPluginEngineKind) async
    {
        let fixture = Fixture([[mapping.account], [Self.applied]])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { error in
            let failure = error as? ProviderFetchClassifiedError
            return failure?.kind == mapping.kind && failure?.message.contains("Google Developer Program") == true
        }
        #expect(await fixture.rejections == 0)
        #expect(await fixture.sessions == 1)
    }

    @Test(
        arguments: [
            ")]}'\n\n18\n[[\"di\",42]]",
            ")]}'\n\n9\n[not-json",
        ],
        BundledPluginTestSupport.engines)
    func `malformed envelopes fail closed`(envelope: String, engine: ProviderPluginEngineKind) async {
        let fixture = Fixture([[Account(envelope: envelope)]])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .parseFailure }
        #expect(await fixture.rejections == 0)
    }

    @Test(
        arguments: [
            #"[["USD","100"],["USD",87],"billingAccounts/000000-AAAAAA-BBBBBB"]"#,
            #"[["usd",100],["usd",87],"billingAccounts/000000-AAAAAA-BBBBBB"]"#,
            #"[["USD",0],["USD",0],"billingAccounts/000000-AAAAAA-BBBBBB"]"#,
            #"{"granted":100}"#,
        ],
        BundledPluginTestSupport.engines)
    func `malformed applied credits fail closed`(billing: String, engine: ProviderPluginEngineKind) async {
        let fixture = Fixture([[Account(benefits: Self.benefits(Self.credit(billing: billing)))]])
        await #expect {
            try await Self.fetch(engine, fixture: fixture)
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .parseFailure }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `an exhausted grant without nanos or a readable expiry still shows its balance`(
        engine: ProviderPluginEngineKind) async throws
    {
        let billing = #"[["TRY",4983,710000000],["TRY"],"billingAccounts/000000-AAAAAA-BBBBBB"]"#
        let usage = try await Self.fetch(
            engine,
            fixture: Fixture([[Account(benefits: Self.benefits(Self.credit(billing: billing, expiry: "null")))]]))
        #expect(usage.primary?.usedPercent == 100)
        #expect(usage.primary?.resetDescription?.hasSuffix(" left") == true)
        #expect(usage.providerCost?.balance == 0)
        #expect(usage.providerCost?.currencyCode == "TRY")
        #expect(usage.detailRow(label: "Granted") == nil)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `cookie policy allows background refresh and disabled cookies never call the broker`(
        engine: ProviderPluginEngineKind) async throws
    {
        let runtime = try BundledPluginTestSupport.runtime("googledeveloper", engine: engine, transport: Fixture([]))
        let policy = try #require(runtime.manifest.cookiePolicy)
        #expect(policy.cache == .nonpersistent)
        #expect(policy.allowsImportAttempt(runtime: .app, interaction: .background))
        await #expect {
            try await runtime.fetchUsage(cookieSource: .off, cookieSessionResolver: { _, _ in
                Issue.record("Disabled cookies reached the broker")
                return nil
            })
        } throws: { ($0 as? ProviderFetchClassifiedError)?.kind == .missingCredential }
    }

    private static func fetch(_ engine: ProviderPluginEngineKind, fixture: Fixture) async throws -> UsageSnapshot {
        let runtime = try BundledPluginTestSupport.runtime("googledeveloper", engine: engine, transport: fixture)
        return try await runtime.fetchUsage(
            cookieSessionResolver: { _, _ in await fixture.nextSession() },
            cookieSessionInvalidator: { _, _ in fixture.rejected.increment() })
    }

    private static func envelope(_ benefits: String) throws -> String {
        let payload = try #require(String(
            data: JSONSerialization.data(withJSONObject: benefits, options: .fragmentsAllowed),
            encoding: .utf8))
        let chunks = [
            #"[["di",42],["af.httprm",41,"-1234567890",7]]"#,
            #"[["wrb.fr","Ro0AYc",\#(payload),null,null,null,"generic"]]"#,
            #"[["e",4,null,null,1234]]"#,
        ]
        return ")]}'\n\n" + chunks.map { "\($0.utf8.count)\n\($0)" }.joined(separator: "\n") + "\n"
    }

    private actor Fixture: ProviderHTTPTransport {
        let profiles: [[Account]]
        let rejected = Counter()
        var sessions = 0
        var requests: [String] = []
        var rejections: Int {
            self.rejected.value
        }

        init(_ profiles: [[Account]]) {
            self.profiles = profiles
        }

        func nextSession() -> ProviderPluginCookieSession? {
            self.sessions += 1
            guard self.sessions <= self.profiles.count else { return nil }
            return .init(
                header: "SID=fixture-\(self.sessions)",
                source: "Synthetic",
                origin: "https://me.developers.google.com")
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            #expect(url.host == "me.developers.google.com")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "SID=fixture-\(self.sessions)")
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let index = try #require(Int(query["authuser"] ?? ""))
            let accounts = self.profiles[self.sessions - 1]
            self.requests.append("\(request.httpMethod ?? "") \(self.sessions)/\(index)")
            guard index < accounts.count else {
                return try Self.response(url, status: 302, body: "", location: "https://accounts.google.com/")
            }
            let account = accounts[index]
            if request.httpMethod == "GET" {
                #expect(url.path == "/benefits")
                var values = [#""cfb2h":"boq_gdp-builders-ui_fixture""#]
                if let token = account.token { values.append(#""SNlM0e":"\#(token)""#) }
                if let email = account.email { values.append(#""oPEP7c":"\#(email)""#) }
                let html = "<html><script>window.WIZ_global_data = {\(values.joined(separator: ","))};</script></html>"
                return try Self.response(url, status: account.pageStatus, body: html)
            }
            #expect(request.httpMethod == "POST")
            #expect(url.path == "/_/GoogleDeveloperProfile/data/batchexecute")
            #expect(query["rpcids"] == "Ro0AYc")
            #expect(query["source-path"] == "/benefits")
            #expect(query["rt"] == "c")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://me.developers.google.com")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://me.developers.google.com/benefits")
            let fields = try BundledPluginTestSupport.formFields(request.httpBody)
            #expect(fields["f.req"] == #"[[["Ro0AYc","[]",null,"generic"]]]"#)
            #expect(fields["at"] == account.token)
            let body = try account.envelope ?? GoogleDeveloperPluginTests.envelope(account.benefits)
            return try Self.response(url, status: account.postStatus, body: body)
        }

        private static func response(
            _ url: URL,
            status: Int,
            body: String,
            location: String? = nil) throws -> (Data, URLResponse)
        {
            var headers = ["Content-Type": "text/html; charset=utf-8"]
            headers["Location"] = location
            return try (Data(body.utf8), #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: headers)))
        }
    }
}
