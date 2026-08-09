import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarWidget

struct ProviderPresentationPolicyCharacterizationTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `automatic exhaustion priority is pinned for every provider`() {
        let optOut: Set<UsageProvider> = [
            .antigravity, .perplexity, .zai, .copilot, .cursor, .minimax, .claude, .codex,
        ]

        for provider in UsageProvider.allCases {
            #expect(
                MenuBarMetricWindowResolver.automaticSelectionPrioritizesExhaustedWindow(for: provider)
                    == !optOut.contains(provider),
                "Unexpected exhaustion priority for \(provider.rawValue)")
        }
    }

    @Test
    func `requested metric lane fallback order is pinned`() {
        let primary = RateWindow(usedPercent: 11, windowMinutes: 300, resetsAt: nil, resetDescription: "primary")
        let secondary = RateWindow(
            usedPercent: 22,
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: "secondary")
        let tertiary = RateWindow(
            usedPercent: 33,
            windowMinutes: 43200,
            resetsAt: nil,
            resetDescription: "tertiary")

        let fixtures: [(UsageProvider, MenuBarMetricPreference, UsageSnapshot, String?)] = [
            (.zai, .tertiary, self.snapshot(primary: primary, secondary: secondary, tertiary: tertiary), "primary"),
            (.cursor, .tertiary, self.snapshot(primary: primary, secondary: secondary, tertiary: tertiary), "tertiary"),
            (
                .perplexity,
                .tertiary,
                self.snapshot(primary: primary, secondary: secondary, tertiary: tertiary),
                "tertiary"),
            (
                .antigravity,
                .tertiary,
                self.snapshot(primary: primary, secondary: secondary, tertiary: tertiary),
                "tertiary"),
            (.zai, .primary, self.snapshot(primary: nil, secondary: secondary, tertiary: tertiary), "secondary"),
            (.perplexity, .primary, self.snapshot(primary: nil, secondary: secondary, tertiary: tertiary), "secondary"),
            (.antigravity, .primary, self.snapshot(primary: nil, secondary: nil, tertiary: tertiary), "tertiary"),
            (.zai, .secondary, self.snapshot(primary: primary, secondary: nil, tertiary: tertiary), "primary"),
            (.perplexity, .secondary, self.snapshot(primary: primary, secondary: nil, tertiary: tertiary), "tertiary"),
            (.antigravity, .secondary, self.snapshot(primary: primary, secondary: nil, tertiary: tertiary), "primary"),
        ]

        for (provider, preference, snapshot, expected) in fixtures {
            let selected = MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: false,
                now: self.now)
            #expect(selected?.resetDescription == expected, "Unexpected \(preference) lane for \(provider.rawValue)")
        }
    }

    @Test
    func `semantic windows and legacy percent migration preserve Kimi lane inversion`() {
        let primary = RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: "weekly")
        let secondary = RateWindow(usedPercent: 50, windowMinutes: 180, resetsAt: nil, resetDescription: "session")
        let snapshot = self.snapshot(primary: primary, secondary: secondary)

        let kimi = MenuBarLayoutSemanticWindowResolver.windows(provider: .kimi, snapshot: snapshot)
        let generic = MenuBarLayoutSemanticWindowResolver.windows(provider: .zai, snapshot: snapshot)

        #expect(kimi.session == secondary)
        #expect(kimi.weekly == primary)
        #expect(generic.session == secondary)
        #expect(generic.weekly == nil)
        #expect(MenuBarLayout.migrated(
            iconStyle: .bars,
            displayMode: .percent,
            metricPreference: .primary,
            resetTimeDisplayStyle: .countdown,
            provider: .kimi).lines == [[.icon, .percent(window: .weekly)]])
        #expect(MenuBarLayout.migrated(
            iconStyle: .bars,
            displayMode: .percent,
            metricPreference: .secondary,
            resetTimeDisplayStyle: .countdown,
            provider: .kimi).lines == [[.icon, .percent(window: .session)]])
    }

    @Test
    func `session pace eligibility matrix is pinned`() {
        let fixtures: [(UsageProvider, Int?, Bool)] = [
            (.codex, nil, true),
            (.codex, 300, true),
            (.codex, 540, true),
            (.codex, 10080, false),
            (.codex, 43200, false),
            (.claude, nil, true),
            (.ollama, nil, false),
            (.ollama, 300, true),
            (.antigravity, nil, true),
            (.antigravity, 300, true),
            (.antigravity, 301, false),
            (.kimi, 180, false),
            (.kimi, 300, true),
            (.notion, nil, false),
            (.notion, 360, true),
            (.notion, 361, false),
            (.zai, 300, true),
            (.zai, 301, false),
        ]

        for (provider, minutes, expected) in fixtures {
            let window = RateWindow(
                usedPercent: 50,
                windowMinutes: minutes,
                resetsAt: self.now.addingTimeInterval(3600),
                resetDescription: nil)
            #expect(
                (UsagePaceText.sessionPace(provider: provider, window: window, now: self.now) != nil) == expected,
                "Unexpected session pace eligibility for \(provider.rawValue):\(String(describing: minutes))")
        }
    }

    @Test
    @MainActor
    func `decorated icon style membership is pinned`() throws {
        let decoratedStyles: Set<IconStyle> = [.codex, .claude, .gemini, .antigravity, .factory, .warp]
        for style in IconStyle.allCases {
            let decorated = IconRenderer.makeIcon(
                primaryRemaining: 60,
                weeklyRemaining: 40,
                creditsRemaining: nil,
                stale: false,
                style: style,
                hideCritters: false)
            let plain = IconRenderer.makeIcon(
                primaryRemaining: 60,
                weeklyRemaining: 40,
                creditsRemaining: nil,
                stale: false,
                style: style,
                hideCritters: true)
            #expect(
                try (#require(decorated.tiffRepresentation) != #require(plain.tiffRepresentation))
                    == decoratedStyles.contains(style),
                "Unexpected icon decoration membership for \(style.rawValue)")
        }
    }

    @Test
    func `credit visibility exceptions are pinned`() {
        let codex = ProviderDescriptorRegistry.descriptor(for: .codex).metadata
        let amp = ProviderDescriptorRegistry.descriptor(for: .amp).metadata
        let openRouter = ProviderDescriptorRegistry.descriptor(for: .openrouter).metadata
        let snapshot = self.snapshot(primary: RateWindow(
            usedPercent: 20,
            windowMinutes: nil,
            resetsAt: nil,
            resetDescription: nil))

        #expect(UsageMenuCardView.Model.creditsLine(
            metadata: codex,
            snapshot: nil,
            credits: nil,
            error: nil) == nil)
        #expect(UsageMenuCardView.Model.creditsLine(
            metadata: amp,
            snapshot: snapshot,
            credits: nil,
            error: nil) == nil)
        #expect(UsageMenuCardView.Model.creditsLine(
            metadata: openRouter,
            snapshot: snapshot,
            credits: nil,
            error: nil) == openRouter.creditsHint)
    }

    @Test
    func `history series selection special cases are pinned`() {
        let session = RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let weekly = RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)
        let monthly = RateWindow(usedPercent: 30, windowMinutes: 43200, resetsAt: nil, resetDescription: nil)
        let histories = [
            self.history(.session, minutes: 300),
            self.history(.weekly, minutes: 10080),
            self.history(.opus, minutes: 10080),
            self.history(.monthly, minutes: 43200),
        ]

        let fixtures: [(UsageProvider, UsageSnapshot, [String])] = [
            (
                .codex,
                self.snapshot(primary: session, secondary: weekly, tertiary: monthly),
                ["session:300", "weekly:10080"]),
            (
                .claude,
                self.snapshot(primary: session, secondary: weekly, tertiary: weekly),
                ["session:300", "weekly:10080", "opus:10080"]),
            (
                .opencodego,
                self.snapshot(primary: session, secondary: weekly, tertiary: monthly),
                ["session:300", "weekly:10080", "monthly:43200"]),
            (.zai, self.snapshot(primary: session, secondary: weekly, tertiary: monthly), ["weekly:10080"]),
        ]

        for (provider, snapshot, expected) in fixtures {
            let model = PlanUtilizationHistoryChartMenuView._modelSnapshotForTesting(
                histories: histories,
                provider: provider,
                snapshot: snapshot)
            #expect(model.visibleSeries == expected, "Unexpected history series for \(provider.rawValue)")
        }
    }

    @Test
    func `widget row caps and burn down global cap providers are pinned`() throws {
        let antigravityRows = [
            WidgetSnapshot.WidgetUsageRowSnapshot(
                id: "antigravity-quota-summary-gemini-session",
                title: "Gemini",
                percentLeft: 80),
        ]
        let rowFixtures: [(UsageProvider, [WidgetSnapshot.WidgetUsageRowSnapshot]?, Int?, Int?)] = [
            (.kimi, nil, 3, 3),
            (.antigravity, antigravityRows, 2, 3),
            (.antigravity, nil, nil, nil),
            (.codex, nil, nil, nil),
        ]
        for (provider, rows, small, medium) in rowFixtures {
            let entry = self.widgetEntry(provider: provider, usageRows: rows)
            #expect(WidgetUsageRow.smallWidgetRowLimit(for: entry) == small)
            #expect(WidgetUsageRow.mediumWidgetRowLimit(for: entry) == medium)
        }

        for provider in UsageProvider.allCases {
            let entry = self.widgetEntry(
                provider: provider,
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))
            let state = try #require(BurnDownState(
                snapshot: WidgetSnapshot(
                    entries: [entry],
                    enabledProviders: [provider.instanceID],
                    generatedAt: self.now),
                provider: provider,
                selection: .session,
                now: self.now))
            #expect(state.secondaryGloballyCapsPrimary == [.codex, .claude].contains(provider))
        }
    }

    private func snapshot(
        primary: RateWindow?,
        secondary: RateWindow? = nil,
        tertiary: RateWindow? = nil) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: primary,
            secondary: secondary,
            tertiary: tertiary,
            updatedAt: self.now)
    }

    private func history(_ name: PlanUtilizationSeriesName, minutes: Int) -> PlanUtilizationSeriesHistory {
        PlanUtilizationSeriesHistory(
            name: name,
            windowMinutes: minutes,
            entries: [PlanUtilizationHistoryEntry(capturedAt: self.now, usedPercent: 10, resetsAt: nil)])
    }

    private func widgetEntry(
        provider: UsageProvider,
        primary: RateWindow? = nil,
        secondary: RateWindow? = nil,
        usageRows: [WidgetSnapshot.WidgetUsageRowSnapshot]? = nil) -> WidgetSnapshot.ProviderEntry
    {
        WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: self.now,
            primary: primary,
            secondary: secondary,
            tertiary: nil,
            usageRows: usageRows,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
    }
}
