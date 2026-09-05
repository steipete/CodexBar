import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Command Code sizes its monthly grant from the optional `/internal/billing/subscriptions`
/// lookup, which loses its bounded join grace several times a day. These tests pin how a
/// remembered plan sizes the monthly lane from the fresh credits response, and every case where
/// the remembered plan must not apply.
struct CommandCodePlanCacheTests {
    /// $10 Go plan with $4 left, so the monthly lane must read 60% used.
    private static let spentCreditsJSON = """
    {"credits":{"monthlyCredits":4,"purchasedCredits":0,"premiumMonthlyCredits":0,\
    "opensourceMonthlyCredits":4}}
    """

    /// $10 Go plan with $9 left, so the monthly lane must read 10% used.
    private static let freshCreditsJSON = """
    {"credits":{"monthlyCredits":9,"purchasedCredits":0,"premiumMonthlyCredits":0,\
    "opensourceMonthlyCredits":9}}
    """

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let periodEnd = Date(timeIntervalSince1970: 4_000_000_000)

    private static let activeSubscriptionJSON = """
    {"success":true,"data":{"id":"sub_1","status":"active","planId":"individual-go",\
    "currentPeriodEnd":"2096-10-02T07:06:40.000Z"}}
    """

    private static let undatedSubscriptionJSON = """
    {"success":true,"data":{"id":"sub_1","status":"active","planId":"individual-go"}}
    """

    private static let unknownPlanJSON = """
    {"success":true,"data":{"id":"sub_1","status":"active","planId":"individual-unreleased",\
    "currentPeriodEnd":"2096-10-02T07:06:40.000Z"}}
    """

    private static let freeTierJSON = #"{"success":true,"data":null}"#

    @Test
    func `remembered plan sizes the monthly lane from fresh credits after a failure`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let resolved = try await Self.fetch(
                credits: Self.freshCreditsJSON,
                subscription: Self.activeSubscriptionJSON)
            #expect(resolved.toUsageSnapshot().tertiary?.usedPercent == 10)

            let repaired = try await Self.fetch(
                credits: Self.spentCreditsJSON,
                subscription: nil)

            // The grant size is remembered; the percentage still comes from this refresh.
            #expect(repaired.subscriptionEnrichmentUnavailable)
            #expect(repaired.plan?.id == "individual-go")
            #expect(repaired.toUsageSnapshot().tertiary?.usedPercent == 60)
            #expect(repaired.toUsageSnapshot().tertiary?.resetsAt == Self.periodEnd)
            // Only the grant size is remembered, never the observed subscription state.
            #expect(repaired.subscriptionStatus == nil)
        }
    }

    @Test
    func `remembered plan stops applying once its billing period ends`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            _ = try await Self.fetch(
                credits: Self.freshCreditsJSON,
                subscription: Self.activeSubscriptionJSON)

            let afterPeriod = try await Self.fetch(
                credits: Self.spentCreditsJSON,
                subscription: nil,
                now: Self.periodEnd.addingTimeInterval(1))

            #expect(afterPeriod.plan == nil)
            #expect(afterPeriod.toUsageSnapshot().tertiary == nil)
        }
    }

    @Test
    func `remembered plan expires without a refresh that confirms it`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            _ = try await Self.fetch(
                credits: Self.freshCreditsJSON,
                subscription: Self.activeSubscriptionJSON)

            // Bounds retention after the credential goes away, well inside the billing period.
            let aDayLater = try await Self.fetch(
                credits: Self.spentCreditsJSON,
                subscription: nil,
                now: Self.now.addingTimeInterval(25 * 60 * 60))

            #expect(aDayLater.plan == nil)
            #expect(aDayLater.toUsageSnapshot().tertiary == nil)
        }
    }

    @Test
    func `remembered plan never sizes another credential`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            _ = try await Self.fetch(
                credits: Self.freshCreditsJSON,
                subscription: Self.activeSubscriptionJSON,
                cookieHeader: "session=first")

            let other = try await Self.fetch(
                credits: Self.spentCreditsJSON,
                subscription: nil,
                cookieHeader: "session=second")

            #expect(other.plan == nil)
            #expect(other.toUsageSnapshot().tertiary == nil)
        }
    }

    @Test
    func `verified free tier forgets the remembered plan`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            _ = try await Self.fetch(
                credits: Self.freshCreditsJSON,
                subscription: Self.activeSubscriptionJSON)
            _ = try await Self.fetch(
                credits: Self.freshCreditsJSON,
                subscription: Self.freeTierJSON)

            let afterDowngrade = try await Self.fetch(
                credits: Self.spentCreditsJSON,
                subscription: nil)

            #expect(afterDowngrade.plan == nil)
            #expect(afterDowngrade.toUsageSnapshot().tertiary == nil)
        }
    }

    @Test
    func `a plan id this build cannot size forgets the remembered plan`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            _ = try await Self.fetch(
                credits: Self.freshCreditsJSON,
                subscription: Self.activeSubscriptionJSON)

            await #expect(throws: CommandCodeUsageError.self) {
                _ = try await Self.fetch(
                    credits: Self.freshCreditsJSON,
                    subscription: Self.unknownPlanJSON)
            }

            // The rejected answer proves the remembered grant is superseded.
            let afterRename = try await Self.fetch(
                credits: Self.spentCreditsJSON,
                subscription: nil)

            #expect(afterRename.plan == nil)
            #expect(afterRename.toUsageSnapshot().tertiary == nil)
        }
    }

    @Test
    func `subscription without a period end is not remembered`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let undated = try await Self.fetch(
                credits: Self.freshCreditsJSON,
                subscription: Self.undatedSubscriptionJSON)
            #expect(undated.plan?.id == "individual-go")

            // An entry that cannot expire would keep sizing the lane after the grant refills.
            let repaired = try await Self.fetch(
                credits: Self.spentCreditsJSON,
                subscription: nil)

            #expect(repaired.plan == nil)
            #expect(repaired.toUsageSnapshot().tertiary == nil)
        }
    }

    /// Runs one refresh. A nil `subscription` body makes the optional lookup fail, which is what a
    /// lost join grace produces.
    private static func fetch(
        credits: String,
        subscription: String?,
        cookieHeader: String = "session=valid",
        now: Date = Self.now) async throws -> CommandCodeUsageSnapshot
    {
        let transport = ProviderHTTPTransportStub { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("/credits") {
                return try Self.response(request: request, statusCode: 200, body: credits)
            }
            guard let subscription else {
                return try Self.response(request: request, statusCode: 503, body: #"{"error":"unavailable"}"#)
            }
            return try Self.response(request: request, statusCode: 200, body: subscription)
        }
        return try await CommandCodeUsageFetcher._fetchUsageForTesting(
            cookieHeader: cookieHeader,
            transport: transport,
            now: now,
            subscriptionGrace: .seconds(5))
    }

    private static func response(
        request: URLRequest,
        statusCode: Int,
        body: String) throws -> (Data, URLResponse)
    {
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil))
        return (Data(body.utf8), response)
    }
}
