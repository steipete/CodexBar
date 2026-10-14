import AppKit
import CodexBarCore
import Foundation
import SwiftUI
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
        #expect(!OverviewMenuCardRowView(model: model, storageText: nil, width: 340, layout: .compact).usesFullCard)
        #expect(model.showsOverviewSupplementalContent(compact: false))
        model.metrics = []
        #expect(model.showsOverviewSupplementalContent(compact: true))
        #expect(OverviewMenuCardRowView(model: model, storageText: nil, width: 340, layout: .compact).usesFullCard)
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

    @Test(arguments: [UsageProvider.codex, .claude])
    func `plan dates add a row only in detailed overview when quotas are present`(provider: UsageProvider) throws {
        var model = try Self.model(provider: provider)
        model.providerDetails = []
        model.providerDetailRawTitles = []
        let withoutDate = model
        model.subscriptionNotes = ["Renews: Nov 5, 2026"]
        model.usageNotes = model.subscriptionNotes

        #expect(abs(Self.height(model, layout: .compact) - Self.height(withoutDate, layout: .compact)) < 1)
        #expect(Self.height(model, layout: .detailed) > Self.height(withoutDate, layout: .detailed) + 10)

        model.metrics = []
        var withoutQuotasOrDate = model
        withoutQuotasOrDate.subscriptionNotes = []
        withoutQuotasOrDate.usageNotes = []
        #expect(Self.height(model, layout: .compact) > Self.height(withoutQuotasOrDate, layout: .compact) + 10)
    }

    private static func height(_ model: UsageMenuCardView.Model, layout: MergedOverviewLayout) -> CGFloat {
        NSHostingController(rootView: OverviewMenuCardRowView(
            model: model, storageText: nil, width: 340, layout: layout))
            .sizeThatFits(in: CGSize(width: 340, height: CGFloat.greatestFiniteMagnitude)).height
    }

    private static func settings(_ defaults: InMemoryUserDefaults) -> SettingsStore {
        ProviderUsageItemVisibilityTests.settings(
            defaults: defaults,
            configStore: testConfigStore(suiteName: "CompactOverviewTests-\(UUID().uuidString)"))
    }

    private static func model(provider: UsageProvider = .zai) throws -> UsageMenuCardView.Model {
        try UsageMenuCardView.Model(
            provider: provider,
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
