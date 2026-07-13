import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct Sub2APICLIOutputTests {
    @Test
    func `subscription labels and per key totals reach CLI output`() {
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: 1440, resetsAt: nil, resetDescription: "$1 / $10"),
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: nil,
                resetDescription: "$2 / $10"),
            tertiary: RateWindow(
                usedPercent: 30,
                windowMinutes: 43200,
                resetsAt: nil,
                resetDescription: "$3 / $10"),
            sub2APIUsage: Sub2APIUsageDetails(
                kind: .subscription,
                balance: 42.5,
                unit: "USD",
                today: .init(requests: 4, totalTokens: 1200, actualCostUSD: 1.25),
                total: .init(requests: 40, totalTokens: 12000, actualCostUSD: 25)),
            updatedAt: Date(timeIntervalSince1970: 1),
            identity: ProviderIdentitySnapshot(
                providerID: .sub2api,
                accountEmail: nil,
                accountOrganization: "Enterprise",
                loginMethod: "Enterprise"))

        let output = CLIRenderer.renderText(
            provider: .sub2api,
            snapshot: snapshot,
            credits: nil,
            context: RenderContext(
                header: "sub2api",
                status: nil,
                useColor: false,
                resetStyle: .absolute))

        #expect(output.contains("Daily quota:"))
        #expect(output.contains("Weekly quota:"))
        #expect(output.contains("Monthly quota:"))
        #expect(output.contains("Balance: $42.50"))
        #expect(output.contains("Today: 4 requests · 1.2K tokens · $1.25"))
        #expect(output.contains("Total: 40 requests · 12K tokens · $25.00"))
        #expect(output.contains("Plan: Enterprise"))
    }
}
