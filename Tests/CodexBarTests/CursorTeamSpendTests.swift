import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorTeamSpendTests {
    @Test(arguments: [
        ("portal-selected-team-id=22; team_id=11", 22),
        ("team_id=11", 11), ("", nil),
        ("portal-selected-team-id=99; team_id=11", nil),
        ("portal-selected-team-id=bad; team_id=11", nil),
        ("portal-selected-team-id=; team_id=11", nil),
        ("portal-selected-team-id=22; portal-selected-team-id=22", nil),
        ("team_id=11; team_id=22", nil),
    ] as [(String, Int?)])
    func `team selection respects portal and rejects ambiguity`(cookie: String, expected: Int?) throws {
        let teams = try JSONDecoder().decode(CursorTeams.self, from: Data(#"{"teams":[{"id":11},{"id":22}]}"#.utf8))
        #expect(teams.selectedID(cookieHeader: cookie) == expected)
    }

    @Test(arguments: [
        (#"{"teams":[{"id":22}]}"#, 22),
        (#"{"teams":[]}"#, nil),
        (#"{"teams":[{"id":22},{"id":22}]}"#, nil),
        (#"{"teams":[{"id":22},{"id":-1}]}"#, nil),
    ] as [(String, Int?)])
    func `only one validated team permits an absent selection cookie`(json: String, expected: Int?) throws {
        let teams = try JSONDecoder().decode(CursorTeams.self, from: Data(json.utf8))
        #expect(teams.selectedID(cookieHeader: "auth=fixture") == expected)
    }

    @Test(arguments: [
        (#"{"overallSpendCents":1312,"effectivePerUserLimitDollars":150}"#, 13.12),
        (#"{"overallSpendCents":0,"monthlyLimitDollars":150}"#, 0),
        (#"{"overallSpendCents":20000,"monthlyLimitDollars":150}"#, 200),
        (#"{"overallSpendCents":1312,"effectivePerUserLimitDollars":null,"monthlyLimitDollars":150}"#, 13.12),
        (#"{"monthlyLimitDollars":150}"#, nil),
        (#"{"overallSpendCents":1312,"effectivePerUserLimitDollars":0,"monthlyLimitDollars":150}"#, nil),
        (#"{"overallSpendCents":1312,"effectivePerUserLimitDollars":-1,"monthlyLimitDollars":150}"#, nil),
        (#"{"overallSpendCents":-1,"monthlyLimitDollars":150}"#, nil),
        (#"{"overallSpendCents":1312,"monthlyLimitDollars":-1}"#, nil),
        (#"{"overallSpendCents":1312,"effectivePerUserLimitDollars":"invalid","monthlyLimitDollars":150}"#, nil),
        (#"{"overallSpendCents":1e309,"monthlyLimitDollars":150}"#, nil),
    ] as [(String, Double?)])
    func `member budget preserves absent zero invalid and unlimited values`(json: String, expected: Double?) {
        let member = try? JSONDecoder().decode(CursorTeamSpend.Member.self, from: Data(json.utf8))
        #expect(member?.budget?.usedUSD == expected)
    }

    @Test(arguments: ["enterprise", "business", "pro"])
    func `reported member budget replaces zero summary without changing dates or other charges`(
        plan: String) async throws
    {
        let fixture = Self.fixture(
            plan: plan,
            pages: [Self.fullPage(Self.other, total: 2), Self.page(Self.member, total: 2)])
        let snapshot = try await fixture.probe.fetchWithCookieHeader(
            Self.cookie, identityFallback: .init(subject: nil, email: "unrelated@example.com"))
        if plan == "pro" {
            #expect(snapshot.planPercentUsed == 0)
            #expect(snapshot.planLimitUSD == 20)
        } else {
            #expect(abs(snapshot.planPercentUsed - 8.7466666667) < 0.00001)
            #expect(snapshot.planUsedUSD == 13.12)
            #expect(snapshot.planLimitUSD == 150)
            #expect(snapshot.requestsLimit == nil)
            #expect(snapshot.autoPercentUsed == nil)
            #expect(snapshot.apiPercentUsed == nil)
            #expect(snapshot.toUsageSnapshot().primary?.usedPercent == snapshot.planPercentUsed)
        }
        #expect(snapshot.billingCycleStart == ISO8601DateParser.parse("2026-09-01T00:00:00Z"))
        #expect(snapshot.billingCycleEnd == ISO8601DateParser.parse("2026-10-01T00:00:00Z"))
        #expect(snapshot.onDemandUsedUSD == 2.5)
        #expect(snapshot.onDemandLimitUSD == 10)
        #expect(snapshot.rawJSON?.contains("other@example.com") == false)
        #expect(snapshot.rawJSON?.contains("99999") == false)
        let requests = await fixture.transport.requests()
        let teamRequests = requests.filter { $0.url?.path.contains("/api/dashboard/") == true &&
            $0.url?.path.hasSuffix("get-sand-usage-status") != true
        }
        #expect(teamRequests.count == (plan == "pro" ? 0 : 3))
        for request in teamRequests {
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Cookie") == Self.cookie)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.example.test:8443")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://cursor.example.test:8443/prefix/dashboard")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.timeoutInterval > 0 && request.timeoutInterval <= 0.5)
            if request.url?.path.hasSuffix("get-team-spend") == true {
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(object["teamId"] as? Int == 22)
                #expect(object["pageSize"] as? Int == 50)
            }
        }
    }

    @Test(arguments: [
        [Self.page(Self.member + "," + Self.member)],
        [Self.page((Array(repeating: Self.other, count: 50) + [Self.member]).joined(separator: ","))],
        [Self.fullPage(Self.member, total: 2), Self.page(Self.member, total: 2)],
        [Self.fullPage(Self.member, total: 2), Self.page(Self.other, total: 3)],
        [Self.fullPage(Self.member, total: 2), "invalid JSON"],
        [Self.page(Self.member, total: 2), Self.page(Self.other, total: 2)],
        [Self.page(Self.member, total: 21)],
        [Self.page(Self.member, total: 0)],
        [#"{"teamMemberSpend":[{"email":"member@example.com","overallSpendCents":1312,"monthlyLimitDollars":150}]}"#],
        [Self.page("", total: 2), Self.page(Self.member, total: 2)],
    ])
    func `unknown incomplete and contradictory pagination cannot publish a member`(pages: [String]) async throws {
        let fixture = Self.fixture(pages: pages)
        let snapshot = try await fixture.probe.fetchWithCookieHeader(Self.cookie)
        #expect(snapshot.planPercentUsed == 0)
        #expect(snapshot.planLimitUSD == 20)
        let requests = await fixture.transport.requests().filter { $0.url?.path.hasSuffix("get-team-spend") == true }
        #expect(requests.count <= 20)
    }

    @Test
    func `a first-page candidate waits for all pages and normalized email matching`() async throws {
        let fixture = Self.fixture(
            identity: #"{"email":" MEMBER@example.com "}"#,
            pages: [Self.fullPage(Self.member, total: 2), Self.page(Self.other, total: 2)])
        let snapshot = try await fixture.probe.fetchWithCookieHeader(Self.cookie)
        #expect(snapshot.planUsedUSD == 13.12)
        let pages = await fixture.transport.requests().filter { $0.url?.path.hasSuffix("get-team-spend") == true }
        #expect(pages.count == 2)
    }

    @Test
    func `the final permitted page can establish a unique member`() async throws {
        let pages = Array(repeating: Self.fullPage(Self.other, total: 20), count: 19) + [Self.page(
            Self.member,
            total: 20)]
        let fixture = Self.fixture(pages: pages)
        let snapshot = try await fixture.probe.fetchWithCookieHeader(Self.cookie)
        #expect(snapshot.planUsedUSD == 13.12)
        let requests = await fixture.transport.requests().filter { $0.url?.lastPathComponent == "get-team-spend" }
        #expect(requests.count == 20)
    }

    @Test(arguments: [#"{}"#, #"{"email":""}"#, #"{"email":"  "}"#, "invalid JSON"])
    func `absent fresh identity never triggers team lookup`(identity: String) async throws {
        let fixture = Self.fixture(identity: identity, pages: [Self.page(Self.member)])
        let snapshot = try await fixture.probe.fetchWithCookieHeader(
            Self.cookie, identityFallback: .init(subject: nil, email: "member@example.com"))
        #expect(snapshot.planPercentUsed == 0)
        #expect(snapshot.planLimitUSD == 20)
        let requests = await fixture.transport.requests()
        #expect(!requests.contains { $0.url?.path.hasSuffix("/teams") == true })
    }

    @Test(arguments: ["me", "teams", "get-team-spend"], [403, 500, 200])
    func `optional team HTTP and decoding failures preserve the summary`(endpoint: String, code: Int) async throws {
        let fixture = Self.fixture(pages: [Self.page(Self.member)], failures: [endpoint: code])
        let snapshot = try await fixture.probe.fetchWithCookieHeader(
            Self.cookie, identityFallback: .init(subject: nil, email: "member@example.com"))
        #expect(snapshot.planPercentUsed == 0)
        #expect(snapshot.planUsedUSD == 0)
        #expect(snapshot.planLimitUSD == 20)
        #expect(snapshot.onDemandUsedUSD == 2.5)
    }

    @Test(arguments: ["1e300", "invalid", "0"])
    func `team date fields do not change the summary billing cycle`(date: String) async throws {
        let page = Self.page(Self.member).replacingOccurrences(of: "1788220800000", with: date)
        let fixture = Self.fixture(pages: [page])
        let snapshot = try await fixture.probe.fetchWithCookieHeader(Self.cookie)
        try #require(snapshot.billingCycleStart == ISO8601DateParser.parse("2026-09-01T00:00:00Z"))
        #expect(snapshot.billingCycleEnd == ISO8601DateParser.parse("2026-10-01T00:00:00Z"))
        #expect(snapshot.toUsageSnapshot().primary?.resetsAt == snapshot.billingCycleEnd)
    }

    @Test
    func `an expired lookup deadline sends no team requests`() async throws {
        let fixture = Self.fixture(pages: [Self.page(Self.member)])
        await #expect(throws: URLError(.timedOut)) {
            try await fixture.probe.fetchTeamSpend(
                cookieHeader: Self.cookie, email: "member@example.com", deadline: .distantPast)
        }
        #expect(await fixture.transport.requests().isEmpty)
    }

    @Test
    func `caller cancellation survives an optional transport returning success`() async {
        let entered = CursorTeamSpendGate()
        let release = CursorTeamSpendGate()
        let fixture = Self.fixture(pages: [
            Self.page(Self.member, total: 2),
            Self.page(Self.other, total: 2),
        ]) { request in
            guard request.url?.lastPathComponent == "get-team-spend" else { return }
            await entered.open()
            await release.wait()
        }
        let task = Task {
            do {
                let snapshot = try await fixture.probe.fetchWithCookieHeader(Self.cookie)
                await entered.open()
                return snapshot
            } catch {
                await entered.open()
                throw error
            }
        }
        await entered.wait()
        task.cancel()
        await release.open()
        switch await task.result {
        case let .failure(error): #expect(error is CancellationError)
        case .success: Issue.record("Cancelled caller must not receive a summary fallback")
        }
        let requests = await fixture.transport.requests().filter { $0.url?.lastPathComponent == "get-team-spend" }
        #expect(requests.count == 1)
    }

    private static let cookie = "auth=fixture; team_id=11; portal-selected-team-id=22"
    private static let member = #"{"email":"member@example.com","overallSpendCents":1312,"#
        + #""monthlyLimitDollars":100,"effectivePerUserLimitDollars":150}"#
    private static let other = #"{"email":"other@example.com","overallSpendCents":99999,"monthlyLimitDollars":150}"#

    private static func fullPage(_ member: String, total: Int) -> String {
        self.page(([member] + Array(repeating: self.other, count: 49)).joined(separator: ","), total: total)
    }

    private static func page(_ members: String, total: Int = 1) -> String {
        """
        {"teamMemberSpend":[\(members)],"totalPages":\(total),
        "subscriptionCycleStart":"1788220800000","nextCycleStart":"1793491200000"}
        """
    }

    private static func fixture(
        plan: String = "enterprise",
        identity: String = #"{"email":"member@example.com","sub":"fixture-user"}"#,
        pages: [String],
        failures: [String: Int] = [:],
        beforeResponse: (@Sendable (URLRequest) async -> Void)? = nil)
        -> (probe: CursorStatusProbe, transport: ProviderHTTPTransportStub)
    {
        let transport = ProviderHTTPTransportStub { request in
            await beforeResponse?(request)
            let url = try #require(request.url)
            let endpoint = url.lastPathComponent
            if let code = failures[endpoint] {
                let (response, data) = makeCursorStatusProbeResponse(url: url, body: "invalid JSON", statusCode: code)
                return (data, response)
            }
            let body: String
            switch endpoint {
            case "usage-summary":
                body = """
                {"membershipType":"\(plan)","billingCycleStart":"2026-09-01T00:00:00Z",
                "billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{
                "plan":{"used":0,"limit":2000,"totalPercentUsed":0,"autoPercentUsed":0,"apiPercentUsed":0},
                "onDemand":{"used":250,"limit":1000}}}
                """
            case "me": body = identity
            case "usage": body = #"{"gpt-4":{"numRequests":500,"maxRequestUsage":500}}"#
            case "teams": body = #"{"teams":[{"id":11},{"id":22}]}"#
            case "get-team-spend":
                let data = try #require(request.httpBody)
                let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let page = try #require(payload["page"] as? Int)
                guard pages.indices.contains(page - 1) else { throw URLError(.badServerResponse) }
                body = pages[page - 1]
            default: throw URLError(.badURL)
            }
            let (response, data) = makeCursorStatusProbeResponse(url: url, body: body, statusCode: 200)
            return (data, response)
        }
        let probe = CursorStatusProbe(
            baseURL: URL(string: "https://cursor.example.test:8443/prefix")!,
            timeout: 0.5,
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: transport,
            sessionStore: CursorSessionStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cursor-team-fixture-\(UUID().uuidString)")
                .appendingPathComponent("session.json")))
        return (probe, transport)
    }
}

private actor CursorTeamSpendGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }

    func open() {
        self.isOpen = true
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
