import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

/// After a paid plan lapses, web `GetUsages` answers `{"totalQuota": {...}}` without any Code usage pools.
struct KimiLapsedSubscriptionTests {
    private static let now = Date(timeIntervalSince1970: 1_792_640_000)
    private static let lapsedUsageJSON = #"{"totalQuota":{"limit":"100","used":"36","remaining":"64"}}"#
    private static let statsJSON = """
    {"subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","unit":"UNIT_CREDIT",
    "amountUsedRatio":0,"expireTime":"2026-11-22T00:00:00Z"}}
    """
    private static let planJSON = """
    {"subscription":{"active":true,"status":"SUBSCRIPTION_STATUS_ACTIVE",
    "goods":{"title":"Adagio","membershipLevel":"LEVEL_FREE"}}}
    """

    private static func transport(statsJSON: String = Self.statsJSON) -> ProviderHTTPTransportHandler {
        ProviderHTTPTransportHandler { request in
            let url = try #require(request.url)
            let json = if url.path.hasSuffix("/GetUsages") {
                Self.lapsedUsageJSON
            } else if url.path.hasSuffix("/GetSubscriptionStats") {
                statsJSON
            } else {
                Self.planJSON
            }
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(json.utf8), response)
        }
    }

    @Test
    func `decodes usage response without Code usage pools`() throws {
        let response = try JSONDecoder().decode(KimiUsageResponse.self, from: Data(Self.lapsedUsageJSON.utf8))
        #expect(response.usages == nil)
    }

    @Test
    func `lapsed web session still shows the membership balance`() async throws {
        let snapshot = try await KimiUsageFetcher.fetchUsage(
            authToken: "fixture-web-token",
            now: Self.now,
            transport: Self.transport())

        #expect(snapshot.weekly == nil)
        #expect(snapshot.rateLimit == nil)
        let usage = snapshot.toUsageSnapshot()
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        let monthly = try #require(usage.extraRateWindows?.first { $0.id == "kimi-monthly" })
        #expect(monthly.window.usedPercent == 0)
        #expect(monthly.window.resetsAt == ISO8601DateParser.parse("2026-11-22T00:00:00Z"))
    }

    @Test
    func `lapsed web session without membership balances keeps the scope error`() async {
        do {
            _ = try await KimiUsageFetcher.fetchUsage(
                authToken: "fixture-web-token",
                now: Self.now,
                transport: Self.transport(statsJSON: "{}"))
            Issue.record("Expected missing Code usage to fail without membership balances")
        } catch let KimiAPIError.parseFailed(message) {
            #expect(message == "FEATURE_CODING scope not found in response")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `menu card renders the membership balance for a lapsed session`() async throws {
        let usage = try await KimiUsageFetcher.fetchUsage(
            authToken: "fixture-web-token",
            now: Self.now,
            transport: Self.transport()).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.kimi])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .kimi,
            metadata: metadata,
            snapshot: usage,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Self.now))

        let monthly = try #require(model.metrics.first { $0.id == "kimi-monthly" })
        #expect(monthly.percent == 100)
        #expect(model.placeholder == nil)
    }
}
