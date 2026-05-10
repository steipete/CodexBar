import Foundation
import Testing
@testable import CodexBarCore

/// Tests for `CommandCodeUsageFetcher` parsers and the cookie/snapshot derivation,
/// using real responses captured from api.commandcode.ai for an active "individual-go" plan.
struct CommandCodeUsageFetcherTests {
    private static let creditsJSON = """
    {"credits":{"belowThreshold":false,"creditThreshold":0,"monthlyCredits":8.7784,\
    "purchasedCredits":0,"premiumMonthlyCredits":0,"opensourceMonthlyCredits":8.7784}}
    """

    private static let subscriptionJSON = """
    {"success":true,"data":{"id":"sub_1TTzt3DSZgxV3MJKG4ClCWpn","status":"active",\
    "userId":"915e93a7-a1f9-4c97-a3f0-20a85fcb3a45","orgId":null,\
    "createdAt":"2026-05-06T07:28:50.000Z","priceId":"price_1TMD8zDSZgxV3MJKxOZMVZrP",\
    "metadata":{"commandCode":"true","commandCodeUserId":"915e93a7-a1f9-4c97-a3f0-20a85fcb3a45"},\
    "quantity":1,"cancelAtPeriodEnd":false,\
    "currentPeriodStart":"2026-05-06T07:28:50.000Z","currentPeriodEnd":"2026-06-06T07:28:50.000Z",\
    "endedAt":null,"cancelAt":null,"canceledAt":null,"planId":"individual-go"}}
    """

    @Test
    func `parses credits payload`() throws {
        let data = try #require(Self.creditsJSON.data(using: .utf8))
        let payload = try CommandCodeUsageFetcher.parseCredits(data: data)
        #expect(payload.monthlyCredits == 8.7784)
        #expect(payload.purchasedCredits == 0)
        #expect(payload.premiumMonthlyCredits == 0)
        #expect(payload.opensourceMonthlyCredits == 8.7784)
    }

    @Test
    func `parses subscription payload`() throws {
        let data = try #require(Self.subscriptionJSON.data(using: .utf8))
        let payload = try #require(try CommandCodeUsageFetcher.parseSubscription(data: data))
        #expect(payload.planID == "individual-go")
        #expect(payload.status == "active")
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expectedEnd = isoFormatter.date(from: "2026-06-06T07:28:50.000Z")
        #expect(payload.currentPeriodEnd == expectedEnd)
    }

    @Test
    func `subscription on free tier returns nil`() throws {
        let data = Data(#"{"success":true,"data":null}"#.utf8)
        let payload = try CommandCodeUsageFetcher.parseSubscription(data: data)
        #expect(payload == nil)
    }

    @Test
    func `snapshot derives used and total from plan catalog`() throws {
        let plan = try #require(CommandCodePlanCatalog.plan(forID: "individual-go"))
        let snapshot = CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 8.7784,
            purchasedCredits: 0,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 8.7784,
            plan: plan,
            billingPeriodEnd: Date(timeIntervalSince1970: 1_780_000_000),
            subscriptionStatus: "active",
            updatedAt: Date(timeIntervalSince1970: 0))
        #expect(snapshot.monthlyCreditsTotal == 10)
        #expect(abs((snapshot.monthlyCreditsUsed ?? -1) - 1.2216) < 0.0001)

        let usage = snapshot.toUsageSnapshot()
        let primary = try #require(usage.primary)
        #expect(abs(primary.usedPercent - 12.216) < 0.001)
        #expect(primary.resetsAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(usage.identity?.loginMethod == "Go · $1.22 of $10.00")
    }

    @Test
    func `plan catalog covers known plans`() {
        #expect(CommandCodePlanCatalog.plan(forID: "individual-go")?.monthlyCreditsUSD == 10)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-pro")?.monthlyCreditsUSD == 30)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-max")?.monthlyCreditsUSD == 150)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-ultra")?.monthlyCreditsUSD == 300)
        #expect(CommandCodePlanCatalog.plan(forID: "unknown") == nil)
    }

    @Test
    func `cookie header extracts secure session cookie`() throws {
        let raw = "_ga=GA1.2.123; __Secure-better-auth.session_token=abc123; foo=bar"
        let override = try #require(CommandCodeCookieHeader.override(from: raw))
        #expect(override.name == "__Secure-better-auth.session_token")
        #expect(override.token == "abc123")
        #expect(override.headerValue == "__Secure-better-auth.session_token=abc123")
    }

    @Test
    func `cookie header accepts non-secure variant`() throws {
        let raw = "better-auth.session_token=plain-token"
        let override = try #require(CommandCodeCookieHeader.override(from: raw))
        #expect(override.name == "better-auth.session_token")
        #expect(override.token == "plain-token")
    }

    @Test
    func `cookie header accepts bare token and uses secure name`() throws {
        let override = try #require(CommandCodeCookieHeader.override(from: "bare-value"))
        #expect(override.name == "__Secure-better-auth.session_token")
        #expect(override.token == "bare-value")
    }

    @Test
    func `cookie header rejects empty input`() {
        #expect(CommandCodeCookieHeader.override(from: nil) == nil)
        #expect(CommandCodeCookieHeader.override(from: "") == nil)
        #expect(CommandCodeCookieHeader.override(from: "   ") == nil)
    }
}
