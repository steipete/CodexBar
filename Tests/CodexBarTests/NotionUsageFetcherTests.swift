import Foundation
import Testing
@testable import CodexBarCore

struct NotionUsageFetcherTests {
    private static let now = Date(timeIntervalSince1970: 1_785_600_000)
    /// Billing period end reported by `getCreditRateLimitStatus` (milliseconds since epoch).
    private static let periodEndMilliseconds = 1_787_342_274_000
    private static let periodEndSeconds = Self.periodEndMilliseconds / 1000
    private static let rollingResetSeconds = 20834

    private static let businessSpaceID = "11111111-2222-3333-4444-555555555555"
    private static let personalSpaceID = "66666666-7777-8888-9999-aaaaaaaaaaaa"
    private static let userID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private static let rateLimitResponse = """
    {"status":"within_limit",
     "window":{"creditType":"basic_ai_credits","scope":"per_user","window":"6h","used":85.31,"limit":100},
     "resetsInSeconds":20834,
     "billingPeriodWindow":{"creditType":"basic_ai_credits","scope":"per_user","cadence":"billing_period",
      "used":16.89,"limit":100,"periodEndMs":1787342274000},
     "enforcement":"preview"}
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
        #expect(status.window?.used == 85.31)
        #expect(status.window?.limit == 100)
        #expect(status.resetsInSeconds == 20834)
        #expect(status.billingPeriodWindow?.used == 16.89)
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

        #expect(usage.primary?.usedPercent == 85.31)
        #expect(usage.primary?.windowMinutes == 360)
        #expect(
            usage.primary?.resetsAt.map { Int($0.timeIntervalSince1970) }
                == Int(Self.now.timeIntervalSince1970) + Self.rollingResetSeconds)
        #expect(usage.secondary?.usedPercent == 16.89)
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
        #expect(NotionUsageSnapshot.percent(used: 85.31, limit: 100) == 85.31)
        // Over-quota values are preserved; display clamping happens downstream.
        #expect(NotionUsageSnapshot.percent(used: 120, limit: 100) == 120)
        #expect(NotionUsageSnapshot.percent(used: nil, limit: 100) == 0)
        #expect(NotionUsageSnapshot.percent(used: 42, limit: 0) == 42)
    }

    @Test
    func `builds a request context from a manual cookie header`() {
        let context = NotionUsageFetcher.requestContext(from: "token_v2=abc; notion_user_id=def")

        #expect(context?.cookieHeader.contains("token_v2=abc") == true)
        #expect(NotionUsageFetcher.requestContext(from: "   ") == nil)
    }
}
