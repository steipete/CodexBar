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
        let subscriptionStarted = HeldRequestGate()
        let subscriptionCancelled = HeldRequestGate()
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                if path.hasSuffix("/credits") {
                    await subscriptionStarted.wait()
                    return try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
                }
                await subscriptionStarted.open()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    await subscriptionCancelled.open()
                    throw error
                }
                return try Self.response(request: request, statusCode: 200, body: Self.subscriptionJSON)
            }

            let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport)

            #expect(snapshot.monthlyCreditsRemaining == 8.7784)
            #expect(snapshot.plan == nil)
            #expect(snapshot.subscriptionEnrichmentUnavailable)
            await subscriptionCancelled.wait()
        }
    }

    @Test
    func `subscription grace does not wait for transport that ignores cancellation`() async throws {
        let subscriptionStarted = HeldRequestGate()
        let releaseSubscription = HeldRequestGate()
        let subscriptionFinished = HeldRequestGate()
        defer { Task { await releaseSubscription.open() } }
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                if path.hasSuffix("/credits") {
                    await subscriptionStarted.wait()
                    return try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
                }
                let response = try Self.response(request: request, statusCode: 200, body: Self.subscriptionJSON)
                await subscriptionStarted.open()
                await releaseSubscription.wait()
                await subscriptionFinished.open()
                return response
            }

            let snapshot = try await CommandCodeUsageFetcher._fetchUsageForTesting(
                cookieHeader: "session=valid",
                transport: transport,
                subscriptionGrace: .milliseconds(20))

            #expect(snapshot.monthlyCreditsRemaining == 8.7784)
            #expect(snapshot.plan == nil)
            #expect(snapshot.subscriptionEnrichmentUnavailable)
            #expect(await releaseSubscription.isOpen == false)
            await releaseSubscription.open()
            await subscriptionFinished.wait()
        }
    }

    @Test
    func `cancellation after credits complete does not return partial snapshot`() async throws {
        let subscriptionStarted = HeldRequestGate()
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
        let releaseCredits = HeldRequestGate()
        defer { Task { await releaseCredits.open() } }
        let creditsStarted = HeldRequestGate()
        let subscriptionStarted = HeldRequestGate()
        let subscriptionCancelled = HeldRequestGate()
        let transport = ProviderHTTPTransportStub { request in
            let path = try #require(request.url?.path)
            if path.hasSuffix("/credits") {
                await creditsStarted.open()
                let response = try Self.response(request: request, statusCode: 200, body: Self.creditsJSON)
                await releaseCredits.wait()
                return response
            }
            await subscriptionStarted.open()
            do {
                try await Task.sleep(for: .seconds(60))
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
        task.cancel()

        await subscriptionCancelled.wait()
        #expect(await releaseCredits.isOpen == false)
        await releaseCredits.open()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func `cancellation wins when optional transport ignores cancellation then fails`() async throws {
        let subscriptionStarted = HeldRequestGate()
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
    func `unknown subscription preserves API usage and its plan label`() async throws {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                let body = path.hasSuffix("/credits")
                    ? #"""
                    {"credits":{"monthlyCredits":8,"monthlyCreditsGranted":20},
                    "windowLimits":{"fiveHour":{"used":1,"cap":4}}}
                    """#
                    : #"{"success":true,"data":{"status":"active","planId":"individual-future"}}"#
                return try Self.response(request: request, statusCode: 200, body: body)
            }
            let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=synthetic", session: transport)
            #expect(snapshot.toUsageSnapshot().primary?.usedPercent == 25)
            #expect(snapshot.monthlyCreditsRemaining == 8)
            #expect(snapshot.monthlyCreditsUsed == 12)
            #expect(snapshot.toUsageSnapshot().tertiary?.usedPercent == 60)
            #expect(snapshot.toUsageSnapshot().identity?.loginMethod == "individual-future · $12.00 of $20.00")

            let unsizedTransport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                let body = path.hasSuffix("/credits") ? Self.creditsJSON
                    : #"{"success":true,"data":{"status":"active","planId":"individual-future"}}"#
                return try Self.response(request: request, statusCode: 200, body: body)
            }
            let unsized = try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=synthetic", session: unsizedTransport)
            #expect(unsized.monthlyCreditsTotal == nil)
            #expect(unsized.toUsageSnapshot().tertiary == nil)
            #expect(unsized.toUsageSnapshot().identity?.loginMethod == "individual-future · $8.78 remaining")
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

    @Test(arguments: ["individual-pro-v1", "individual-go-v1"])
    func `versioned subscriptions resolve to their published grants`(planID: String) async throws {
        let expectedGrant = planID == "individual-pro-v1" ? 80.0 : 10.0
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let versionedJSON = Self.subscriptionJSON.replacingOccurrences(
                of: #""planId":"individual-go""#,
                with: "\"planId\":\"\(planID)\"")
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                let body = path.hasSuffix("/credits") ? Self.creditsJSON : versionedJSON
                return try Self.response(request: request, statusCode: 200, body: body)
            }

            let snapshot = try await CommandCodeUsageFetcher.fetchUsage(
                cookieHeader: "session=valid",
                session: transport)

            let plan = try #require(snapshot.plan)
            #expect(plan.id == planID)
            #expect(plan.monthlyCreditsUSD == expectedGrant)
            #expect(snapshot.monthlyCreditsTotal == expectedGrant)
            #expect(abs((snapshot.monthlyCreditsUsed ?? -1) - (expectedGrant - 8.7784)) < 0.0001)
            #expect(snapshot.subscriptionEnrichmentUnavailable == false)
        }
    }

    @Test
    func `credit labels retain their currency precision`() {
        #expect(CommandCodeUsageSnapshot.formatUSD(8.7784) == "$8.78")
        #expect(CommandCodeUsageSnapshot.formatUSD(150.75) == "$151")
    }

    @Test
    func `plan catalog covers known plans`() {
        #expect(CommandCodePlanCatalog.plan(forID: "individual-go")?.monthlyCreditsUSD == 10)
        #expect(CommandCodePlanCatalog.plan(forID: "individual-go-v1")?.monthlyCreditsUSD == 10)
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
    func `cookie header accepts bare token and uses production name`() throws {
        let override = try #require(CommandCodeCookieHeader.override(from: "bare-value"))
        #expect(override.name == "__Secure-commandcode_prod_.session_token")
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

    @Test
    func `parses granted monthly credits`() throws {
        let data = Data("""
        {"credits":{"monthlyCredits":4,"purchasedCredits":0,"premiumMonthlyCredits":0,
        "opensourceMonthlyCredits":4,"monthlyCreditsGranted":10}}
        """.utf8)
        let payload = try CommandCodeUsageFetcher.parseCredits(data: data)
        #expect(payload.monthlyCreditsGranted == 10)

        let legacy = try CommandCodeUsageFetcher.parseCredits(data: #require(Self.creditsJSON.data(using: .utf8)))
        #expect(legacy.monthlyCreditsGranted == nil)
    }

    @Test(arguments: [(4.0, 60.0), (0.0, 100.0)])
    func `subscription failure in a fresh process sizes the monthly window from granted credits`(
        remaining: Double,
        usedPercent: Double) async throws
    {
        try await CommandCodeUsageFetcher.withIsolatedPlanCacheForTesting {
            let transport = ProviderHTTPTransportStub { request in
                let path = try #require(request.url?.path)
                if path.hasSuffix("/credits") {
                    let body = """
                    {"credits":{"monthlyCredits":\(remaining),"purchasedCredits":0,"premiumMonthlyCredits":0,
                    "opensourceMonthlyCredits":\(remaining),"monthlyCreditsGranted":10},
                    "windowLimits":{"fiveHour":{"used":2.5,"cap":10,"resetAt":0},
                    "weekly":{"used":30,"cap":100,"resetAt":0}}}
                    """
                    return try Self.response(request: request, statusCode: 200, body: body)
                }
                return try Self.response(request: request, statusCode: 503, body: #"{"error":"unavailable"}"#)
            }

            let snapshot = try await CommandCodeUsageFetcher._fetchUsageForTesting(
                cookieHeader: "session=valid",
                transport: transport,
                subscriptionGrace: .seconds(5))

            #expect(snapshot.subscriptionEnrichmentUnavailable)
            #expect(snapshot.plan == nil)
            let usage = snapshot.toUsageSnapshot()
            let monthly = try #require(usage.tertiary)
            #expect(abs(monthly.usedPercent - usedPercent) < 0.0001)
            // The billing period end only comes from the subscription lookup.
            #expect(monthly.resetsAt == nil)
            #expect(usage.primary?.usedPercent == 25)
            #expect(usage.secondary?.usedPercent == 30)
        }
    }

    @Test
    func `granted credits size the monthly window over the plan catalog`() throws {
        let plan = try #require(CommandCodePlanCatalog.plan(forID: "individual-go"))
        let snapshot = CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 9,
            purchasedCredits: 0,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 9,
            monthlyCreditsGranted: 12,
            plan: plan,
            billingPeriodEnd: nil,
            subscriptionStatus: "active")

        #expect(snapshot.monthlyCreditsTotal == 12)
        let monthly = try #require(snapshot.toUsageSnapshot().tertiary)
        #expect(abs(monthly.usedPercent - 25) < 0.0001)
        #expect(snapshot.toUsageSnapshot().identity?.loginMethod == "Go · $3.00 of $12.00")
    }

    @Test(arguments: [0.0, -5.0, Double.infinity])
    func `unusable granted credits keep the free tier reading`(granted: Double) throws {
        let snapshot = CommandCodeUsageSnapshot(
            monthlyCreditsRemaining: 0,
            purchasedCredits: 5,
            premiumMonthlyCredits: 0,
            opensourceMonthlyCredits: 0,
            monthlyCreditsGranted: granted,
            plan: nil,
            billingPeriodEnd: nil,
            subscriptionStatus: nil)

        #expect(snapshot.monthlyCreditsTotal == nil)
        let monthly = try #require(snapshot.toUsageSnapshot().tertiary)
        #expect(monthly.usedPercent == 0)
    }

    @Test
    func `endpoint override is limited to debug loopback origins`() throws {
        let key = "COMMANDCODE_API_URL"
        let production = try #require(URL(string: "https://api.commandcode.ai"))
        #expect(CommandCodeUsageFetcher.apiBase(environment: [:]) == production)
        for raw in ["http://127.0.0.1:8080", "http://[::1]:8080", "https://localhost:8080/"] {
            let loopback = try #require(URL(string: raw))
            #if DEBUG
            #expect(CommandCodeUsageFetcher.apiBase(environment: [key: raw]) == loopback)
            #else
            #expect(CommandCodeUsageFetcher.apiBase(environment: [key: raw]) == production)
            #endif
        }
        for raw in [
            "https://billing.test", "http://billing.test", "http://localhost:8080/path",
            "http://localhost:8080?test=1", "http://localhost:8080#fragment", "http://user@localhost:8080",
        ] {
            #expect(CommandCodeUsageFetcher.apiBase(environment: [key: raw]) == production)
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
