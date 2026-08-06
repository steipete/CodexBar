import CodexBarCore
import Foundation
import Testing
@testable import CodexBarCLI

struct Sub2APICLIOutputTests {
    @Test
    func `subscription labels and per key totals reach CLI output`() throws {
        let snapshot = try UsageSnapshot(
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
            details: [ProviderDetailSection(title: "Usage summary", rows: [
                ProviderDetailSection.Row(label: "Balance", value: "$42.50"),
                ProviderDetailSection.Row(label: "Today requests", value: "4"),
                ProviderDetailSection.Row(label: "Today tokens", value: "1,200", secondaryValue: "$1.25"),
                ProviderDetailSection.Row(label: "All time requests", value: "40"),
                ProviderDetailSection.Row(
                    label: "All time tokens",
                    value: "12,000",
                    secondaryValue: "$25.00"),
            ])],
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
        #expect(output.contains("Today requests: 4"))
        #expect(output.contains("Today tokens: 1,200 · $1.25"))
        #expect(output.contains("All time requests: 40"))
        #expect(output.contains("All time tokens: 12,000 · $25.00"))
        #expect(output.contains("Plan: Enterprise"))
    }
}
