import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

struct HyperPresentationTests {
    @Test
    func `CLI renders Hypercredits as a balance instead of a zero-limit cost`() {
        let snapshot = HyperUsageSnapshot(balance: 42.5, updatedAt: Date(timeIntervalSince1970: 1))
            .toUsageSnapshot()

        let output = CLIRenderer.renderText(
            provider: .hyper,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "hyper",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Balance: 42.50 HC"))
        #expect(!output.contains("Cost:"))
        #expect(!output.contains("/ 0"))
    }

    @Test
    func `menu bar renders the Hypercredit balance`() {
        let snapshot = HyperUsageSnapshot(balance: 42.5, updatedAt: Date(timeIntervalSince1970: 1))
            .toUsageSnapshot()

        #expect(StatusItemController.hyperBalanceDisplayText(snapshot: snapshot) == "42.50 HC")
    }

    @Test
    @MainActor
    func `menu card renders Hypercredits as a balance without a percentage`() throws {
        let now = Date(timeIntervalSince1970: 1)
        let snapshot = HyperUsageSnapshot(balance: 42.5, updatedAt: now).toUsageSnapshot()
        let metadata = try #require(ProviderDefaults.metadata[.hyper])

        let model = UsageMenuCardView.Model.make(.init(
            provider: .hyper,
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

        #expect(model.providerCost?.title == "Hypercredits")
        #expect(model.providerCost?.spendLine == "Balance: 42.50 HC")
        #expect(model.providerCost?.percentUsed == nil)
        #expect(model.providerCost?.percentLine == nil)
    }
}
