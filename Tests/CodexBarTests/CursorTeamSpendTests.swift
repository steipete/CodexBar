import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CursorTeamSpendTests {
    @Test(arguments: [
        ("portal-selected-team-id=22; team_id=11", 22),
        ("team_id=11", 11),
        ("", nil),
        ("portal-selected-team-id=99; team_id=11", nil),
        ("portal-selected-team-id=bad; team_id=11", nil),
        ("team_id=11; team_id=22", nil),
    ] as [(String, Int?)])
    func `team selection respects portal and rejects ambiguity`(cookie: String, expected: Int?) throws {
        let teams = try JSONDecoder().decode(CursorTeams.self, from: Data(#"{"teams":[{"id":11},{"id":22}]}"#.utf8))
        #expect(teams.selectedID(cookieHeader: cookie) == expected)
    }

    @Test
    func `single team supports app auth without selection cookies`() throws {
        let teams = try JSONDecoder().decode(CursorTeams.self, from: Data(#"{"teams":[{"id":22}]}"#.utf8))
        #expect(teams.selectedID(cookieHeader: "auth=test") == 22)
    }

    @Test(arguments: [
        (#"{"overallSpendCents":1312,"effectivePerUserLimitDollars":150}"#, 13.12),
        (#"{"overallSpendCents":0,"monthlyLimitDollars":150}"#, 0),
        (#"{"monthlyLimitDollars":150}"#, nil),
        (#"{"overallSpendCents":1312,"effectivePerUserLimitDollars":0,"monthlyLimitDollars":150}"#, nil),
        (#"{"overallSpendCents":-1,"monthlyLimitDollars":150}"#, nil),
        (#"{"overallSpendCents":1312,"monthlyLimitDollars":-1}"#, nil),
    ] as [(String, Double?)])
    func `member budget validates missing and unlimited values`(json: String, expected: Double?) throws {
        let member = try JSONDecoder().decode(CursorTeamSpend.Member.self, from: Data(json.utf8))
        #expect(member.budget?.usedUSD == expected)
    }

    @Test(arguments: ["enterprise", "business", "pro"])
    func `fetch uses selected member quota only for team plans`(plan: String) async throws {
        let session = CursorStatusProbeTestSession { request in
            let url = try #require(request.url)
            let body: String
            switch url.path {
            case "/api/usage-summary":
                body = """
                {"membershipType":"\(plan)","individualUsage":{"plan":{"used":0,"limit":2000,
                "totalPercentUsed":0,"autoPercentUsed":0,"apiPercentUsed":0}}}
                """
            case "/api/auth/me":
                body = #"{"email":"member@example.com","sub":"test-user"}"#
            case "/api/usage":
                body = #"{"gpt-4":{"numRequests":500,"maxRequestUsage":500}}"#
            case "/api/dashboard/teams":
                #expect(plan != "pro")
                #expect(request.httpMethod == "POST")
                body = #"{"teams":[{"id":11},{"id":22}]}"#
            case "/api/dashboard/get-team-spend":
                #expect(plan != "pro")
                #expect(request.httpMethod == "POST")
                let data = try Self.bodyData(request)
                let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(payload["teamId"] as? Int == 22)
                #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("auth=test") == true)
                if payload["page"] as? Int == 1 {
                    body = """
                    {"teamMemberSpend":[{"email":"other@example.com","overallSpendCents":99999}],"totalPages":2}
                    """
                } else {
                    body = """
                    {"teamMemberSpend":[{"email":"MEMBER@example.com","overallSpendCents":1312,
                    "monthlyLimitDollars":100,"effectivePerUserLimitDollars":150}],"totalPages":2,
                    "subscriptionCycleStart":"1788220800000","nextCycleStart":"1790812800000"}
                    """
                }
            default:
                throw URLError(.badURL)
            }
            return makeCursorStatusProbeResponse(url: url, body: body, statusCode: 200)
        }
        let snapshot = try await CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0),
            urlSession: session.urlSession)
            .fetchWithManualCookies("auth=test; team_id=11; portal-selected-team-id=22")
        if plan == "pro" {
            #expect(snapshot.planPercentUsed == 0)
            #expect(snapshot.planLimitUSD == 20)
        } else {
            #expect(abs(snapshot.planPercentUsed - 8.7466666667) < 0.00001)
            #expect(snapshot.planUsedUSD == 13.12)
            #expect(snapshot.planLimitUSD == 150)
            #expect(snapshot.billingCycleStart == Date(timeIntervalSince1970: 1_788_220_800))
            #expect(snapshot.billingCycleEnd == Date(timeIntervalSince1970: 1_790_812_800))
            #expect(snapshot.requestsLimit == nil)
            #expect(snapshot.autoPercentUsed == nil)
            #expect(snapshot.apiPercentUsed == nil)
            #expect(snapshot.toUsageSnapshot().primary?.usedPercent == snapshot.planPercentUsed)
        }
        #expect(snapshot.rawJSON?.contains("other@example.com") == false)
    }

    @Test(arguments: [
        #"{"teamMemberSpend":[{"email":"other@example.com","overallSpendCents":1312,"monthlyLimitDollars":150}]}"#,
        #"{"teamMemberSpend":[{"email":"member@example.com","monthlyLimitDollars":150}]}"#,
        #"{"teamMemberSpend":[{"email":"member@example.com"},{"email":"member@example.com"}]}"#,
        #"{"teamMemberSpend":[],"totalPages":1000}"#,
    ])
    func `missing ambiguous or incomplete member never supplies a budget`(body: String) async throws {
        let session = CursorStatusProbeTestSession { request in
            let url = try #require(request.url)
            return makeCursorStatusProbeResponse(
                url: url,
                body: url.path.hasSuffix("/teams") ? #"{"teams":[{"id":22}]}"# : body,
                statusCode: 200)
        }
        let budget = try await CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0), urlSession: session.urlSession)
            .fetchTeamSpend(cookieHeader: "auth=test", email: "member@example.com", deadline: nil)
        #expect(budget == nil)
        #expect(session.requestCount == 2)
    }

    private static func bodyData(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    @Test(arguments: [403, 500, 200])
    func `optional team failures preserve summary`(status: Int) async throws {
        let session = CursorStatusProbeTestSession { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/usage-summary":
                return makeCursorStatusProbeResponse(
                    url: url,
                    body: #"{"membershipType":"enterprise","individualUsage":{"overall":{"used":2500,"limit":10000}}}"#,
                    statusCode: 200)
            case "/api/auth/me":
                return makeCursorStatusProbeResponse(
                    url: url,
                    body: #"{"email":"member@example.com"}"#,
                    statusCode: 200)
            default:
                return makeCursorStatusProbeResponse(url: url, body: "invalid JSON", statusCode: status)
            }
        }
        let snapshot = try await CursorStatusProbe(
            browserDetection: BrowserDetection(cacheTTL: 0), urlSession: session.urlSession)
            .fetchWithManualCookies("auth=test")
        #expect(snapshot.planPercentUsed == 25)
    }
}
