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
    func `fetch usage keeps credits when subscription endpoint fails`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            switch request.url?.path {
            case "/internal/billing/credits":
                Self.httpResponse(status: 200, body: Self.creditsJSON)
            case "/internal/billing/subscriptions":
                Self.httpResponse(status: 503, body: #"{"error":"temporarily unavailable"}"#)
            default:
                Self.httpResponse(status: 404, body: "{}")
            }
        }

        let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
            cookieHeader: "__Secure-better-auth.session_token=test",
            session: transport,
            now: Date(timeIntervalSince1970: 0))

        #expect(snapshot.monthlyCreditsRemaining == 8.7784)
        #expect(snapshot.plan == nil)
        #expect(snapshot.billingPeriodEnd == nil)
        #expect(snapshot.subscriptionStatus == nil)
    }

    @Test
    func `fetch usage does not wait for slow subscription endpoint`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let response: (Data, URLResponse)
            switch request.url?.path {
            case "/internal/billing/credits":
                response = Self.httpResponse(status: 200, body: Self.creditsJSON)
            case "/internal/billing/subscriptions":
                try await Task.sleep(nanoseconds: 500_000_000)
                response = Self.httpResponse(status: 200, body: Self.subscriptionJSON)
            default:
                response = Self.httpResponse(status: 404, body: "{}")
            }
            return response
        }
        let start = Date()

        let snapshot = try await CommandCodeUsageFetcher.fetchUsageForTesting(
            cookieHeader: "__Secure-better-auth.session_token=test",
            session: transport,
            now: Date(timeIntervalSince1970: 0),
            subscriptionGraceSeconds: 0.05)

        #expect(Date().timeIntervalSince(start) < 0.4)
        #expect(snapshot.monthlyCreditsRemaining == 8.7784)
        #expect(snapshot.plan == nil)
        #expect(snapshot.billingPeriodEnd == nil)
    }

    @Test
    func `fetch usage treats nonfinite subscription grace as zero`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            switch request.url?.path {
            case "/internal/billing/credits":
                return Self.httpResponse(status: 200, body: Self.creditsJSON)
            case "/internal/billing/subscriptions":
                try await Task.sleep(nanoseconds: 500_000_000)
                return Self.httpResponse(status: 200, body: Self.subscriptionJSON)
            default:
                return Self.httpResponse(status: 404, body: "{}")
            }
        }
        let start = Date()

        let snapshot = try await CommandCodeUsageFetcher.fetchUsageForTesting(
            cookieHeader: "__Secure-better-auth.session_token=test",
            session: transport,
            now: Date(timeIntervalSince1970: 0),
            subscriptionGraceSeconds: .infinity)

        #expect(Date().timeIntervalSince(start) < 0.4)
        #expect(snapshot.monthlyCreditsRemaining == 8.7784)
        #expect(snapshot.plan == nil)
    }

    @Test
    func `fetch usage includes subscription when it finishes before credits`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            switch request.url?.path {
            case "/internal/billing/credits":
                try await Task.sleep(nanoseconds: 50_000_000)
                return Self.httpResponse(status: 200, body: Self.creditsJSON)
            case "/internal/billing/subscriptions":
                return Self.httpResponse(status: 200, body: Self.subscriptionJSON)
            default:
                return Self.httpResponse(status: 404, body: "{}")
            }
        }

        let snapshot = try await CommandCodeUsageFetcher.fetchUsageForTesting(
            cookieHeader: "__Secure-better-auth.session_token=test",
            session: transport,
            now: Date(timeIntervalSince1970: 0),
            subscriptionGraceSeconds: 0.05)

        #expect(snapshot.monthlyCreditsRemaining == 8.7784)
        #expect(snapshot.plan?.displayName == "Go")
        #expect(snapshot.subscriptionStatus == "active")
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(snapshot.billingPeriodEnd == isoFormatter.date(from: "2026-06-06T07:28:50.000Z"))
    }

    @Test
    func `fetch usage still fails when credits endpoint fails`() async {
        let transport = ProviderHTTPTransportStub { request in
            switch request.url?.path {
            case "/internal/billing/credits":
                Self.httpResponse(status: 503, body: #"{"error":"temporarily unavailable"}"#)
            case "/internal/billing/subscriptions":
                Self.httpResponse(status: 200, body: Self.subscriptionJSON)
            default:
                Self.httpResponse(status: 404, body: "{}")
            }
        }

        await #expect(throws: CommandCodeUsageError.apiError(503)) {
            try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "__Secure-better-auth.session_token=test",
                session: transport,
                now: Date(timeIntervalSince1970: 0))
        }
    }

    @Test
    func `fetch usage still fails for unknown active subscription plan`() async throws {
        let unknownSubscription = """
        {"success":true,"data":{"status":"active","planId":"individual-mystery"}}
        """
        let transport = ProviderHTTPTransportStub { request in
            switch request.url?.path {
            case "/internal/billing/credits":
                Self.httpResponse(status: 200, body: Self.creditsJSON)
            case "/internal/billing/subscriptions":
                Self.httpResponse(status: 200, body: unknownSubscription)
            default:
                Self.httpResponse(status: 404, body: "{}")
            }
        }

        await #expect(throws: CommandCodeUsageError.unknownPlan("individual-mystery")) {
            try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "__Secure-better-auth.session_token=test",
                session: transport,
                now: Date(timeIntervalSince1970: 0))
        }
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

    private static func httpResponse(status: Int, body: String) -> (Data, URLResponse) {
        let url = URL(string: "https://api.commandcode.ai/test")!
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
