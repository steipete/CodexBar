import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS) || os(Linux)
struct CursorTeamSpend: Decodable, Sendable {
    struct Member: Decodable, Sendable {
        let email: String?
        let overallSpendCents: Double?
        let effectivePerUserLimitDollars: Double?
        let monthlyLimitDollars: Double?

        var budget: Budget? {
            // An explicit zero/unlimited effective limit must not fall back to a nominal monthly limit.
            guard let used = self.overallSpendCents, used.isFinite, used >= 0,
                  let limit = self.effectivePerUserLimitDollars ?? self.monthlyLimitDollars,
                  limit.isFinite, limit > 0 else { return nil }
            return Budget(usedUSD: used / 100, limitUSD: limit)
        }
    }

    struct Budget: Sendable {
        let usedUSD: Double
        let limitUSD: Double
    }

    let teamMemberSpend: [Member]
    let totalPages: Int?
}

struct CursorTeams: Decodable {
    struct Team: Decodable {
        let id: Int
    }

    let teams: [Team]

    func selectedID(cookieHeader: String) -> Int? {
        let ids = Set(self.teams.map(\.id).filter { $0 > 0 })
        guard ids.count == self.teams.count else { return nil }
        let cookies = cookieHeader.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        }
        for name in ["portal-selected-team-id", "team_id"] {
            let values = cookies.filter { $0.first == Substring(name) }
            if !values.isEmpty {
                guard values.count == 1, values[0].count == 2,
                      let id = Int(values[0][1]), ids.contains(id) else { return nil }
                return id
            }
        }
        return ids.count == 1 ? ids.first : nil
    }
}

extension CursorUsageSummary {
    var isTeamPlan: Bool {
        ["enterprise", "business", "team", "teams"].contains(self.membershipType?.lowercased() ?? "")
            || self.limitType?.lowercased() == "team"
    }
}

extension CursorStatusProbe {
    func fetchTeamSpend(
        cookieHeader: String,
        email: String,
        deadline: Date?) async throws -> CursorTeamSpend.Budget?
    {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else { return nil }
        // Bound the entire optional lookup, including pagination, rather than each request independently.
        let lookupDeadline = min(deadline ?? .distantFuture, Date().addingTimeInterval(10))
        let teams: CursorTeams = try await self.fetchTeamDashboard(
            "teams", body: [:], cookieHeader: cookieHeader, deadline: lookupDeadline)
        guard let teamID = teams.selectedID(cookieHeader: cookieHeader) else { return nil }
        var expectedPages: Int?
        var candidate: CursorTeamSpend.Budget?
        for page in 1...20 {
            let spend: CursorTeamSpend = try await self.fetchTeamDashboard(
                "get-team-spend",
                body: ["teamId": teamID, "page": page, "pageSize": 50, "sortBy": "name", "sortDirection": "asc"],
                cookieHeader: cookieHeader,
                deadline: lookupDeadline)
            guard let totalPages = spend.totalPages, (1...20).contains(totalPages),
                  expectedPages == nil || expectedPages == totalPages,
                  !spend.teamMemberSpend.isEmpty, spend.teamMemberSpend.count <= 50,
                  page == totalPages || spend.teamMemberSpend.count == 50
            else { return nil }
            expectedPages = totalPages
            for member in spend.teamMemberSpend where member.email?
                .trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(email) == .orderedSame
            {
                guard candidate == nil, let budget = member.budget else { return nil }
                candidate = budget
            }
            // A later page can invalidate an earlier match; publish only after the complete page set.
            if page == totalPages { return candidate }
        }
        return nil
    }

    private func fetchTeamDashboard<Response: Decodable>(
        _ endpoint: String,
        body: [String: Any],
        cookieHeader: String,
        deadline: Date) async throws -> Response
    {
        try Task.checkCancellation()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw URLError(.timedOut) }
        var request = URLRequest(url: self.baseURL.appendingPathComponent("/api/dashboard/\(endpoint)"))
        request.httpMethod = "POST"
        request.timeoutInterval = min(self.timeout, remaining)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        guard var origin = URLComponents(url: self.baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        origin.user = nil
        origin.password = nil
        request.setValue(origin.url?.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(self.baseURL.appendingPathComponent("dashboard").absoluteString, forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await self.urlSession.data(for: request)
        try Task.checkCancellation()
        guard deadline.timeIntervalSinceNow > 0 else { throw URLError(.timedOut) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        // Do not retain raw team responses: they contain other members' identities and spending.
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
#endif
