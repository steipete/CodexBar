import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct CompactOverviewTests {
    @Test
    func `layout defaults to detailed and unknown values fail back to detailed`() {
        let defaults = InMemoryUserDefaults()
        #expect(Self.settings(defaults).mergedOverviewLayout == .detailed)
        defaults.set("unsupported-layout", forKey: "mergedOverviewLayout")
        #expect(Self.settings(defaults).mergedOverviewLayout == .detailed)
    }

    @Test
    func `compact layout persists independently of icon merging`() {
        let defaults = InMemoryUserDefaults()
        let settings = Self.settings(defaults)
        settings.mergedOverviewLayout = .compact
        settings.mergeIcons = false

        let reloaded = Self.settings(defaults)
        #expect(reloaded.mergedOverviewLayout == .compact)
        #expect(!reloaded.mergeIcons)
        reloaded.mergeIcons = true
        #expect(reloaded.mergedOverviewLayout == .compact)
        reloaded.mergedOverviewLayout = .detailed
        #expect(Self.settings(defaults).mergedOverviewLayout == .detailed)
    }

    @Test
    func `compact keeps details when no quota metrics can describe the provider`() throws {
        var model = try Self.model()
        #expect(!model.showsOverviewSupplementalContent(compact: true))
        #expect(model.showsOverviewSupplementalContent(compact: false))
        model.metrics = []
        #expect(model.showsOverviewSupplementalContent(compact: true))
        #expect(model.providerDetails.first?.title == "Account balance")
    }

    @Test
    func `hiding the final metric restores useful compact details`() throws {
        let model = try Self.model()
        let visible = model.applyingUsageItemVisibility(hiddenItemIDs: [.metric("primary")])
        #expect(visible.metrics.isEmpty)
        #expect(visible.showsOverviewSupplementalContent(compact: true))
        #expect(visible.providerDetails.first?.rows.first?.value == "$12.00")
    }

    private static func settings(_ defaults: InMemoryUserDefaults) -> SettingsStore {
        ProviderUsageItemVisibilityTests.settings(
            defaults: defaults,
            configStore: testConfigStore(suiteName: "CompactOverviewTests-\(UUID().uuidString)"))
    }

    private static func model() throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model(
            provider: .zai,
            providerName: "Example provider",
            email: "",
            subtitleText: "Updated just now",
            subtitleStyle: .info,
            planText: nil,
            metrics: [.init(
                id: "primary",
                title: "Weekly",
                percent: 25,
                percentStyle: .used,
                resetText: "Resets in 2d",
                detailText: "Example detail",
                detailLeftText: nil,
                detailRightText: nil,
                pacePercent: nil,
                paceOnTop: true)],
            usageNotes: [],
            providerDetails: [ProviderDetailSection(
                title: "Account balance", rows: [.init(label: "Balance", value: "$12.00")])],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)
    }
}
