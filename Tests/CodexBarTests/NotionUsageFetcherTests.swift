import Foundation
import Testing
@testable import CodexBarCore

struct NotionUsageFetcherTests {
    private static let now = Date(timeIntervalSince1970: 1_785_600_000)
    /// Billing period end reported by `getCreditRateLimitStatus` (milliseconds since epoch).
    private static let periodEndMilliseconds = 1_788_000_000_000
    private static let periodEndSeconds = Self.periodEndMilliseconds / 1000
    private static let rollingResetSeconds = 12600

    private static let businessSpaceID = "11111111-2222-3333-4444-555555555555"
    private static let personalSpaceID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    private static let userID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private static let rateLimitResponse = """
    {"status":"within_limit",
     "window":{"creditType":"basic_ai_credits","scope":"per_user","window":"6h","used":42.5,"limit":100},
     "resetsInSeconds":12600,
     "billingPeriodWindow":{"creditType":"basic_ai_credits","scope":"per_user","cadence":"billing_period",
      "used":18.0,"limit":100,"periodEndMs":1788000000000},
     "enforcement":"preview"}
    """

    /// Older responses wrap each record once; newer ones wrap twice. Both shapes must parse.
    private static let singlyWrappedSpacesResponse = """
    {"\(Self.userID)":{
      "notion_user":{"\(Self.userID)":{"value":{
        "id":"\(Self.userID)","email":"legacy@example.com","name":"Legacy Person"}}},
      "space":{
        "\(Self.businessSpaceID)":{"value":{
          "id":"\(Self.businessSpaceID)","name":"Acme","plan_type":"team","subscription_tier":"business"}}}}}
    """

    private static let spacesResponse = """
    {"\(Self.userID)":{
      "notion_user":{"\(Self.userID)":{"value":{"value":{
        "id":"\(Self.userID)","email":"person@example.com","name":"Example Person"}}}},
      "space":{
        "\(Self.personalSpaceID)":{"value":{"value":{
          "id":"\(Self.personalSpaceID)","name":"Personal","plan_type":"personal","subscription_tier":"free"}}},
        "\(Self.businessSpaceID)":{"value":{"value":{
          "id":"\(Self.businessSpaceID)","name":"Acme","plan_type":"team","subscription_tier":"business"}}}}}}
    """

    private static func rateLimitStatus() throws -> NotionCreditRateLimitStatus {
        try NotionUsageParser.parseRateLimitStatus(Data(self.rateLimitResponse.utf8))
    }

    @Test
    func `parses credit rate limit status`() throws {
        let status = try Self.rateLimitStatus()

        #expect(status.status == "within_limit")
        #expect(status.enforcement == "preview")
        #expect(status.window?.window == "6h")
        #expect(status.window?.used == 42.5)
        #expect(status.window?.limit == 100)
        #expect(status.resetsInSeconds == 12600)
        #expect(status.billingPeriodWindow?.used == 18.0)
        #expect(status.billingPeriodWindow?.cadence == "billing_period")
        #expect(status.isNotApplicable == false)
    }

    @Test
    func `maps rolling and billing windows to usage snapshot`() throws {
        let workspace = NotionWorkspace(
            id: Self.businessSpaceID,
            name: "Acme",
            planType: "team",
            subscriptionTier: "business")
        let account = NotionAccount(
            userID: Self.userID,
            email: "person@example.com",
            name: "Example Person",
            workspaces: [workspace])
        let usage = try NotionUsageSnapshot(
            rateLimit: Self.rateLimitStatus(),
            workspace: workspace,
            account: account,
            updatedAt: Self.now).toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 42.5)
        #expect(usage.primary?.windowMinutes == 360)
        #expect(
            usage.primary?.resetsAt.map { Int($0.timeIntervalSince1970) }
                == Int(Self.now.timeIntervalSince1970) + Self.rollingResetSeconds)
        #expect(usage.secondary?.usedPercent == 18.0)
        #expect(usage.secondary?.windowMinutes == nil)
        #expect(usage.secondary?.resetsAt.map { Int($0.timeIntervalSince1970) } == Self.periodEndSeconds)
        #expect(usage.identity?.providerID == .notion)
        #expect(usage.identity?.accountEmail == "person@example.com")
        #expect(usage.identity?.accountOrganization == "Acme")
        #expect(usage.identity?.loginMethod == "Business")
    }

    @Test
    func `flags workspaces without an allowance`() throws {
        let status = try NotionUsageParser.parseRateLimitStatus(Data(#"{"status":"not_applicable"}"#.utf8))

        #expect(status.isNotApplicable)
        #expect(status.window == nil)
        #expect(status.billingPeriodWindow == nil)
    }

    @Test
    func `parses spaces payload into account and workspaces`() throws {
        let account = try NotionUsageParser.parseSpaces(Data(Self.spacesResponse.utf8))

        #expect(account.userID == Self.userID)
        #expect(account.email == "person@example.com")
        #expect(account.name == "Example Person")
        #expect(account.workspaces.count == 2)
        #expect(account.workspaces.contains { $0.id == Self.businessSpaceID && $0.name == "Acme" })
    }

    @Test
    func `prefers a workspace whose plan carries an allowance`() throws {
        let account = try NotionUsageParser.parseSpaces(Data(Self.spacesResponse.utf8))

        // The personal/free space sorts first by id but reports `not_applicable`, so it must not win.
        #expect(account.resolveWorkspace()?.id == Self.businessSpaceID)
    }

    @Test
    func `honours a configured workspace id in either uuid form`() throws {
        let account = try NotionUsageParser.parseSpaces(Data(Self.spacesResponse.utf8))
        let undashed = Self.personalSpaceID.replacingOccurrences(of: "-", with: "")

        #expect(account.resolveWorkspace(preferredID: Self.personalSpaceID)?.id == Self.personalSpaceID)
        #expect(account.resolveWorkspace(preferredID: undashed)?.id == Self.personalSpaceID)
    }

    @Test
    func `falls back to the first workspace when none carries an allowance`() {
        let account = NotionAccount(
            userID: Self.userID,
            email: nil,
            name: nil,
            workspaces: [
                NotionWorkspace(
                    id: Self.personalSpaceID,
                    name: "Personal",
                    planType: "personal",
                    subscriptionTier: "free"),
            ])

        #expect(account.resolveWorkspace()?.id == Self.personalSpaceID)
    }

    @Test
    func `converts notion window tokens to minutes`() {
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: "6h") == 360)
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: "30m") == 30)
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: "7d") == 10080)
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: "1w") == 10080)
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: "weekly") == nil)
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: nil) == nil)
    }

    @Test
    func `scales usage against the reported limit`() {
        #expect(NotionUsageSnapshot.percent(used: 25, limit: 50) == 50)
        #expect(NotionUsageSnapshot.percent(used: 42.5, limit: 100) == 42.5)
        // Over-quota values are preserved; display clamping happens downstream.
        #expect(NotionUsageSnapshot.percent(used: 120, limit: 100) == 120)
        // Without a usable limit there is nothing to measure against, so no percentage is invented.
        #expect(NotionUsageSnapshot.percent(used: nil, limit: 100) == nil)
        #expect(NotionUsageSnapshot.percent(used: 42, limit: 0) == nil)
        #expect(NotionUsageSnapshot.percent(used: 42, limit: nil) == nil)
    }

    @Test
    func `omits a window that carries no measurable allowance`() {
        let status = NotionCreditRateLimitStatus(
            status: "within_limit",
            window: NotionRollingWindow(
                creditType: "basic_ai_credits",
                scope: "per_user",
                window: "6h",
                used: 42,
                limit: nil),
            resetsInSeconds: 60,
            billingPeriodWindow: nil,
            enforcement: "preview")
        let usage = NotionUsageSnapshot(
            rateLimit: status,
            workspace: nil,
            account: nil,
            updatedAt: Self.now).toUsageSnapshot()

        // A fabricated 0% here would read as "plenty of headroom" on a workspace that may be capped.
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
    }

    @Test
    func `rejects a response that carries no usage windows`() {
        let body = Data(#"{"errorId":"abc","name":"UnauthorizedError"}"#.utf8)

        #expect(throws: NotionUsageError.parseFailed("getCreditRateLimitStatus returned no usage windows.")) {
            try NotionUsageParser.parseRateLimitStatus(body)
        }
    }

    @Test
    func `keeps a reset that lands exactly now`() {
        #expect(NotionUsageSnapshot.rollingReset(from: 0, now: Self.now) == Self.now)
        #expect(NotionUsageSnapshot.rollingReset(from: -1, now: Self.now) == nil)
    }

    @Test
    func `builds a request context from a manual cookie header`() {
        let context = NotionUsageFetcher.requestContext(from: "token_v2=abc; notion_user_id=def")

        #expect(context?.cookieHeader.contains("token_v2=abc") == true)
        #expect(NotionUsageFetcher.requestContext(from: "   ") == nil)
    }

    @Test
    func `parses singly wrapped records`() throws {
        let account = try NotionUsageParser.parseSpaces(Data(Self.singlyWrappedSpacesResponse.utf8))

        #expect(account.email == "legacy@example.com")
        #expect(account.workspaces.count == 1)
        #expect(account.workspaces.first?.name == "Acme")
    }

    @Test
    func `refuses a spaces payload naming more than one user`() {
        let second = "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"
        let body = """
        {"\(Self.userID)":{"notion_user":{"\(Self.userID)":{"value":{"value":{"id":"\(Self.userID)"}}}}},
         "\(second)":{"notion_user":{"\(second)":{"value":{"value":{"id":"\(second)"}}}}}}
        """

        // Binding to whichever key sorts first would report the wrong account's allowance.
        #expect(throws: NotionUsageError.parseFailed("getSpaces response did not identify a single user.")) {
            try NotionUsageParser.parseSpaces(Data(body.utf8))
        }
    }

    @Test
    func `falls back to auto selection when the configured workspace id is unknown`() throws {
        let account = try NotionUsageParser.parseSpaces(Data(Self.spacesResponse.utf8))

        // A typo'd id would otherwise be queried anyway and answered with an opaque 403.
        #expect(account.resolveWorkspace(preferredID: "00000000-0000-0000-0000-000000000000")?.id
            == Self.businessSpaceID)
    }

    // MARK: - Transport-backed behaviour

    private struct StubResponse: Sendable {
        let statusCode: Int
        let body: Data
    }

    private struct StubTransport: ProviderHTTPTransport {
        let spaces: StubResponse
        let rateLimit: StubResponse

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let stub = (request.url?.path.hasSuffix("getSpaces") ?? false) ? self.spaces : self.rateLimit
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: stub.statusCode,
                      httpVersion: nil,
                      headerFields: nil)
            else {
                throw URLError(.badServerResponse)
            }
            return (stub.body, response)
        }
    }

    private static func fetchUsage(transport: StubTransport, preferredSpaceID: String? = nil) async throws
        -> NotionUsageSnapshot
    {
        try await NotionUsageFetcher.fetchUsage(
            context: NotionUsageFetcher.RequestContext(cookieHeader: "token_v2=abc"),
            preferredSpaceID: preferredSpaceID,
            timeout: 5,
            now: self.now,
            transport: transport)
    }

    @Test
    func `maps an unauthorized response to invalid credentials`() async {
        let transport = StubTransport(
            spaces: StubResponse(statusCode: 401, body: Data("{}".utf8)),
            rateLimit: StubResponse(statusCode: 200, body: Data(Self.rateLimitResponse.utf8)))

        await #expect(throws: NotionUsageError.invalidCredentials) {
            try await Self.fetchUsage(transport: transport)
        }
    }

    @Test
    func `maps a server error to an api error`() async {
        let transport = StubTransport(
            spaces: StubResponse(statusCode: 200, body: Data(Self.spacesResponse.utf8)),
            rateLimit: StubResponse(statusCode: 500, body: Data("nope".utf8)))

        await #expect(throws: NotionUsageError.apiError("HTTP 500 from getCreditRateLimitStatus")) {
            try await Self.fetchUsage(transport: transport)
        }
    }

    @Test
    func `throws when the resolved workspace has no allowance`() async {
        let transport = StubTransport(
            spaces: StubResponse(statusCode: 200, body: Data(Self.spacesResponse.utf8)),
            rateLimit: StubResponse(statusCode: 200, body: Data(#"{"status":"not_applicable"}"#.utf8)))

        await #expect(throws: NotionUsageError.allowanceNotApplicable(workspace: "Personal")) {
            try await Self.fetchUsage(transport: transport, preferredSpaceID: Self.personalSpaceID)
        }
    }

    @Test
    func `returns a snapshot for a workspace that carries an allowance`() async throws {
        let transport = StubTransport(
            spaces: StubResponse(statusCode: 200, body: Data(Self.spacesResponse.utf8)),
            rateLimit: StubResponse(statusCode: 200, body: Data(Self.rateLimitResponse.utf8)))

        let snapshot = try await Self.fetchUsage(transport: transport)

        #expect(snapshot.workspace?.id == Self.businessSpaceID)
        #expect(snapshot.account?.email == "person@example.com")
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 42.5)
    }
}
