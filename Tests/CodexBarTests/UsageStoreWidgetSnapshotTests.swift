import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct UsageStoreWidgetSnapshotTests {
    @Test
    func `widget snapshot preserves raw Codex windows for timeline projection`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-codex-weekly-cap"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 1,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(3600),
                    resetDescription: nil),
                updatedAt: now.addingTimeInterval(-7200)),
            provider: .codex)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "codex-weekly-cap-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .codex })
        #expect(entry.usageRows?.map(\.id) == ["session", "weekly"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [99, 0])
        #expect(entry.usageRows?.first?.window?.usedPercent == 1)
        #expect(entry.usageRows?.last?.window?.resetsAt == now.addingTimeInterval(3600))
    }

    @Test
    func `widget snapshot includes Kimi subscription quota rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-kimi-subscription-rows"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "kimi-code-7d",
                    title: "Code 7-day",
                    window: RateWindow(
                        usedPercent: 10,
                        windowMinutes: 7 * 24 * 60,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "kimi-future-quota",
                    title: "Future quota",
                    window: RateWindow(
                        usedPercent: 5,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil)),
                NamedRateWindow(
                    id: "kimi-monthly",
                    title: "Total usage",
                    window: RateWindow(
                        usedPercent: 75,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: nil)),
            ],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .kimi,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: nil))
        store._setSnapshotForTesting(snapshot, provider: .kimi)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "kimi-subscription-rows-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .kimi })
        // Widgets preserve persisted lane order; menu-only presentation may reorder these lanes.
        #expect(entry.usageRows?.map(\.id) == ["primary", "secondary", "kimi-monthly", "kimi-code-7d"])
        #expect(entry.usageRows?.map(\.title) == ["7-day usage", "5-hour usage", "Total usage", "Code 7-day"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [75, 50, 25, 90])
    }

    @Test
    func `widget snapshot includes antigravity grouped usage rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-grouped"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.usageBarsShowUsed = true

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-grouped-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(widgetSnapshots.last?.usageBarsShowUsed == true)
        #expect(entry.usageRows?.map(\.id) == ["primary", "secondary"])
        #expect(entry.usageRows?.map(\.title) == ["Gemini Models", "Claude and GPT"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [90, 80])
    }

    @Test
    func `widget snapshot includes antigravity quota summary rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-quota-summary"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 27, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models Five Hour Limit",
                    window: RateWindow(usedPercent: 9, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Models Weekly Limit",
                    window: RateWindow(usedPercent: 18, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude and GPT models Five Hour Limit",
                    window: RateWindow(usedPercent: 27, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude and GPT models Weekly Limit",
                    window: RateWindow(usedPercent: 36, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-quota-summary-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(entry.usageRows?.map(\.title) == [
            "Gemini Models Five Hour Limit",
            "Gemini Models Weekly Limit",
            "Claude and GPT models Five Hour Limit",
            "Claude and GPT models Weekly Limit",
        ])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [91, 82, 73, 64])
    }

    @Test
    func `widget snapshot hides untouched antigravity model families`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-untouched-family"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: RateWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini weekly",
                    window: RateWindow(usedPercent: 4, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude/GPT 5-hour",
                    window: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Claude/GPT weekly",
                    window: RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Google AI Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-untouched-family-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(entry.usageRows?.map(\.title) == [
            "Gemini 5-hour",
            "Gemini weekly",
        ])
    }

    @Test
    func `widget snapshot pairs renamed antigravity third party lanes`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-renamed-third-party"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: RateWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Third-party models 5-hour",
                    window: RateWindow(usedPercent: 27, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-3p-weekly",
                    title: "Third-party models weekly",
                    window: RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Google AI Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-renamed-third-party-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        // The reset weekly lane stays because its 5-hour sibling is active.
        #expect(entry.usageRows?.map(\.title) == [
            "Gemini 5-hour",
            "Third-party models 5-hour",
            "Third-party models weekly",
        ])
    }

    @Test
    func `widget snapshot labels antigravity compact fallback with model name`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-compact-fallback"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = try AntigravityStatusSnapshot(
            modelQuotas: [
                AntigravityModelQuota(
                    label: "Experimental Model",
                    modelId: "MODEL_PLACEHOLDER_NEW",
                    remainingFraction: 0.36,
                    resetTime: nil,
                    resetDescription: nil),
            ],
            accountEmail: nil,
            accountPlan: nil,
            source: .local)
            .toUsageSnapshot()
        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-compact-fallback-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        #expect(entry.primary == nil)
        #expect(entry.usageRows?.map(\.id) == ["antigravity-compact-fallback-MODEL_PLACEHOLDER_NEW"])
        #expect(entry.usageRows?.map(\.title) == ["Experimental Model"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [36])
    }

    @Test
    func `widget snapshot excludes mimo balance from quota rows`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-mimo-balance"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = MiMoUsageSnapshot(
            balance: 25.51,
            currency: "USD",
            updatedAt: Date())
            .toUsageSnapshot()
        store._setSnapshotForTesting(snapshot, provider: .mimo)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "mimo-balance-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .mimo })
        #expect(entry.primary == nil)
        #expect(entry.secondary == nil)
        #expect(entry.usageRows?.isEmpty == true)
    }

    @Test
    func `widget snapshot keeps Claude local cost without quota data`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-local-cost-only"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4200,
                sessionCostUSD: 1.25,
                last30DaysTokens: 42000,
                last30DaysCostUSD: 12.50,
                daily: [],
                updatedAt: updatedAt),
            provider: .claude)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .codex)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-local-cost-only-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(entry.updatedAt == updatedAt)
        #expect(entry.primary == nil)
        #expect(entry.secondary == nil)
        #expect(entry.usageRows?.isEmpty == true)
        #expect(entry.tokenUsage?.sessionTokens == 4200)
        #expect(entry.tokenUsage?.last30DaysTokens == 42000)
    }

    @Test
    func `widget snapshot preserves prior Claude quota rows during token only refresh`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-token-only-preserves-quota"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let quotaUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let tokenUpdatedAt = quotaUpdatedAt.addingTimeInterval(60)
        let primary = RateWindow(
            usedPercent: 28,
            windowMinutes: 300,
            resetsAt: quotaUpdatedAt.addingTimeInterval(3600),
            resetDescription: nil)
        let secondary = RateWindow(
            usedPercent: 12,
            windowMinutes: 10080,
            resetsAt: quotaUpdatedAt.addingTimeInterval(86400),
            resetDescription: nil)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: primary,
                secondary: secondary,
                updatedAt: quotaUpdatedAt),
            provider: .claude)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-pre-token-preserves-quota-test")
        await store.widgetSnapshotPersistTask?.value

        let preTokenEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(preTokenEntry.updatedAt == quotaUpdatedAt)
        #expect(preTokenEntry.primary == primary)
        #expect(preTokenEntry.secondary == secondary)
        #expect(preTokenEntry.usageRows?.map(\.id) == ["primary", "secondary"])
        #expect(preTokenEntry.tokenUsage == nil)
        let quotaOwnerKey = try #require(preTokenEntry.quotaOwnerKey)

        store.snapshots.removeValue(forKey: .claude)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4300,
                sessionCostUSD: 1.50,
                last30DaysTokens: 43000,
                last30DaysCostUSD: 13.50,
                daily: [],
                updatedAt: tokenUpdatedAt),
            provider: .claude)
        store.persistWidgetSnapshot(reason: "claude-token-only-preserves-quota-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(entry.updatedAt == quotaUpdatedAt)
        #expect(entry.primary == primary)
        #expect(entry.secondary == secondary)
        #expect(entry.usageRows?.map(\.id) == ["primary", "secondary"])
        #expect(entry.usageRows?.compactMap(\.percentLeft) == [72, 88])
        #expect(entry.tokenUsage?.updatedAt == tokenUpdatedAt)
        #expect(entry.tokenUsage?.sessionTokens == 4300)

        store.lastQueuedWidgetSnapshot = WidgetSnapshot(
            entries: [
                WidgetSnapshot.ProviderEntry(
                    provider: .claude,
                    updatedAt: quotaUpdatedAt,
                    primary: primary,
                    secondary: secondary,
                    tertiary: nil,
                    usageRows: [
                        WidgetSnapshot.WidgetUsageRowSnapshot(
                            id: "primary",
                            title: "Session",
                            percentLeft: 72),
                        WidgetSnapshot.WidgetUsageRowSnapshot(
                            id: "secondary",
                            title: "Weekly",
                            percentLeft: 88),
                    ],
                    creditsRemaining: nil,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: [],
                    quotaOwnerKey: quotaOwnerKey),
            ],
            enabledProviders: [.claude],
            generatedAt: quotaUpdatedAt)
        store.widgetUsagePreservationBlockedProviders.insert(.claude)

        store.persistWidgetSnapshot(reason: "claude-token-only-credential-change-test")
        await store.widgetSnapshotPersistTask?.value

        let blockedEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(blockedEntry.updatedAt == tokenUpdatedAt)
        #expect(blockedEntry.primary == nil)
        #expect(blockedEntry.secondary == nil)
        #expect(blockedEntry.usageRows?.isEmpty == true)

        let placeholder = RateWindow(
            usedPercent: 0,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        store.widgetUsagePreservationBlockedProviders.remove(.claude)
        store.lastQueuedWidgetSnapshot = WidgetSnapshot(
            entries: [
                WidgetSnapshot.ProviderEntry(
                    provider: .claude,
                    updatedAt: quotaUpdatedAt,
                    primary: placeholder,
                    secondary: nil,
                    tertiary: nil,
                    usageRows: [
                        WidgetSnapshot.WidgetUsageRowSnapshot(
                            id: "primary",
                            title: "Session",
                            percentLeft: 100),
                    ],
                    creditsRemaining: nil,
                    codeReviewRemainingPercent: nil,
                    tokenUsage: nil,
                    dailyUsage: [],
                    quotaOwnerKey: quotaOwnerKey),
            ],
            enabledProviders: [.claude],
            generatedAt: quotaUpdatedAt)

        store.persistWidgetSnapshot(reason: "claude-token-only-drops-placeholder-test")
        await store.widgetSnapshotPersistTask?.value

        let filteredEntry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(filteredEntry.updatedAt == tokenUpdatedAt)
        #expect(filteredEntry.primary == nil)
        #expect(filteredEntry.usageRows?.isEmpty == true)
    }

    @Test
    func `widget snapshot uses Claude enterprise spend limit instead of placeholder quota`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-claude-enterprise-spend-limit"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: 300,
                    resetsAt: nil,
                    resetDescription: nil,
                    isSyntheticPlaceholder: true),
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 25545.63,
                    limit: 30000,
                    currencyCode: "USD",
                    period: "Monthly cap",
                    updatedAt: updatedAt),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .claude)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "claude-enterprise-spend-limit-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        let row = try #require(entry.usageRows?.first)
        #expect(entry.usageRows?.count == 1)
        #expect(row.id == "extraUsage")
        #expect(row.title == "Monthly cap")
        #expect(abs((row.percentLeft ?? 0) - 14.8479) < 0.0001)
        #expect(row.window?.isSyntheticPlaceholder == false)
    }

    @Test(arguments: [true, false])
    func `widget snapshot respects extra usage visibility for Devin`(_ showsExtraUsage: Bool) async throws {
        let suite = "UsageStoreWidgetSnapshotTests-devin-extra-usage-\(showsExtraUsage)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.showOptionalCreditsAndExtraUsage = showsExtraUsage

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: nil,
                secondary: nil,
                providerCost: ProviderCostSnapshot(
                    used: 48,
                    limit: 0,
                    currencyCode: "USD",
                    period: "Extra usage balance",
                    updatedAt: updatedAt),
                updatedAt: updatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .devin,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .devin)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "devin-extra-usage-visibility-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .devin })
        #expect((entry.providerCost != nil) == showsExtraUsage)
    }

    @Test
    func `widget snapshot carries token usage age separately from entry freshness`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-token-usage-age"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let entryUpdatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let tokenUpdatedAt = entryUpdatedAt.addingTimeInterval(-45 * 60)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: entryUpdatedAt,
                identity: ProviderIdentitySnapshot(
                    providerID: .claude,
                    accountEmail: nil,
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: .claude)
        store._setTokenSnapshotForTesting(
            CostUsageTokenSnapshot(
                sessionTokens: 4200,
                sessionCostUSD: 1.25,
                last30DaysTokens: 42000,
                last30DaysCostUSD: 12.50,
                daily: [],
                updatedAt: tokenUpdatedAt),
            provider: .claude)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "token-usage-age-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .claude })
        #expect(entry.updatedAt == entryUpdatedAt)
        #expect(entry.tokenUsage?.updatedAt == tokenUpdatedAt)
        #expect(entry.tokenUsage?.isStale(comparedTo: entry.updatedAt) == true)
    }

    @Test
    func `widget snapshot labels legacy Cursor request quota as Requests`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-cursor-requests-label"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        try store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                details: [ProviderDetailSection(rows: [
                    ProviderDetailSection.Row(label: "Request quota", value: "200 / 500"),
                ])],
                updatedAt: Date()),
            provider: .cursor)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "cursor-requests-label-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .cursor })
        #expect(entry.usageRows?.map(\.id) == ["primary"])
        #expect(entry.usageRows?.map(\.title) == ["Requests"])
    }

    @Test
    func `widget snapshot keeps Cursor Total label for token based plans`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-cursor-total-label"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 20, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
                tertiary: RateWindow(usedPercent: 0, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
                updatedAt: Date()),
            provider: .cursor)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "cursor-total-label-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .cursor })
        #expect(entry.usageRows?.map(\.title) == ["Total", "Cursor", "Third Party"])
    }
}

@MainActor
struct UsageStoreWidgetSnapshotAntigravityFamilyTests {
    @Test
    func `widget snapshot pairs unfamiliar antigravity family lanes`() async throws {
        let suite = "UsageStoreWidgetSnapshotTests-antigravity-unfamiliar-family"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false

        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini 5-hour",
                    window: RateWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-grok-5h",
                    title: "Grok 5-hour",
                    window: RateWindow(usedPercent: 30, windowMinutes: 300, resetsAt: nil, resetDescription: nil)),
                NamedRateWindow(
                    id: "antigravity-quota-summary-grok-weekly",
                    title: "Grok weekly",
                    window: RateWindow(usedPercent: 0, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)),
            ],
            updatedAt: Date(),
            identity: ProviderIdentitySnapshot(
                providerID: .antigravity,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: "Google AI Pro"))

        store._setSnapshotForTesting(snapshot, provider: .antigravity)

        var widgetSnapshots: [WidgetSnapshot] = []
        store._test_widgetSnapshotSaveOverride = { widgetSnapshots.append($0) }
        defer { store._test_widgetSnapshotSaveOverride = nil }

        store.persistWidgetSnapshot(reason: "antigravity-unfamiliar-family-test")
        await store.widgetSnapshotPersistTask?.value

        let entry = try #require(widgetSnapshots.last?.entries.first { $0.provider == .antigravity })
        // Neither ID nor title names a known family, so the title fallback must still pair the lanes.
        #expect(entry.usageRows?.map(\.title) == [
            "Gemini 5-hour",
            "Grok 5-hour",
            "Grok weekly",
        ])
    }
}
