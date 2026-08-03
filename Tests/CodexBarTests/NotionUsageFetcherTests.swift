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

    /// Older responses wrap each record once; newer ones wrap twice. Both shapes must parse.
    private static let singlyWrappedSpacesResponse = """
    {"\(Self.userID)":{
      "notion_user":{"\(Self.userID)":{"value":{
        "id":"\(Self.userID)","email":"legacy@example.com","name":"Legacy Person"}}},
      "space":{
        "\(Self.businessSpaceID)":{"value":{
          "id":"\(Self.businessSpaceID)","name":"Acme","plan_type":"team","subscription_tier":"business"}}}}}
    """

    private static func rateLimitStatus() throws -> NotionCreditRateLimitStatus {
        try NotionUsageParser.parseRateLimitStatus(self.fixtureData("get-credit-rate-limit-status"))
    }

    private static func account() throws -> NotionAccount {
        try NotionUsageParser.parseSpaces(self.fixtureData("get-spaces"))
    }

    private static func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Providers/Notion"))
        return try Data(contentsOf: url)
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
        // The monthly sentinel, not nil: it is what makes the provider's pace capability match, which is
        // what swaps in the real calendar cycle ending at `resetsAt`.
        #expect(usage.secondary?.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
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
        let account = try Self.account()

        #expect(account.userID == Self.userID)
        #expect(account.email == "person@example.com")
        #expect(account.name == "Example Person")
        #expect(account.workspaces.count == 2)
        #expect(account.workspaces.contains { $0.id == Self.businessSpaceID && $0.name == "Acme" })
    }

    @Test
    func `prefers a workspace whose plan carries an allowance`() throws {
        let account = try Self.account()

        // The personal/free space sorts first by id but reports `not_applicable`, so it must not win.
        #expect(account.resolveWorkspace()?.id == Self.businessSpaceID)
    }

    @Test
    func `honours a configured workspace id in either uuid form`() throws {
        let account = try Self.account()
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
    func `names a manually pasted bare token v2 value`() {
        let context = NotionUsageFetcher.requestContext(from: "bare-token-value")

        #expect(context?.cookieHeader == "token_v2=bare-token-value")
    }

    @Test
    func `defaults automatic imports to Chrome only`() {
        #if os(macOS)
        #expect(NotionProviderDescriptor.descriptor.metadata.browserCookieOrder == [.chrome])
        #else
        #expect(NotionProviderDescriptor.descriptor.metadata.browserCookieOrder == nil)
        #endif
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
        let account = try Self.account()

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
    func `maps an unauthorized response to invalid credentials`() async throws {
        let transport = try StubTransport(
            spaces: StubResponse(statusCode: 401, body: Data("{}".utf8)),
            rateLimit: StubResponse(statusCode: 200, body: Self.fixtureData("get-credit-rate-limit-status")))

        await #expect(throws: NotionUsageError.invalidCredentials) {
            try await Self.fetchUsage(transport: transport)
        }
    }

    @Test
    func `maps a server error to an api error`() async throws {
        let transport = try StubTransport(
            spaces: StubResponse(statusCode: 200, body: Self.fixtureData("get-spaces")),
            rateLimit: StubResponse(statusCode: 500, body: Data("nope".utf8)))

        await #expect(throws: NotionUsageError.apiError("HTTP 500 from getCreditRateLimitStatus")) {
            try await Self.fetchUsage(transport: transport)
        }
    }

    @Test
    func `throws when the resolved workspace has no allowance`() async throws {
        let transport = try StubTransport(
            spaces: StubResponse(statusCode: 200, body: Self.fixtureData("get-spaces")),
            rateLimit: StubResponse(statusCode: 200, body: Data(#"{"status":"not_applicable"}"#.utf8)))

        await #expect(throws: NotionUsageError.allowanceNotApplicable(workspace: "Personal")) {
            try await Self.fetchUsage(transport: transport, preferredSpaceID: Self.personalSpaceID)
        }
    }

    @Test
    func `returns a snapshot for a workspace that carries an allowance`() async throws {
        let transport = try StubTransport(
            spaces: StubResponse(statusCode: 200, body: Self.fixtureData("get-spaces")),
            rateLimit: StubResponse(statusCode: 200, body: Self.fixtureData("get-credit-rate-limit-status")))

        let snapshot = try await Self.fetchUsage(transport: transport)

        #expect(snapshot.workspace?.id == Self.businessSpaceID)
        #expect(snapshot.account?.email == "person@example.com")
        #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 42.5)
    }

    /// Midnight UTC on the given day, so a cycle length is exactly a whole number of days.
    private static func utcDate(year: Int, month: Int, day: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        return try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day)))
    }

    private static func monthlyWindow(usedPercent: Double, resetsAt: Date) -> RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
            resetsAt: resetsAt,
            resetDescription: nil)
    }

    @Test
    func `scores the billing window against the real calendar month`() throws {
        // The sentinel is a placeholder, not a duration: resolution has to yield the true length of the
        // cycle ending at the reset. Asserting only the capability booleans would stay green if the
        // descriptor were swapped for a plain 30-day capability, which is the regression to catch.
        let pace = ProviderDescriptorRegistry.descriptor(for: .notion).pace
        let februaryCycle = try Self.monthlyWindow(
            usedPercent: 18,
            resetsAt: Self.utcDate(year: 2026, month: 3, day: 1))
        let mayCycle = try Self.monthlyWindow(
            usedPercent: 18,
            resetsAt: Self.utcDate(year: 2026, month: 6, day: 1))

        #expect(pace.resolvedResetWindowForPace(februaryCycle).windowMinutes == 28 * 24 * 60)
        #expect(pace.resolvedResetWindowForPace(mayCycle).windowMinutes == 31 * 24 * 60)
        #expect(pace.resolvedResetWindowForPace(februaryCycle).resetsAt == februaryCycle.resetsAt)
        #expect(pace.resolvedResetWindowForPace(februaryCycle).usedPercent == februaryCycle.usedPercent)
    }

    @Test
    func `a billing window with no length is scored against the caller's default`() throws {
        // A nil length is not pace-safe on its own: `UsagePace.weekly` substitutes `defaultWindowMinutes`
        // rather than skipping the window, so dropping the sentinel would score a month against a week.
        let resetsAt = try Self.utcDate(year: 2026, month: 3, day: 1)
        let now = resetsAt.addingTimeInterval(-3 * 24 * 60 * 60)
        let lengthless = RateWindow(usedPercent: 37, windowMinutes: nil, resetsAt: resetsAt, resetDescription: nil)

        let weekScored = try #require(UsagePace.weekly(window: lengthless, now: now, defaultWindowMinutes: 10080))
        // Four of seven days elapsed against a week that is really a month.
        #expect((weekScored.expectedUsedPercent * 10).rounded() / 10 == 57.1)

        let resolved = ProviderDescriptorRegistry.descriptor(for: .notion).pace
            .resolvedResetWindowForPace(Self.monthlyWindow(usedPercent: 37, resetsAt: resetsAt))
        let cycleScored = try #require(UsagePace.weekly(window: resolved, now: now, defaultWindowMinutes: 10080))
        // Twenty-five of February's twenty-eight days elapsed.
        #expect((cycleScored.expectedUsedPercent * 10).rounded() / 10 == 89.3)
    }

    @Test
    func `does not treat the rolling window as a monthly one`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .notion)
        let rolling = RateWindow(
            usedPercent: 42.5,
            windowMinutes: 360,
            resetsAt: Self.now.addingTimeInterval(3600),
            resetDescription: nil)

        #expect(!descriptor.pace.usesInferredMonthlyDuration(window: rolling))
    }

    @Test
    func `drops a rolling length that collides with the monthly sentinel`() {
        // `30d`, `720h` and `43200m` all parse to the monthly sentinel, which pace matching keys on, so a
        // rolling window carrying one would be resolved as a calendar cycle ending hours from now.
        #expect(NotionUsageSnapshot.minutes(fromWindowToken: "30d")
            == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(NotionUsageSnapshot.rollingMinutes(fromWindowToken: "30d") == nil)
        #expect(NotionUsageSnapshot.rollingMinutes(fromWindowToken: "720h") == nil)
        #expect(NotionUsageSnapshot.rollingMinutes(fromWindowToken: "43200m") == nil)
        #expect(NotionUsageSnapshot.rollingMinutes(fromWindowToken: "6h") == 360)
    }
}
