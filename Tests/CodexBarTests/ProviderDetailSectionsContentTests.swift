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

    @Test
    func `detail pace follows the global preference without requiring automatic pace support`() throws {
        let row = try ProviderDetailSection.Row(
            label: "Weekly", value: "60%", progress: .init(used: 0.6, total: 1, expectedUsed: 0.5))
        let details = try [ProviderDetailSection(rows: [row])]
        let visible = UsageMenuCardView.Model.make(Self.input(details: details))
        let hidden = UsageMenuCardView.Model.make(Self.input(details: details, paceVisible: false))
        #expect(visible.detailPaceVisible)
        #expect(!hidden.detailPaceVisible)
        #expect(hidden.providerDetails == details)
    }

    @Test(arguments: [ProviderDetailSection.Chart.Kind.bars, .line])
    func `generic detail renderer lays out rows and chart kinds`(kind: ProviderDetailSection.Chart.Kind) throws {
        let view = try ProviderDetailSectionsContent(sections: [Self.section(kind: kind)], chartColor: .blue)
        let size = NSHostingController(rootView: view)
            .sizeThatFits(in: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))

        #expect(size.width > 0)
        #expect(size.height > 58)
    }

    @Test
    func `bar hover reports the original day with native compact token units`() throws {
        for (value, expected) in [(0.0, "0"), (1_334_060, "1.3M"), (2_149_885_865, "2.1B")] {
            let point = try ProviderDetailSection.Chart.Point(label: "2026-11-15", value: value)
            #expect(ProviderDetailChartContent.hoverSummary(point: point, unit: "Token")
                == "2026-11-15: \(expected) Token")
        }
        let maximum = try ProviderDetailSection.Chart.Point(label: "Max", value: Double(Int.max))
        #expect(ProviderDetailChartContent.hoverSummary(point: maximum, unit: "tokens")
            == "Max: 9223372037B tokens")
    }

    @Test
    func `non-token charts preserve their own units and decimal values`() throws {
        let point = try ProviderDetailSection.Chart.Point(label: "Monday", value: 12.5)
        let value = point.value.formatted(.number.precision(.fractionLength(0...2)))
        #expect(ProviderDetailChartContent.hoverSummary(point: point, unit: "credits")
            == "Monday: \(value) credits")
        #expect(ProviderDetailChartContent.hoverSummary(point: point, unit: nil) == "Monday: \(value)")
    }

    @Test
    func `selected bar details render in a stable height and clear with selection`() throws {
        let chart = try #require(Self.section(kind: .bars).chart)
        var selected: String?
        let selection = Binding(get: { selected }, set: { selected = $0 })
        let view = ProviderDetailChartContent(chart: chart, color: .blue)
            .environment(\.menuUsageBarSelection, selection)
        let hosting = NSHostingView(rootView: view.environment(\.accessibilityEnabled, true))
        _ = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        let initialHeight = hosting.fittingSize.height
        #expect(MenuLayoutScreenshotRenderTests.accessibilityText(hosting).contains(L("Hover a bar for details")))

        selected = "1"
        hosting.rootView = view.environment(\.accessibilityEnabled, true)
        _ = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        #expect(MenuLayoutScreenshotRenderTests.accessibilityText(hosting).contains("Tue: 24 tokens"))
        #expect(hosting.fittingSize.height == initialHeight)

        selected = nil
        hosting.rootView = view.environment(\.accessibilityEnabled, true)
        _ = try #require(MenuLayoutScreenshotRenderTests.pngDataWithWindow(hosting: hosting))
        #expect(MenuLayoutScreenshotRenderTests.accessibilityText(hosting).contains(L("Hover a bar for details")))
    }

    @Test
    func `privacy redaction preserves detail severity and progress`() throws {
        let row = try ProviderDetailSection.Row(
            label: "Pool user@example.com",
            value: "10%",
            progress: .init(used: 0.9, total: 1, expectedUsed: 0.5),
            severity: .critical)
        let model = try UsageMenuCardView.Model.make(Self.input(
            details: [ProviderDetailSection(rows: [row])], hidePersonalInfo: true))
        let redacted = try #require(model.providerDetails.first?.rows.first)
        #expect(redacted.label == "Pool")
        #expect(redacted.severity == .critical)
        #expect(redacted.progress == row.progress)
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

    private static func input(
        details: [ProviderDetailSection],
        hidePersonalInfo: Bool = false,
        paceVisible: Bool = true) -> UsageMenuCardView.Model.Input
    {
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
            hidePersonalInfo: hidePersonalInfo,
            paceVisible: paceVisible,
            now: Date())
    }
}
