import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct MenuCardHelmcodeTests {
    @Test
    func `model shows the primary quota line named extra windows and prepaid balance`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            creditsData: Self.creditsFixture(),
            now: now).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.helmcode])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .helmcode,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let primary = try #require(model.metrics.first)
        #expect(primary.title == "Monthly")
        #expect(primary.percent == HelmcodeUsageFetcherTests.glm53FlashPercent)
        #expect(primary.detailText?.contains("glm5.3-flash") == true)
        #expect(primary.detailText?.contains("73,854,494 / 2,000,000,000 tokens") == true)

        let extras = model.metrics.dropFirst()
        #expect(extras.count == 5)
        #expect(extras.first?.title == "deepseek-v4-flash")
        #expect(extras.first?.percent == 0)

        let prepaid = try #require(model.providerCost)
        #expect(prepaid.title == "Credits")
        #expect(prepaid.spendLine.replacingOccurrences(of: "\u{00A0}", with: "") == "Balance: €12.50")
        #expect(model.creditsText == nil)
    }

    @Test
    func `model omits the balance section when credits are unavailable`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try HelmcodeUsageFetcher._parseSnapshotForTesting(
            quotaData: Self.quotaFixture(),
            creditsData: nil,
            now: now).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.helmcode])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .helmcode,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.providerCost == nil)
        #expect(model.metrics.first?.title == "Monthly")
        #expect(model.metrics.first?.percent == HelmcodeUsageFetcherTests.glm53FlashPercent)
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

    private static func creditsFixture() throws -> Data {
        try self.fixtureData("credits")
    }
}
