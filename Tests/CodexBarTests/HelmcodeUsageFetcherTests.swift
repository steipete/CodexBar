import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HelmcodeUsageFetcherTests {
    @Test
    func `real quota and credits map to monthly model windows and prepaid balance`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            creditsData: Self.creditsFixture(),
            now: now)
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.identity?.providerID == .helmcode)
        #expect(snapshot.identity?.loginMethod == "Dashboard session")
        #expect(snapshot.primary?.usedPercent == Self.glm53FlashPercent)
        #expect(snapshot.primary?.resetDescription?.contains("glm5.3-flash") == true)
        #expect(snapshot.extraRateWindows?.map(\.title) == [
            "deepseek-v4-flash",
            "glm5.2",
            "glm5.3",
            "mimo-v2.5",
            "qwen3.8-flash",
        ])
        #expect(snapshot.providerCost?.used == 12.5)
        #expect(snapshot.providerCost?.currencyCode == "EUR")
        #expect(snapshot.providerCost?.period == "Prepaid balance")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let expectedReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        #expect(snapshot.primary?.resetsAt == expectedReset)
    }

    @Test
    func `billing without premium omits rolling window tiers from other plans`() throws {
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            billingData: Self.billingFixture(),
            creditsData: nil)
        let snapshot = parsed.toUsageSnapshot()

        #expect(parsed.billing?.subscription?.premium == false)
        #expect(snapshot.primary?.resetDescription?.contains("glm5.3-flash") == true)
        #expect(snapshot.extraRateWindows?.map(\.title) == [
            "deepseek-v4-flash",
            "mimo-v2.5",
            "qwen3.8-flash",
        ])
        #expect(snapshot.extraRateWindows?.contains { $0.title == "glm5.2" } == false)
        #expect(snapshot.extraRateWindows?.contains { $0.title == "glm5.3" } == false)
    }

    @Test
    func `premium subscription keeps rolling window tiers`() throws {
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            billingData: Self.billingPremiumFixture(),
            creditsData: nil)
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.resetDescription?.contains("glm5.3-flash") == true)
        #expect(snapshot.extraRateWindows?.map(\.title) == [
            "deepseek-v4-flash",
            "glm5.2",
            "glm5.3",
            "mimo-v2.5",
            "qwen3.8-flash",
        ])
    }

    @Test
    func `billing failure keeps every quota entry`() throws {
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            billingData: nil,
            creditsData: nil)
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.resetDescription?.contains("glm5.3-flash") == true)
        #expect(snapshot.extraRateWindows?.count == 5)
    }

    @Test
    func `per model period end wins over the derived month start`() throws {
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            billingData: Self.billingPremiumFixture(),
            creditsData: nil)
        let snapshot = parsed.toUsageSnapshot()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let derivedReset = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let rollingReset = try #require(HelmcodeUsageSnapshot.parseISODate("2026-10-04T19:25:48Z"))
        #expect(rollingReset != derivedReset)
        let glm52 = try #require(snapshot.extraRateWindows?.first { $0.title == "glm5.2" }).window
        #expect(glm52.resetsAt == rollingReset)
        let glm53Flash = try #require(snapshot.primary)
        #expect(glm53Flash.resetsAt == derivedReset)
    }

    @Test
    func `rolling window entries map window hours to minutes`() throws {
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            billingData: Self.billingPremiumFixture(),
            creditsData: nil)
        let snapshot = parsed.toUsageSnapshot()

        let glm52 = try #require(snapshot.extraRateWindows?.first { $0.title == "glm5.2" })
        #expect(glm52.window.windowMinutes == 240)
        let glm53Flash = try #require(snapshot.primary)
        #expect(glm53Flash.windowMinutes == nil)
    }

    @Test
    func `credit funded tokens show in the window detail`() throws {
        let quota = #"""
        {"periodStart":"2026-09-01","models":[
          {"model":"helm-model-a","cap":1000000,"tokensUsed":250000,"creditTokens":2000},
          {"model":"helm-model-b","cap":2000000,"tokensUsed":1500000}]}
        """#
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Data(quota.utf8),
            creditsData: nil)
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary?.resetDescription?.contains("credit-funded") == false)
        let extra = try #require(snapshot.extraRateWindows?.first?.window)
        #expect(extra.resetDescription?.contains("2,000 credit-funded") == true)
    }

    @Test
    func `usage above the cap clamps to one hundred percent`() throws {
        let quota = #"""
        {"periodStart":"2026-09-01","models":[{"model":"helm-model-a","cap":1000000,"tokensUsed":1500000}]}
        """#
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Data(quota.utf8),
            creditsData: nil)
        #expect(parsed.toUsageSnapshot().primary?.usedPercent == 100)
    }

    @Test
    func `unlimited models are omitted and credits default to euros`() throws {
        let quota = #"""
        {"periodStart":"2026-09-01","models":[{"model":"helm-unlimited","cap":0,"tokensUsed":123}]}
        """#
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Data(quota.utf8),
            creditsData: Data(#"{"balanceMicros":2750000}"#.utf8))
        let snapshot = parsed.toUsageSnapshot()

        #expect(snapshot.primary == nil)
        #expect(snapshot.extraRateWindows == nil)
        #expect(snapshot.providerCost?.used == 2.75)
        #expect(snapshot.providerCost?.currencyCode == "EUR")
    }

    @Test
    func `malformed optional credits do not erase valid quota`() throws {
        let parsed = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            creditsData: Data(#"{"balanceMicros":"unknown"}"#.utf8))

        #expect(parsed.credits == nil)
        #expect(parsed.toUsageSnapshot().primary?.usedPercent == Self.glm53FlashPercent)
    }

    @Test
    func `drifted quota payload fails parsing visibly`() {
        #expect(throws: HelmcodeUsageError.self) {
            _ = try HelmcodeUsageFetcher._parseSnapshotForTesting(
                quotaData: Self.driftedQuotaFixture(),
                creditsData: nil)
        }
    }

    @Test
    func `reset date maps december to january of the next year`() {
        #expect(HelmcodeUsageSnapshot.nextMonthStart(periodStart: "2026-12-15T10:00:00Z") ==
            Self.utcDate(year: 2027, month: 1, day: 1))
        #expect(HelmcodeUsageSnapshot.nextMonthStart(periodStart: "2026-09-18T14:30:00Z") ==
            Self.utcDate(year: 2026, month: 10, day: 1))
        #expect(HelmcodeUsageSnapshot.nextMonthStart(periodStart: "2026-09-01") ==
            Self.utcDate(year: 2026, month: 10, day: 1))
    }

    @Test
    func `malformed period start yields no reset date`() {
        #expect(HelmcodeUsageSnapshot.nextMonthStart(periodStart: "not-a-date") == nil)
        #expect(HelmcodeUsageSnapshot.nextMonthStart(periodStart: "2026-13-01T00:00:00Z") == nil)
    }

    @Test(arguments: [302, 401, 403, 500])
    func `fetch sends dashboard session headers and keeps quota when credits fail`(creditsStatus: Int) async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cloud.helmcode.com")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://cloud.helmcode.com/dashboard")
            switch url.path {
            case "/api/usage/quota":
                return try Self.response(url: url, body: Self.quotaFixture())
            case "/api/billing":
                return try Self.response(url: url, body: Self.billingFixture())
            case "/api/billing/credits":
                return try Self.response(
                    url: url,
                    status: creditsStatus,
                    body: Data(#"{"error":"unavailable"}"#.utf8))
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }

        let parsed = try await HelmcodeUsageFetcher.fetchUsage(
            cookieHeader: "session=fixture",
            transport: transport)

        #expect(parsed.credits == nil)
        #expect(parsed.toUsageSnapshot().primary?.usedPercent == Self.glm53FlashPercent)
        #expect(await transport.requests().contains { $0.url?.path == "/api/billing/credits" })
    }

    @Test
    func `credits 404 means no balance for the tenant and keeps quota`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            switch url.path {
            case "/api/usage/quota":
                return try Self.response(url: url, body: Self.quotaFixture())
            case "/api/billing":
                return try Self.response(url: url, body: Self.billingFixture())
            case "/api/billing/credits":
                return try Self.response(url: url, status: 404, body: Data("404 page not found".utf8))
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }

        let parsed = try await HelmcodeUsageFetcher.fetchUsage(
            cookieHeader: "session=fixture",
            transport: transport)

        #expect(parsed.credits == nil)
        #expect(parsed.toUsageSnapshot().primary?.usedPercent == Self.glm53FlashPercent)
        #expect(await transport.requests().count == 3)
    }

    @Test
    func `rate limited quota surfaces a dedicated error`() async {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return try Self.response(url: url, status: 429, body: Data(#"{"error":"rate limited"}"#.utf8))
        }

        await #expect {
            _ = try await HelmcodeUsageFetcher.fetchUsage(cookieHeader: "session=fixture", transport: transport)
        } throws: { error in
            (error as? HelmcodeUsageError) == HelmcodeUsageError.rateLimited
        }
    }

    @Test(arguments: [302, 401, 403])
    func `fetch classifies rejected dashboard sessions`(status: Int) async {
        let transport = ProviderHTTPTransportStub { request in
            let url = request.url ?? HelmcodeUsageFetcher.quotaURL
            return try Self.response(
                url: url,
                status: status,
                body: Data(#"{"error":"unauthenticated"}"#.utf8))
        }

        await #expect(throws: HelmcodeUsageError.invalidSession(.helmcode)) {
            _ = try await HelmcodeUsageFetcher.fetchUsage(
                cookieHeader: "session=expired",
                transport: transport)
        }
    }

    @Test
    func `nan deployment fetch targets community endpoints with scoped cookies`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.host == "cloud-api.nan.builders")
            #expect(request.value(forHTTPHeaderField: "Cookie") == "session=fixture")
            #expect(request.value(forHTTPHeaderField: "Origin") == "https://cloud.nan.builders")
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://cloud.nan.builders/dashboard")
            switch url.path {
            case "/api/usage/quota":
                return try Self.response(url: url, body: Self.quotaFixture())
            case "/api/billing":
                return try Self.response(url: url, body: Self.billingFixture())
            case "/api/billing/credits":
                return try Self.response(url: url, status: 404, body: Data("404 page not found".utf8))
            default:
                Issue.record("Unexpected request path: \(url.path)")
                throw URLError(.badURL)
            }
        }

        let parsed = try await HelmcodeUsageFetcher.fetchUsage(
            cookieHeader: "session=fixture",
            deployment: .nanBuilders,
            transport: transport)

        // NaN has no prepaid balance; premium tiers not in the plan are hidden.
        #expect(parsed.credits == nil)
        #expect(parsed.toUsageSnapshot().extraRateWindows?.count == 3)
        #expect(await transport.requests().count == 3)
    }

    static let glm53FlashPercent = Double(73_854_494) / Double(2_000_000_000) * 100

    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day))!
    }

    private static func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/Providers/Helmcode"))
        return try Data(contentsOf: url)
    }

    private static func quotaFixture() throws -> Data {
        try self.fixtureData("quota")
    }

    private static func driftedQuotaFixture() throws -> Data {
        try self.fixtureData("quota-drifted")
    }

    private static func billingFixture() throws -> Data {
        try self.fixtureData("billing")
    }

    private static func billingPremiumFixture() throws -> Data {
        try self.fixtureData("billing-premium")
    }

    private static func creditsFixture() throws -> Data {
        try self.fixtureData("credits")
    }

    private static func response(url: URL, status: Int = 200, body: Data) throws -> (Data, URLResponse) {
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil))
        return (body, response)
    }
}
