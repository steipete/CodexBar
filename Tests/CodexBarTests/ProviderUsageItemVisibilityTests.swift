import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct ProviderUsageItemVisibilityTests {
    @Test
    func `codex exposes independently selectable metrics credits and reset credits`() {
        let model = Self.model(
            provider: .codex,
            metricIDs: ["primary", "secondary", "codex-spark", "codex-spark-weekly"],
            showsCredits: true,
            showsResetCredits: true)

        #expect(model.usageItemDescriptors.map(\.id.rawValue) == [
            "metric:primary",
            "metric:secondary",
            "metric:codex-spark",
            "metric:codex-spark-weekly",
            "section:codex-reset-credits",
            "section:credits",
        ])
    }

    @Test
    func `projection can leave only codex weekly usage and reset credits`() {
        let model = Self.model(
            provider: .codex,
            metricIDs: ["primary", "secondary", "codex-spark", "codex-spark-weekly"],
            showsCredits: true,
            showsResetCredits: true)
        let projected = model.applyingUsageItemVisibility(hiddenItemIDs: [
            .metric("primary"),
            .metric("codex-spark"),
            .metric("codex-spark-weekly"),
            .credits,
        ])

        #expect(projected.metrics.map(\.id) == ["secondary"])
        #expect(projected.codexResetCredits != nil)
        #expect(projected.creditsText == nil)
        #expect(projected.creditsRemaining == nil)
        #expect(projected.creditsProgressPercent == nil)
        #expect(projected.creditsScaleText == nil)
        #expect(projected.creditsHintText == nil)
        #expect(projected.creditsHintCopyText == nil)

        // The raw model remains available to populate the settings checkboxes.
        #expect(model.metrics.count == 4)
        #expect(model.creditsText != nil)
    }

    @Test
    func `cursor grok bot usage can be hidden without hiding weekly usage`() {
        let model = Self.model(provider: .cursor, metricIDs: ["primary", "cursor-grok-bot"])

        let projected = model.applyingUsageItemVisibility(hiddenItemIDs: [
            .metric("cursor-grok-bot"),
        ])

        #expect(projected.metrics.map(\.id) == ["primary"])
    }

    @Test
    func `legacy codex spark choice migrates and explicit defaults survive reload`() throws {
        let suite = "ProviderUsageItemVisibilityTests-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "codexSparkUsageVisible")
        let configStore = testConfigStore(suiteName: suite)
        let settings = Self.settings(defaults: defaults, configStore: configStore)

        #expect(settings.hiddenUsageItemIDs(for: .codex) == [
            .metric("codex-spark"),
            .metric("codex-spark-weekly"),
        ])

        let backgroundRevision = settings.backgroundWorkSettingsRevision
        settings.setUsageItemVisible(true, itemID: .metric("codex-spark-weekly"), for: .codex)
        #expect(settings.providerConfig(for: .codex)?.hiddenUsageItemIDs == ["metric:codex-spark"])
        #expect(settings.codexSparkUsageVisible)
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision)

        settings.setUsageItemVisible(false, itemID: .init(rawValue: "future:item"), for: .codex)
        #expect(settings.providerConfig(for: .codex)?.hiddenUsageItemIDs == [
            "future:item",
            "metric:codex-spark",
        ])

        settings.restoreDefaultUsageItemVisibility(for: .codex)
        #expect(settings.providerConfig(for: .codex)?.hiddenUsageItemIDs == [])
        #expect(settings.codexSparkUsageVisible)

        let reloaded = Self.settings(
            defaults: defaults,
            configStore: testConfigStore(suiteName: suite, reset: false))
        #expect(reloaded.hiddenUsageItemIDs(for: .codex).isEmpty)
    }

    private static func settings(
        defaults: UserDefaults,
        configStore: CodexBarConfigStore) -> SettingsStore
    {
        SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func model(
        provider: UsageProvider,
        metricIDs: [String],
        showsCredits: Bool = false,
        showsResetCredits: Bool = false) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model(
            provider: provider,
            providerName: provider.rawValue,
            email: "user@example.com",
            subtitleText: "Updated just now",
            subtitleStyle: .info,
            planText: nil,
            metrics: metricIDs.map { id in
                .init(
                    id: id,
                    title: id == "secondary" ? "Weekly" : id,
                    percent: 25,
                    percentStyle: .used,
                    resetText: nil,
                    detailText: nil,
                    detailLeftText: nil,
                    detailRightText: nil,
                    pacePercent: nil,
                    paceOnTop: true)
            },
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: showsCredits ? "$12.34 remaining" : nil,
            creditsRemaining: showsCredits ? 12.34 : nil,
            creditsProgressPercent: showsCredits ? 50 : nil,
            creditsScaleText: showsCredits ? "$25" : nil,
            creditsHintText: showsCredits ? "Available balance" : nil,
            creditsHintCopyText: showsCredits ? "Available balance" : nil,
            codexResetCredits: showsResetCredits
                ? CodexResetCreditsPresentation(
                    text: "1 available",
                    items: [.init(expiryText: "Expires tomorrow", compactExpiryText: "tomorrow")])
                : nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)
    }
}
