import CodexBarCore
import Foundation
import Observation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct ProviderUsageItemVisibilityTests {
    @Test
    func `cosmetic edits preserve account caches spend ownership and synced refresh state`() throws {
        let defaults = InMemoryUserDefaults()
        let configStore = testConfigStore(suiteName: "visibility-ownership-\(UUID().uuidString)")
        try configStore.save(CodexBarConfig(providers: UsageProvider.allCases.map {
            ProviderConfig(id: $0.instanceID, enabled: $0 == .claude)
        }))
        let settings = Self.settings(defaults: defaults, configStore: configStore)
        defer { settings.configFileWatcher?.stop() }
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.costUsageEnabled = true
        settings.addTokenAccount(provider: .claude, label: "Synthetic", token: "fixture-original")
        let account = try #require(settings.tokenAccounts(for: .claude).first)
        let home = configStore.fileURL.deletingLastPathComponent().path
        let environment = ["HOME": home]
        settings._test_codexReconciliationEnvironment = environment
        let store = UsageStore(
            fetcher: UsageFetcher(environment: environment),
            browserDetection: BrowserDetection(homeDirectory: home, cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        defer { store.stopSharedSpendDashboardPublication() }
        let key = store.tokenAccountSnapshotCacheKey(provider: .claude, account: account)
        store.accountSnapshots[.claude] = [TokenAccountUsageSnapshot(
            account: account,
            snapshot: UsageSnapshot(
                primary: RateWindow(usedPercent: 20, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            error: nil,
            sourceLabel: "synthetic",
            cacheKey: key)]
        let ownership = SpendDashboardSource.configuration(settings: settings, store: store).sourceOwnershipFingerprints
        #expect(!ownership.isEmpty)
        let fetchRevision = settings.providerConfigRevision(for: .claude)
        let backgroundRevision = settings.backgroundWorkSettingsRevision

        settings.setUsageItemVisible(false, itemID: .metric("primary"), for: .claude)
        #expect(store.tokenAccountSnapshotCacheKey(provider: .claude, account: account) == key)
        #expect(store.validTokenAccountSnapshots(provider: .claude, accounts: [account]).count == 1)
        #expect(SpendDashboardSource.configuration(settings: settings, store: store)
            .sourceOwnershipFingerprints == ownership)

        var incoming = settings.configSnapshot
        let index = try #require(incoming.providers.firstIndex { $0.id == .claude })
        incoming.providers[index].hiddenUsageItemIDs = ["metric:secondary"]
        incoming.providers[index].accentColor = "#123456"
        settings.applyExternalConfig(incoming, reason: "synthetic-cosmetic-sync", affectsBackgroundWork: false)
        #expect(settings.providerConfigRevision(for: .claude) == fetchRevision)
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision)
        #expect(store.tokenAccountSnapshotCacheKey(provider: .claude, account: account) == key)
        #expect(store.validTokenAccountSnapshots(provider: .claude, accounts: [account]).count == 1)
        #expect(SpendDashboardSource.configuration(settings: settings, store: store)
            .sourceOwnershipFingerprints == ownership)

        settings.updateTokenAccount(provider: .claude, accountID: account.id, token: "fixture-rotated")
        let rotated = try #require(settings.tokenAccounts(for: .claude).first)
        #expect(store.tokenAccountSnapshotCacheKey(provider: .claude, account: rotated) != key)
        #expect(store.validTokenAccountSnapshots(provider: .claude, accounts: [rotated]).isEmpty)
        #expect(SpendDashboardSource.configuration(settings: settings, store: store)
            .sourceOwnershipFingerprints != ownership)
    }

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
        #expect(projected.limitResetCredits != nil)
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
    func `provider detail sections appear as usage items keyed by raw title`() throws {
        let model = try Self.model(
            provider: .zai,
            metricIDs: ["primary", "secondary", "zai-mcp"],
            detailSections: [
                "Quota details",
                "Hourly tokens",
                "Daily tokens",
            ].map { try ProviderDetailSection(title: $0, rows: [.init(label: "GLM-5.3", value: "100")]) })

        // Cost-summary sections stay owned by the cost summary style picker; only independent
        // sections join the checkbox list.
        #expect(model.usageItemDescriptors.map(\.id.rawValue) == [
            "metric:primary",
            "metric:secondary",
            "metric:zai-mcp",
            "detailSection:Quota details",
        ])
        #expect(model.usageItemDescriptors.last?.title == "Quota details")
    }

    @Test
    func `hiding a detail section removes it from the projection only`() throws {
        let model = try Self.model(
            provider: .zai,
            metricIDs: ["primary"],
            detailSections: [
                "Quota details",
                "Hourly tokens",
            ].map { try ProviderDetailSection(title: $0, rows: [.init(label: "GLM-5.3", value: "100")]) })

        let projected = model.applyingUsageItemVisibility(hiddenItemIDs: [.detailSection("Quota details")])

        #expect(projected.providerDetails.map(\.title) == ["Hourly tokens"])
        #expect(projected.providerDetailRawTitles == ["Hourly tokens"])
        #expect(projected.metrics.map(\.id) == ["primary"])
        // The raw model remains available to populate the settings checkboxes.
        #expect(model.providerDetails.map(\.title) == ["Quota details", "Hourly tokens"])
        // Applying the projection twice changes nothing further.
        let reapplied = projected.applyingUsageItemVisibility(hiddenItemIDs: [.detailSection("Quota details")])
        #expect(reapplied.providerDetails.map(\.title) == projected.providerDetails.map(\.title))
    }

    @Test
    func `hiding a remembered section preserves details without identity metadata`() throws {
        let model = try Self.model(
            provider: .zai,
            metricIDs: ["primary"],
            detailSections: [ProviderDetailSection(title: "New details", rows: [])],
            detailRawTitles: [])

        let projected = model.applyingUsageItemVisibility(hiddenItemIDs: [.detailSection("Old details")])

        #expect(projected.providerDetails.map(\.title) == ["New details"])
        #expect(projected.providerDetailRawTitles == [nil])
    }

    @Test
    func `a hidden detail section the provider stopped reporting stays restorable`() throws {
        let model = try Self.model(
            provider: .zai,
            metricIDs: ["primary"],
            detailSections: [ProviderDetailSection(title: "Account balance", rows: [])])

        let descriptors = model.usageItemDescriptors(includingHidden: [.detailSection("Quota details")])

        #expect(descriptors.map(\.id.rawValue) == [
            "metric:primary",
            "detailSection:Account balance",
            "detailSection:Quota details",
        ])
        #expect(descriptors.last?.title == "Quota details (unavailable)")
    }

    @Test
    func `unavailable detail labels respect privacy without changing stored identity`() {
        let model = Self.model(provider: .zai, metricIDs: [])
        let item = ProviderUsageItemID.detailSection("Quota for fixture@example.com")
        let hidden: Set<ProviderUsageItemID> = [item]

        let privateItems = model.usageItemDescriptors(includingHidden: hidden, hidePersonalInfo: true)
        let visibleItems = model.usageItemDescriptors(includingHidden: hidden, hidePersonalInfo: false)

        #expect(privateItems.last?.id == item)
        #expect(privateItems.last?.title.contains("fixture@example.com") == false)
        #expect(visibleItems.last?.title == "Quota for fixture@example.com (unavailable)")
    }

    @Test
    func `untitled detail sections render without joining the usage item list`() throws {
        let untitled = try ProviderDetailSection(title: nil, rows: [.init(label: "Pool", value: "42")])
        let model = Self.model(
            provider: .kimi,
            metricIDs: ["primary"],
            detailSections: [untitled],
            detailRawTitles: [nil])

        #expect(model.usageItemDescriptors.map(\.id.rawValue) == ["metric:primary"])
        let projected = model.applyingUsageItemVisibility(hiddenItemIDs: [.detailSection("Quota details")])
        #expect(projected.providerDetails.count == 1)
        #expect(projected.providerDetailRawTitles == [nil])
    }

    @Test
    func `detail section choices round-trip through provider config and restore defaults`() {
        let settings = Self.settings(
            defaults: InMemoryUserDefaults(),
            configStore: testConfigStore(
                suiteName: "ProviderUsageItemVisibilityTests-detail-sections-\(UUID().uuidString)"))

        settings.setUsageItemVisible(false, itemID: .detailSection("Quota details"), for: .zai)
        settings.setUsageItemVisible(false, itemID: .metric("zai-mcp"), for: .zai)

        #expect(settings.providerConfig(for: .zai)?.hiddenUsageItemIDs == [
            "detailSection:Quota details",
            "metric:zai-mcp",
        ])
        #expect(!settings.isUsageItemVisible(.detailSection("Quota details"), for: .zai))

        settings.restoreDefaultUsageItemVisibility(for: .zai)

        #expect(settings.providerConfig(for: .zai)?.hiddenUsageItemIDs == [])
    }

    @Test
    func `projection keeps sections and raw titles aligned on a maximally populated card`() throws {
        // A snapshot may carry the documented maximum of 8 sections with 24 rows each; the paired
        // arrays must survive selective removal without drifting out of sync.
        let sections = try (0..<8).map { index in
            try ProviderDetailSection(
                title: "Section \(index)",
                rows: (0..<24).map { row in try .init(label: "Row \(row)", value: "\(index)-\(row)") })
        }
        let model = Self.model(provider: .zai, metricIDs: ["primary", "secondary"], detailSections: sections)
        let hiddenItemIDs: Set<ProviderUsageItemID> = [
            .detailSection("Section 0"),
            .detailSection("Section 3"),
            .detailSection("Section 7"),
            .metric("secondary"),
        ]

        let projected = model.applyingUsageItemVisibility(hiddenItemIDs: hiddenItemIDs)

        #expect(projected.providerDetails.count == 5)
        #expect(projected.providerDetailRawTitles.count == projected.providerDetails.count)
        #expect(zip(projected.providerDetails, projected.providerDetailRawTitles).allSatisfy { $0.title == $1 })
        #expect(projected.providerDetails.flatMap(\.rows).count == 5 * 24)
        #expect(projected.metrics.map(\.id) == ["primary"])
        #expect(model.usageItemDescriptors(includingHidden: hiddenItemIDs).count == 2 + 8)
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
    func `visibility changes notify menus while preserving other providers and fetch state`() {
        let settings = Self.settings(
            defaults: InMemoryUserDefaults(),
            configStore: testConfigStore(suiteName: "usage-item-observation-\(UUID().uuidString)"))
        let changed = LockIsolated(false)
        let fetchRevision = settings.providerConfigRevision(for: .codex)
        let backgroundRevision = settings.backgroundWorkSettingsRevision
        withObservationTracking {
            _ = settings.menuObservationToken
        } onChange: {
            changed.setValue(true)
        }

        settings.setUsageItemVisible(false, itemID: .metric("primary"), for: .codex)

        #expect(changed.value)
        #expect(settings.isUsageItemVisible(.metric("primary"), for: .claude))
        #expect(settings.providerConfigRevision(for: .codex) == fetchRevision)
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision)
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

    @Test
    func `legacy hidden rows are persisted for sync without replacing explicit selections`() throws {
        let defaults = InMemoryUserDefaults(values: [
            "codexSparkUsageVisible": false,
            "claudeDailyRoutinesUsageVisible": false,
        ])
        let configStore = testConfigStore(suiteName: "visibility-sync-\(UUID().uuidString)")
        let settings = Self.settings(defaults: defaults, configStore: configStore)
        for (provider, expected) in [
            (UsageProvider.codex, ["metric:codex-spark", "metric:codex-spark-weekly"]),
            (.claude, ["metric:claude-routines"]),
        ] {
            let config = try #require(settings.providerConfig(for: provider))
            #expect(ProviderIntentPayload(config: config).hiddenUsageItemIDs == expected)
            #expect(try configStore.load()?.providerConfig(for: provider.instanceID)?.hiddenUsageItemIDs == expected)
            settings.restoreDefaultUsageItemVisibility(for: provider)
        }
        let reloaded = Self.settings(defaults: defaults, configStore: configStore)
        #expect(reloaded.providerConfig(for: .codex)?.hiddenUsageItemIDs == [])
        #expect(reloaded.providerConfig(for: .claude)?.hiddenUsageItemIDs == [])
        #expect(reloaded.providerConfig(for: .cursor)?.hiddenUsageItemIDs == nil)
    }

    static func settings(
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
        showsResetCredits: Bool = false,
        detailSections: [ProviderDetailSection] = [],
        detailRawTitles: [String?]? = nil) -> UsageMenuCardView.Model
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
            providerDetails: detailSections,
            providerDetailRawTitles: detailRawTitles ?? detailSections.map(\.title),
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: showsCredits ? "$12.34 remaining" : nil,
            creditsRemaining: showsCredits ? 12.34 : nil,
            creditsProgressPercent: showsCredits ? 50 : nil,
            creditsScaleText: showsCredits ? "$25" : nil,
            creditsHintText: showsCredits ? "Available balance" : nil,
            creditsHintCopyText: showsCredits ? "Available balance" : nil,
            limitResetCredits: showsResetCredits
                ? LimitResetCreditsPresentation(
                    text: "1 available",
                    items: [.init(expiryText: "Expires tomorrow", compactExpiryText: "tomorrow")])
                : nil,
            providerCost: nil,
            tokenUsage: nil,
            placeholder: nil,
            progressColor: .blue)
    }
}
