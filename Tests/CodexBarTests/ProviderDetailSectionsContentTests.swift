import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct ProviderDetailSectionsContentTests {
    @Test
    func `snapshot details flow into menu model without affecting empty snapshots`() throws {
        let details = try [Self.section(kind: .bars)]
        let populated = UsageMenuCardView.Model.make(Self.input(details: details))
        let empty = UsageMenuCardView.Model.make(Self.input(details: []))

        #expect(populated.providerDetails == details)
        #expect(populated.hasUsageContent)
        #expect(empty.providerDetails.isEmpty)
    }

    @Test(arguments: [ProviderDetailSection.Chart.Kind.bars, .line])
    func `generic detail renderer lays out rows and chart kinds`(kind: ProviderDetailSection.Chart.Kind) throws {
        let view = try ProviderDetailSectionsContent(sections: [Self.section(kind: kind)], chartColor: .blue)
        let size = NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))

        #expect(size.width > 0)
        #expect(size.height > 58)
    }

    private static func section(kind: ProviderDetailSection.Chart.Kind) throws -> ProviderDetailSection {
        try ProviderDetailSection(
            title: "Usage",
            rows: [ProviderDetailSection.Row(label: "Requests", value: "42", secondaryValue: "Today")],
            chart: ProviderDetailSection.Chart(
                kind: kind,
                title: "Daily",
                unit: "tokens",
                points: [
                    ProviderDetailSection.Chart.Point(label: "Mon", value: 12),
                    ProviderDetailSection.Chart.Point(label: "Tue", value: 24),
                ]))
    }

    private static func input(details: [ProviderDetailSection]) -> UsageMenuCardView.Model.Input {
        let provider: UsageProvider = .synthetic
        return UsageMenuCardView.Model.Input(
            provider: provider,
            metadata: ProviderDescriptorRegistry.descriptor(for: provider).metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                details: details,
                updatedAt: Date()),
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
            now: Date())
    }
}
