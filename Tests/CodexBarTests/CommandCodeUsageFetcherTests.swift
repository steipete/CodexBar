import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tests for `CommandCodeUsageFetcher` parsers and the cookie/snapshot derivation,
/// using real responses captured from api.commandcode.ai for an active "individual-go" plan.
struct CommandCodeUsageFetcherTests {
    private static func creditsFixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Providers/CommandCode")))
    }

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
    func `parses rolling windows at response root`() throws {
        let payload = try CommandCodeUsageFetcher.parseCredits(
            data: Self.creditsFixture("window-limits-root"))

        #expect(payload.monthlyCredits == 8.5)
        let fiveHour = try #require(payload.fiveHourWindow)
        #expect(fiveHour.usedPercent == 25)
        #expect(fiveHour.windowMinutes == 5 * 60)
        #expect(fiveHour.resetsAt == Date(timeIntervalSince1970: 1_780_000_000))
        let weekly = try #require(payload.weeklyWindow)
        #expect(weekly.usedPercent == 10)
        #expect(weekly.windowMinutes == 7 * 24 * 60)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_780_100_000))
    }

    @Test
    func `parses rolling windows nested in credits`() throws {
        let payload = try CommandCodeUsageFetcher.parseCredits(
            data: Self.creditsFixture("window-limits-nested"))

        #expect(payload.monthlyCredits == 7.25)
        let fiveHour = try #require(payload.fiveHourWindow)
        #expect(fiveHour.usedPercent == 25)
        #expect(fiveHour.resetsAt == Date(timeIntervalSince1970: 1_780_200_000))
        let weekly = try #require(payload.weeklyWindow)
        #expect(weekly.usedPercent == 20)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_780_300_000))
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
    func `successful free tier lookup has no usage window`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                let body = if path.hasSuffix("/credits") {
                    """
                    {"credits":{"monthlyCredits":0,"purchasedCredits":0,
                    "premiumMonthlyCredits":0,"opensourceMonthlyCredits":0}}
                    """
                } else {
                    #"{"success":true,"data":null}"#
                }
                return try Self.response(request: request, statusCode: 200, body: body)
            }

            let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport)

            #expect(snapshot.subscriptionEnrichmentUnavailable == false)
            #expect(snapshot.toUsageSnapshot().primary == nil)
        }
    }

    @Test
    func `subscription failure envelope preserves required credits`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                if path.hasSuffix("/credits") {
                    return try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
                }
                return try Self.response(
                    request: request,
                    statusCode: 200,
                    body: #"{"success":false,"error":"temporarily unavailable"}"#)
            }

            let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport,
                now: Date(timeIntervalSince1970: 123))

            #expect(snapshot.monthlyCreditsRemaining == 8.7784)
            #expect(snapshot.plan == nil)
            #expect(snapshot.subscriptionEnrichmentUnavailable)
            #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 123))
        }
    }

    @Test
    func `successful subscription envelope requires explicit data`() throws {
        let data = Data(#"{"success":true}"#.utf8)

        #expect(throws: CommandCodeUsageError.self) {
            try CommandCodeUsageFetcher.parseSubscription(data: data)
        }
    }

    @Test
    func `subscription failure preserves required credits`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                if path.hasSuffix("/credits") {
                    return try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
                }
                return try Self.response(request: request, statusCode: 503, body: #"{"error":"unavailable"}"#)
            }

            let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport,
                now: Date(timeIntervalSince1970: 123))

            #expect(snapshot.monthlyCreditsRemaining == 8.7784)
            #expect(snapshot.plan == nil)
            #expect(snapshot.billingPeriodEnd == nil)
            #expect(snapshot.subscriptionEnrichmentUnavailable)
            #expect(snapshot.updatedAt == Date(timeIntervalSince1970: 123))
        }
    }

    @Test
    func `subscription timeout does not hold credits for full request timeout`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                if path.hasSuffix("/credits") {
                    return try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
                }
                try await Task.sleep(for: .seconds(10))
                return try Self.response(request: request, statusCode: 200, body: Self.subscriptionJSON)
            }

            let startedAt = ContinuousClock.now
            let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport)
            let elapsed = startedAt.duration(to: .now)

            #expect(snapshot.monthlyCreditsRemaining == 8.7784)
            #expect(snapshot.plan == nil)
            #expect(snapshot.subscriptionEnrichmentUnavailable)
            #expect(elapsed < .seconds(3), "Subscription enrichment delayed credits: \(elapsed)")
        }
    }

    @Test
    func `subscription grace does not wait for transport that ignores cancellation`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                if path.hasSuffix("/credits") {
                    return try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
                }
                let response = try Self.response(request: request, statusCode: 200, body: Self.subscriptionJSON)
                return await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume(returning: response)
                    }
                }
            }

            let startedAt = ContinuousClock.now
            let snapshot = try await CommandCodeUsageFetcher._fetchUsageForTesting(
                cookieHeader: "session=valid",
                transport: transport,
                subscriptionGrace: .milliseconds(20))
            let elapsed = startedAt.duration(to: .now)

            #expect(snapshot.monthlyCreditsRemaining == 8.7784)
            #expect(snapshot.plan == nil)
            #expect(snapshot.subscriptionEnrichmentUnavailable)
            #expect(elapsed < .milliseconds(300), "Subscription enrichment delayed credits: \(elapsed)")

            // Let the deliberately cancellation-ignoring test task drain before the test exits.
            try await Task.sleep(for: .milliseconds(550))
        }
    }

    @Test
    func `cancellation after credits complete does not return partial snapshot`() async throws {
        let subscriptionStarted = CommandCodeRequestGate()
        let transport = ProviderHTTPTransportStub { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("/credits") {
                return try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
            }
            await subscriptionStarted.open()
            try await Task.sleep(for: .seconds(10))
            return try Self.response(request: request, statusCode: 200, body: Self.subscriptionJSON)
        }
        let task = Task {
            try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport)
        }

        await subscriptionStarted.wait()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func `cancellation cleans up subscription when credits transport ignores cancellation`() async throws {
        let creditsStarted = CommandCodeRequestGate()
        let subscriptionStarted = CommandCodeRequestGate()
        let subscriptionCancelled = CommandCodeRequestGate()
        let transport = ProviderHTTPTransportStub { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("/credits") {
                await creditsStarted.open()
                let response = try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
                return await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume(returning: response)
                    }
                }
            }
            await subscriptionStarted.open()
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                await subscriptionCancelled.open()
                throw error
            }
            return try Self.response(request: request, statusCode: 200, body: Self.subscriptionJSON)
        }
        let task = Task {
            try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport)
        }

        await creditsStarted.wait()
        await subscriptionStarted.wait()
        let cancellationStartedAt = ContinuousClock.now
        task.cancel()

        await subscriptionCancelled.wait()
        #expect(cancellationStartedAt.duration(to: .now) < .milliseconds(300))
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func `cancellation wins when optional transport ignores cancellation then fails`() async throws {
        let subscriptionStarted = CommandCodeRequestGate()
        let transport = ProviderHTTPTransportStub { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("/credits") {
                return try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
            }
            await subscriptionStarted.open()
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                // Simulate a transport that converts cancellation into an ordinary endpoint failure.
            }
            return try Self.response(request: request, statusCode: 503, body: #"{"error":"unavailable"}"#)
        }
        let task = Task {
            try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport)
        }

        await subscriptionStarted.wait()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func `successful unknown active subscription still fails explicitly`() async {
        await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let unknownPlanJSON = Self.subscriptionJSON.replacingOccurrences(
                of: #""planId":"individual-go""#,
                with: #""planId":"individual-future""#)
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                let body = path.hasSuffix("/credits") ? Self.creditsJSON : unknownPlanJSON
                return try Self.response(request: request, statusCode: 200, body: body)
            }

            await #expect(throws: CommandCodeUsageError.unknownPlan("individual-future")) {
                try await CommandCodeUsageFetcher.fetchUsage(
                    cookieHeader: "session=valid",
                    session: transport)
            }
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
            fiveHourWindow: RateWindow(
                usedPercent: 25,
                windowMinutes: 5 * 60,
                resetsAt: Date(timeIntervalSince1970: 1_779_000_000),
                resetDescription: nil),
            weeklyWindow: RateWindow(
                usedPercent: 10,
                windowMinutes: 7 * 24 * 60,
                resetsAt: Date(timeIntervalSince1970: 1_779_500_000),
                resetDescription: nil),
            plan: plan,
            billingPeriodEnd: Date(timeIntervalSince1970: 1_780_000_000),
            subscriptionStatus: "active",
            updatedAt: Date(timeIntervalSince1970: 0))
        #expect(snapshot.monthlyCreditsTotal == 10)
        #expect(abs((snapshot.monthlyCreditsUsed ?? -1) - 1.2216) < 0.0001)

        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.secondary?.usedPercent == 10)
        let monthly = try #require(usage.tertiary)
        #expect(abs(monthly.usedPercent - 12.216) < 0.001)
        #expect(monthly.windowMinutes == ProviderPaceCapability.monthlyWindowSentinelMinutes)
        #expect(monthly.resetsAt == Date(timeIntervalSince1970: 1_780_000_000))
        #expect(usage.identity?.loginMethod == "Go · $1.22 of $10.00")
    }

    @Test
    func `free tier with no allowance has no usage window`() {
        let snapshot = CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 0,
            purchasedCredits: 0,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            plan: nil,
            billingPeriodEnd: nil,
            subscriptionStatus: nil)

        #expect(snapshot.toUsageSnapshot().tertiary == nil)
    }

    @Test
    func `active pro-v1 subscription resolves to the eighty dollar plan`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let proV1JSON = Self.subscriptionJSON.replacingOccurrences(
                of: #""planId":"individual-go""#,
                with: #""planId":"individual-pro-v1""#)
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                let body = path.hasSuffix("/credits") ? Self.creditsJSON : proV1JSON
                return try Self.response(request: request, statusCode: 200, body: body)
            }

            let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport)

            let plan = try #require(snapshot.plan)
            #expect(plan.id == "individual-pro-v1")
            #expect(plan.monthlyCreditsUSD == 80)
            #expect(snapshot.monthlyCreditsTotal == 80)
            #expect(abs((snapshot.monthlyCreditsUsed ?? -1) - 71.2216) < 0.0001)
            #expect(snapshot.subscriptionEnrichmentUnavailable == false)
        }
    }

    @Test
    func `plan catalog covers known plans`() {
        #expect(CommandCodePlanCatalog.plan(forID: "individual-go")?.monthlyCreditsUSD == 10)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-goat")?.monthlyCreditsUSD == 70)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-pro")?.monthlyCreditsUSD == 30)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-pro-v1")?.monthlyCreditsUSD == 80)
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
    func `cookie header extracts renamed commandcode session cookie`() throws {
        let raw = "_ga=GA1.2.123; __Secure-commandcode_prod_.session_token=abc123; foo=bar"
        let override = try #require(CommandCodeCookieHeader.override(from: raw))
        #expect(override.name == "__Secure-commandcode_prod_.session_token")
        #expect(override.token == "abc123")
        #expect(override.headerValue == "__Secure-commandcode_prod_.session_token=abc123")
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

    @Test
    func `subscription failure leaves the projected monthly window unavailable`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                if path.hasSuffix("/credits") {
                    return try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
                }
                return try Self.response(request: request, statusCode: 503, body: #"{"error":"unavailable"}"#)
            }

            let snapshot = try await CommandCodeUsageFetcher._fetchUsageForTesting(
                cookieHeader: "session=valid",
                transport: transport,
                subscriptionGrace: .seconds(5))

            // An unknown grant size must not borrow the free-tier reading: that renders an untouched
            // monthly bar for a plan that is partly spent.
            #expect(snapshot.toUsageSnapshot().tertiary == nil)
            #expect(snapshot.monthlyCreditsRemaining == 8.7784)
        }
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

private actor CommandCodeRequestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }

    func open() {
        self.isOpen = true
        let continuations = self.continuations
        self.continuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
