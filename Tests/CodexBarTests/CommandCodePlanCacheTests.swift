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
    func `older successful and undated responses cannot replace a newer allowance`() async throws {
        let cache = CommandCodePlanCache()
        let go = try #require(CommandCodePlanCatalog.plan(forID: "individual-go"))
        let pro = try #require(CommandCodePlanCatalog.plan(forID: "individual-pro"))
        let newer = Self.now.addingTimeInterval(1)
        await cache.store(plan: pro, periodEnd: Self.periodEnd, fingerprint: "account", now: newer)
        await cache.store(plan: go, periodEnd: Self.periodEnd, fingerprint: "account", now: Self.now)
        #expect(await cache.entry(fingerprint: "account", now: newer)?.plan == pro)
        await cache.store(plan: go, periodEnd: nil, fingerprint: "account", now: Self.now)
        #expect(await cache.entry(fingerprint: "account", now: newer)?.plan == pro)
        await cache.clear(fingerprint: "account", now: Self.now)
        #expect(await cache.entry(fingerprint: "account", now: newer)?.plan == pro)
    }

    @Test
    func `older responses cannot resurrect a plan after a newer cleared verdict`() async throws {
        let plan = try #require(CommandCodePlanCatalog.plan(forID: "individual-go"))
        let newer = Self.now.addingTimeInterval(1)
        for undated in [false, true] {
            let cache = CommandCodePlanCache()
            if undated {
                await cache.store(plan: plan, periodEnd: nil, fingerprint: "account", now: newer)
            } else {
                await cache.clear(fingerprint: "account", now: newer)
            }
            await cache.store(plan: plan, periodEnd: Self.periodEnd, fingerprint: "account", now: Self.now)
            #expect(await cache.entry(fingerprint: "account", now: newer) == nil)
            await cache.store(
                plan: plan, periodEnd: Self.periodEnd, fingerprint: "account", now: newer.addingTimeInterval(1))
            #expect(await cache.entry(fingerprint: "account", now: newer.addingTimeInterval(1))?.plan == plan)
        }
    }

    @Test
    func `allowance expires at the exact period and confirmation boundaries`() async throws {
        let cache = CommandCodePlanCache()
        let plan = try #require(CommandCodePlanCatalog.plan(forID: "individual-go"))
        let end = Self.now.addingTimeInterval(60)
        await cache.store(plan: plan, periodEnd: end, fingerprint: "period", now: Self.now)
        #expect(await cache.entry(fingerprint: "period", now: end.addingTimeInterval(-1)) != nil)
        #expect(await cache.entry(fingerprint: "period", now: end) == nil)
        await cache.store(plan: plan, periodEnd: Self.periodEnd, fingerprint: "age", now: Self.now)
        #expect(await cache.entry(fingerprint: "age", now: Self.now.addingTimeInterval(86400 - 1)) != nil)
        #expect(await cache.entry(fingerprint: "age", now: Self.now.addingTimeInterval(86400)) == nil)
    }

    @Test
    func `cleared verdicts share the bounded credential capacity`() async throws {
        let cache = CommandCodePlanCache()
        let plan = try #require(CommandCodePlanCatalog.plan(forID: "individual-go"))
        for index in 0..<4 {
            await cache.store(
                plan: plan,
                periodEnd: Self.periodEnd,
                fingerprint: "account-\(index)",
                now: Self.now.addingTimeInterval(Double(index)))
        }
        let latest = Self.now.addingTimeInterval(4)
        await cache.clear(fingerprint: "account-4", now: latest)
        #expect(await cache.entry(fingerprint: "account-0", now: latest) == nil)
        for index in 1..<4 {
            #expect(await cache.entry(fingerprint: "account-\(index)", now: latest)?.plan == plan)
        }
    }

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
