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
    func `a hidden item the provider stopped reporting stays restorable`() {
        // A partial refresh can drop a lane the user hid earlier. Its checkbox has to survive so the
        // single row can be restored without Restore Defaults discarding the rest of the selection.
        let model = Self.model(provider: .cursor, metricIDs: ["primary"])
        let hiddenItemIDs: Set<ProviderUsageItemID> = [.metric("cursor-grok-bot"), .credits]

        let descriptors = model.usageItemDescriptors(includingHidden: hiddenItemIDs)

        #expect(descriptors.map(\.id.rawValue) == [
            "metric:primary",
            "metric:cursor-grok-bot",
            "section:credits",
        ])
        #expect(descriptors[1].title == "Grok Bot (unavailable)")
        #expect(descriptors.last?.title.contains("Credits") == true)
        // Rows the provider still reports keep their menu title instead of the unreported fallback.
        #expect(model.usageItemDescriptors.map(\.id.rawValue) == ["metric:primary"])
    }

    @Test
    func `codex reset credits choice appears only when available or hidden`() {
        let model = Self.model(provider: .codex, metricIDs: ["secondary"])

        #expect(model.usageItemDescriptors.map(\.id.rawValue) == ["metric:secondary"])

        let descriptors = model.usageItemDescriptors(includingHidden: [.codexResetCredits])
        #expect(descriptors.map(\.id.rawValue) == [
            "metric:secondary",
            "section:codex-reset-credits",
        ])
        #expect(descriptors.last?.title == "Limit Reset Credits (unavailable)")
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
    func `restoring one unavailable item preserves other hidden choices`() {
        let suite = "ProviderUsageItemVisibilityTests-restoration-\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults()
        let settings = Self.settings(defaults: defaults, configStore: testConfigStore(suiteName: suite))

        settings.setUsageItemVisible(false, itemID: .metric("cursor-grok-bot"), for: .cursor)
        settings.setUsageItemVisible(false, itemID: .credits, for: .cursor)
        settings.setUsageItemVisible(true, itemID: .metric("cursor-grok-bot"), for: .cursor)

        #expect(settings.hiddenUsageItemIDs(for: .cursor) == [.credits])
    }

    @Test
    func `changing usage item visibility leaves the provider refresh revision untouched`() {
        let settings = Self.settings(
            defaults: InMemoryUserDefaults(),
            configStore: testConfigStore(
                suiteName: "ProviderUsageItemVisibilityTests-refresh-revision-\(UUID().uuidString)"))
        let provider = UsageProvider.codex
        let before = settings.providerConfigRevision(for: provider)

        settings.setUsageItemVisible(false, itemID: .metric("primary"), for: provider)

        #expect(settings.hiddenUsageItemIDs(for: provider) == [.metric("primary")])
        #expect(settings.providerConfigRevision(for: provider) == before)

        settings.restoreDefaultUsageItemVisibility(for: provider)

        #expect(settings.hiddenUsageItemIDs(for: provider).isEmpty)
        #expect(settings.providerConfigRevision(for: provider) == before)
    }

    @Test
    func `legacy codex spark choice migrates and explicit defaults survive reload`() {
        let suite = "ProviderUsageItemVisibilityTests-migration-\(UUID().uuidString)"
        let defaults = InMemoryUserDefaults()
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
        defaults: InMemoryUserDefaults,
        configStore: CodexBarConfigStore) -> SettingsStore
    {
        // Temporary config alone does not isolate migration from real legacy credentials.
        SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { false }),
            performInitialProviderDetection: false)
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
