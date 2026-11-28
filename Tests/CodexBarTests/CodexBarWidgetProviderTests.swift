import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore
@testable import CodexBarWidget

struct CodexBarWidgetProviderTests {
    @Test
    func `widget token counts use compact shared formatting`() {
        #expect(WidgetFormat.tokenCount(999) == "999 tokens")
        #expect(WidgetFormat.tokenCount(9_400_000) == "9.4M tokens")
        #expect(WidgetFormat.tokenCount(94_500_000) == "94M tokens")
        #expect(WidgetFormat.tokenCount(10_600_000_000) == "11B tokens")
    }

    @Test
    func `usage display follows remaining and used preference`() {
        #expect(WidgetUsageDisplay.percent(fromRemaining: 48, showUsed: false) == 48)
        #expect(WidgetUsageDisplay.percent(fromRemaining: 48, showUsed: true) == 52)
        #expect(WidgetUsageDisplay.percent(fromRemaining: nil, showUsed: true) == nil)
    }

    @Test
    func `small widget falls back to local cost when quota rows are unavailable`() {
        let tokenUsage = WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: 1.25,
            sessionTokens: 4200,
            last30DaysCostUSD: 12.50,
            last30DaysTokens: 42000,
            currencyCode: "USD",
            sessionLabel: "Today",
            last30DaysLabel: "30d")
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: tokenUsage,
            dailyUsage: [])
        let windowedEntry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Date(),
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            usageRows: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: tokenUsage,
            dailyUsage: [])

        #expect(WidgetUsageRow.compactTokenUsage(for: entry)?.sessionTokens == 4200)
        #expect(WidgetUsageRow.compactTokenUsage(for: windowedEntry) == nil)
    }

    @Test
    func `small widget limits custom usage rows`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .antigravity,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "one", title: "One", percentLeft: 90),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "two", title: "Two", percentLeft: 80),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "three", title: "Three", percentLeft: 70),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "four", title: "Four", percentLeft: 60),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        #expect(WidgetUsageRow.rows(for: entry, limit: 2).map(\.id) == ["one", "two"])
        #expect(WidgetUsageRow.rows(for: entry).count == 4)
    }

    @Test
    func `small antigravity widget keeps one row per quota family`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .antigravity,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-gemini-session",
                    title: "Gemini Models Five Hour Limit",
                    percentLeft: 80),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Models Weekly Limit",
                    percentLeft: 20),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-third-party-session",
                    title: "Claude and GPT models Five Hour Limit",
                    percentLeft: 5),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-third-party-weekly",
                    title: "Claude and GPT models Weekly Limit",
                    percentLeft: 60),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry, limit: 2)

        #expect(rows.map(\.title) == ["Gemini Models Weekly Limit", "Claude and GPT models Five Hour Limit"])
        #expect(rows.compactMap(\.percentLeft) == [20, 5])
        #expect(WidgetUsageRow.smallWidgetRowLimit(for: entry) == 2)
        #expect(WidgetUsageRow.mediumWidgetRowLimit(for: entry) == 3)
        let mediumRows = WidgetUsageRow.rows(
            for: entry,
            limit: WidgetUsageRow.mediumWidgetRowLimit(for: entry))
        #expect(mediumRows.map(\.title) == [
            "Gemini Models Weekly Limit",
            "Claude and GPT models Five Hour Limit",
            "Claude and GPT models Weekly Limit",
        ])
    }

    @Test
    func `small antigravity widget keeps claude gpt family when fallback rows are more constrained`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .antigravity,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-gemini-5h",
                    title: "Gemini Models Five Hour Limit",
                    percentLeft: 40),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Models Weekly Limit",
                    percentLeft: 70),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-3p-5h",
                    title: "Claude and GPT models Five Hour Limit",
                    percentLeft: 60),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-other-5h",
                    title: "Other Five Hour Limit",
                    percentLeft: 1),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry, limit: 2)

        #expect(rows.map(\.id) == [
            "antigravity-quota-summary-gemini-5h",
            "antigravity-quota-summary-3p-5h",
        ])
    }

    @Test
    func `small widget preserves tertiary rows for other providers`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .cursor,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "one", title: "One", percentLeft: 90),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "two", title: "Two", percentLeft: 80),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "three", title: "Three", percentLeft: 70),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let limit = WidgetUsageRow.smallWidgetRowLimit(for: entry)

        #expect(limit == nil)
        #expect(WidgetUsageRow.rows(for: entry, limit: limit).map(\.id) == ["one", "two", "three"])
    }

    @Test
    func `small antigravity widget prefers known quota rows`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .antigravity,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-gemini-session",
                    title: "Gemini Models Five Hour Limit",
                    percentLeft: nil),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Models Weekly Limit",
                    percentLeft: 100),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-third-party-session",
                    title: "Claude and GPT models Five Hour Limit",
                    percentLeft: 80),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry, limit: 2)

        #expect(rows.map(\.title) == ["Gemini Models Weekly Limit", "Claude and GPT models Five Hour Limit"])
    }

    @Test
    func `small antigravity widget keeps nonstandard quota groups visible`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .antigravity,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-other-session",
                    title: "Other Session",
                    percentLeft: 70),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-other-weekly",
                    title: "Other Weekly",
                    percentLeft: 40),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry, limit: 2)

        #expect(rows.map(\.title) == ["Other Weekly", "Other Session"])
    }

    @Test
    func `provider choice supports alibaba`() {
        #expect(ProviderChoice(provider: .alibaba) == .alibaba)
        #expect(ProviderChoice.alibaba.provider == .alibaba)
    }

    @Test
    func `provider choice supports alibaba token plan`() {
        #expect(ProviderChoice(provider: .alibabatokenplan) == .alibabatokenplan)
        #expect(ProviderChoice.alibabatokenplan.provider == .alibabatokenplan)
    }

    @Test
    func `provider choice supports opencode go`() {
        #expect(ProviderChoice(provider: .opencodego) == .opencodego)
        #expect(ProviderChoice.opencodego.provider == .opencodego)
    }

    @Test
    func `provider choice supports devin`() {
        #expect(ProviderChoice(provider: .devin) == .devin)
        #expect(ProviderChoice.devin.provider == .devin)
    }

    @Test
    func `widget entry carries devin overage balance through providerCost`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .devin,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            providerCost: ProviderCostSnapshot(
                used: 48.0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let encoded = try? JSONEncoder().encode(entry)
        #expect(encoded != nil)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(WidgetSnapshot.ProviderEntry.self, from: $0) }
        #expect(decoded?.providerCost?.period == "Extra usage balance")
        #expect(decoded?.providerCost?.used == 48.0)
        #expect(decoded?.providerCost?.limit == 0)
        #expect(decoded?.provider == .devin)
    }

    @Test
    func `widget balance formatter renders devin extra usage balance`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .devin,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            providerCost: ProviderCostSnapshot(
                used: 48.0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let line = WidgetBalanceFormatter.extraUsageBalance(for: entry)
        #expect(line?.title == "Extra usage")
        #expect(line?.value.hasPrefix("Balance: ") == true)
        #expect(line?.value.contains("48") == true)
    }

    @Test
    func `compact credits render Devin extra usage balance`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .devin,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            providerCost: ProviderCostSnapshot(
                used: 48.0,
                limit: 0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        let display = CompactMetricFormatter.display(for: entry, metric: .credits)

        #expect(display.value.contains("48"))
        #expect(display.label == "Extra usage balance")
        #expect(display.detail == nil)
    }

    @Test
    func `widget balance formatter does not leak another provider balance`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .factory,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [],
            providerCost: ProviderCostSnapshot(
                used: 12.0,
                limit: 100.0,
                currencyCode: "USD",
                period: "Extra usage balance",
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(WidgetBalanceFormatter.extraUsageBalance(for: entry) == nil)
    }

    @Test
    func `provider choice supports Mistral`() {
        #expect(ProviderChoice(provider: .mistral) == .mistral)
        #expect(ProviderChoice.mistral.provider == .mistral)
    }

    @Test
    func `provider choice supports Kimi`() {
        #expect(ProviderChoice(provider: .kimi) == .kimi)
        #expect(ProviderChoice.kimi.provider == .kimi)
    }

    @Test
    func `compact Kimi widgets keep established row fit while large widgets show all quotas`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .kimi,
            updatedAt: now,
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "primary", title: "7-day usage", percentLeft: 75),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "secondary", title: "5-hour usage", percentLeft: 50),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "kimi-monthly", title: "Total usage", percentLeft: 25),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "kimi-code-7d", title: "Code 7-day", percentLeft: 90),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let smallRows = WidgetUsageRow.rows(
            for: entry,
            limit: WidgetUsageRow.smallWidgetRowLimit(for: entry))
        let mediumRows = WidgetUsageRow.rows(
            for: entry,
            limit: WidgetUsageRow.mediumWidgetRowLimit(for: entry))
        let largeRows = WidgetUsageRow.rows(for: entry)

        #expect(WidgetUsageRow.smallWidgetRowLimit(for: entry) == 3)
        #expect(WidgetUsageRow.mediumWidgetRowLimit(for: entry) == 3)
        #expect(smallRows.map(\.id) == ["primary", "secondary", "kimi-monthly"])
        #expect(mediumRows == smallRows)
        #expect(largeRows.map(\.id) == ["primary", "secondary", "kimi-monthly", "kimi-code-7d"])
    }

    @Test
    func `provider choice excludes unsupported Chutes widgets`() {
        #expect(ProviderChoice(provider: .chutes) == nil)
        #expect(ProviderChoice(provider: .sub2api) == nil)
    }

    @Test
    func `supported providers fall back to codex when snapshot is empty`() {
        let snapshot = WidgetSnapshot(entries: [], enabledProviders: [], generatedAt: Date())

        #expect(CodexBarSwitcherTimelineProvider.supportedProviders(from: snapshot) == [.codex])
    }

    @Test
    func `supported providers keep alibaba when it is the only enabled provider`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .alibaba,
            updatedAt: now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], enabledProviders: [.alibaba], generatedAt: now)

        #expect(CodexBarSwitcherTimelineProvider.supportedProviders(from: snapshot) == [.alibaba])
    }

    @Test
    func `supported providers keep alibaba token plan when it is the only enabled provider`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .alibabatokenplan,
            updatedAt: now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], enabledProviders: [.alibabatokenplan], generatedAt: now)

        #expect(CodexBarSwitcherTimelineProvider.supportedProviders(from: snapshot) == [.alibabatokenplan])
    }

    @Test
    func `supported providers keep Mistral when it is the only enabled provider`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .mistral,
            updatedAt: now,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], enabledProviders: [.mistral], generatedAt: now)

        #expect(CodexBarSwitcherTimelineProvider.supportedProviders(from: snapshot) == [.mistral])
    }

    @Test
    func `supported providers keep Kimi when it is the only enabled provider`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .kimi,
            updatedAt: now,
            primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], enabledProviders: [.kimi], generatedAt: now)

        #expect(CodexBarSwitcherTimelineProvider.supportedProviders(from: snapshot) == [.kimi])
    }

    @Test
    func `codex weekly only widget rows omit session`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: now,
            primary: nil,
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry)

        #expect(rows.count == 1)
        #expect(rows.first?.title == "Weekly")
        #expect(rows.first?.percentLeft == 75)
    }

    @Test
    func `codex widget usage rows keep code review separate from rate rows`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: now,
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: 60,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry)

        #expect(rows.map(\.title) == ["Session", "Weekly"])
        #expect(rows.count == 2)
        #expect(!rows.contains { $0.title == "Code review" })
    }

    @Test
    func `widget usage rows prefer projected rows over legacy slots`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: now,
            primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 25, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "weekly", title: "Weekly", percentLeft: 75),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry)

        #expect(rows == [WidgetUsageRow(id: "weekly", title: "Weekly", percentLeft: 75)])
    }

    @Test
    func `codex widget session cap lifts at weekly reset without a new snapshot`() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let weeklyReset = now.addingTimeInterval(3600)
        let sessionWindow = RateWindow(
            usedPercent: 1,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(1800),
            resetDescription: nil)
        let weeklyWindow = RateWindow(
            usedPercent: 100,
            windowMinutes: 10080,
            resetsAt: weeklyReset,
            resetDescription: nil)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: now.addingTimeInterval(-7200),
            primary: sessionWindow,
            secondary: weeklyWindow,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "session",
                    title: "Session",
                    percentLeft: 99,
                    window: sessionWindow),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "weekly",
                    title: "Weekly",
                    percentLeft: 0,
                    window: weeklyWindow),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let capped = WidgetUsageRow.rows(for: entry, now: now)
        let reset = WidgetUsageRow.rows(for: entry, now: weeklyReset)

        #expect(capped.map(\.percentLeft) == [0, 0])
        #expect(reset.map(\.percentLeft) == [99, 0])
    }

    @Test
    func `legacy widget usage rows use antigravity grouped slots`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .antigravity,
            updatedAt: now,
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry)

        #expect(rows.map(\.id) == ["primary", "secondary"])
        #expect(rows.map(\.title) == ["Gemini Models", "Claude and GPT"])
        #expect(rows.compactMap(\.percentLeft) == [90, 80])
    }

    @Test
    func `widget configuration intents default to codex and credits`() {
        let providerIntent = ProviderSelectionIntent()
        let compactIntent = CompactMetricSelectionIntent()
        let burnIntent = BurnDownSelectionIntent()
        let combinedBurnIntent = BurnProviderSelectionIntent()

        #expect(providerIntent.provider == .codex)
        #expect(compactIntent.provider == .codex)
        #expect(compactIntent.metric == .credits)
        #expect(burnIntent.provider == .codex)
        #expect(burnIntent.window == .session)
        #expect(combinedBurnIntent.provider == .codex)
    }

    @Test
    func `burn down uses an exact provider entry`() {
        let snapshot = Self.burnSnapshot(provider: .claude, primaryUsed: 20, secondaryUsed: 30)

        #expect(BurnDownState(snapshot: snapshot, provider: .codex, selection: .session) == nil)
        #expect(BurnDownState(snapshot: snapshot, provider: .claude, selection: .session) != nil)
    }

    @Test
    func `codex exhausted weekly cap blocks the session chart until weekly reset`() throws {
        let weeklyReset = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .codex,
            primaryUsed: 80,
            secondaryUsed: 100,
            primaryReset: weeklyReset.addingTimeInterval(-3600),
            secondaryReset: weeklyReset)
        let state = try #require(BurnDownState(snapshot: snapshot, provider: .codex, selection: .session))

        #expect(state.secondaryGloballyCapsPrimary)
        #expect(state.primaryWindow?.remainingPercent == 0)
        #expect(state.blankPrimaryChart)
        #expect(state.selectedResetOverride == weeklyReset)
    }

    @Test
    func `gemini exhausted secondary window does not block the independent primary`() throws {
        let primaryReset = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .gemini,
            primaryUsed: 20,
            secondaryUsed: 100,
            primaryReset: primaryReset,
            secondaryReset: primaryReset.addingTimeInterval(-3600))
        let state = try #require(BurnDownState(snapshot: snapshot, provider: .gemini, selection: .session))

        #expect(!state.secondaryGloballyCapsPrimary)
        #expect(state.primaryWindow?.remainingPercent == 80)
        #expect(!state.blankPrimaryChart)
        #expect(state.selectedResetOverride == nil)
    }

    @Test
    func `independent secondary reset never overrides primary reset`() throws {
        let primaryReset = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .gemini,
            primaryUsed: 20,
            secondaryUsed: 30,
            primaryReset: primaryReset,
            secondaryReset: primaryReset.addingTimeInterval(-3600))
        let state = try #require(BurnDownState(snapshot: snapshot, provider: .gemini, selection: .session))

        #expect(state.selectedWindow?.resetsAt == primaryReset)
        #expect(state.selectedResetOverride == nil)
    }

    @Test
    func `burn down preview includes session and weekly windows`() throws {
        let snapshot = WidgetPreviewData.snapshot()

        let session = try #require(BurnDownState(snapshot: snapshot, provider: .codex, selection: .session))
        let weekly = try #require(BurnDownState(snapshot: snapshot, provider: .codex, selection: .weekly))

        #expect(session.selectedWindow?.windowMinutes == 300)
        #expect(weekly.selectedWindow?.windowMinutes == 10080)
    }

    @Test
    func `burn down selection does not fall back to another window`() throws {
        let weeklyOnly = Self.burnSnapshot(provider: .codex, primaryUsed: nil, secondaryUsed: 30)
        let sessionOnly = Self.burnSnapshot(provider: .codex, primaryUsed: 20, secondaryUsed: nil)
        let weeklyStoredInPrimary = Self.burnSnapshot(
            provider: .claude,
            primaryUsed: 30,
            secondaryUsed: nil,
            primaryWindowMinutes: 7 * 24 * 60)

        let weeklyOnlySession = try #require(BurnDownState(
            snapshot: weeklyOnly,
            provider: .codex,
            selection: .session))
        let weeklyOnlyWeekly = try #require(BurnDownState(
            snapshot: weeklyOnly,
            provider: .codex,
            selection: .weekly))
        let sessionOnlySession = try #require(BurnDownState(
            snapshot: sessionOnly,
            provider: .codex,
            selection: .session))
        let sessionOnlyWeekly = try #require(BurnDownState(
            snapshot: sessionOnly,
            provider: .codex,
            selection: .weekly))
        let weeklyPrimarySession = try #require(BurnDownState(
            snapshot: weeklyStoredInPrimary,
            provider: .claude,
            selection: .session))
        let weeklyPrimaryWeekly = try #require(BurnDownState(
            snapshot: weeklyStoredInPrimary,
            provider: .claude,
            selection: .weekly))

        #expect(weeklyOnlySession.selectedWindow == nil)
        #expect(weeklyOnlyWeekly.selectedWindow == weeklyOnlyWeekly.secondaryWindow)
        #expect(sessionOnlySession.selectedWindow == sessionOnlySession.primaryWindow)
        #expect(sessionOnlyWeekly.selectedWindow == nil)
        #expect(weeklyPrimarySession.selectedWindow == nil)
        #expect(weeklyPrimaryWeekly.selectedWindow?.usedPercent == 30)
    }

    @Test
    func `expired weekly reset no longer blocks the session chart`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .codex,
            primaryUsed: 20,
            secondaryUsed: 100,
            primaryReset: now.addingTimeInterval(300),
            secondaryReset: now.addingTimeInterval(-1))
        let state = try #require(BurnDownState(
            snapshot: snapshot,
            provider: .codex,
            selection: .session,
            now: now))

        #expect(!state.secondaryExhausted)
        #expect(state.primaryWindow?.remainingPercent == 80)
        #expect(!state.blankPrimaryChart)
        #expect(state.selectedResetOverride == nil)
    }

    @Test
    func `explicit reset takes precedence over estimated reset`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let future = now.addingTimeInterval(600)

        #expect(burnEffectiveResetDate(
            explicitResetAt: now.addingTimeInterval(-1),
            estimatedResetMinutes: 5,
            now: now) == nil)
        #expect(burnEffectiveResetDate(
            explicitResetAt: future,
            estimatedResetMinutes: 5,
            now: now) == future)
        #expect(burnEffectiveResetDate(
            explicitResetAt: nil,
            estimatedResetMinutes: 5,
            now: now) == now.addingTimeInterval(300))
        #expect(burnEffectiveResetDate(
            explicitResetAt: nil,
            estimatedResetMinutes: nil,
            now: now) == nil)
    }

    @Test
    func `burn down axis shares the effective estimated reset`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let effectiveReset = try #require(burnEffectiveResetDate(
            explicitResetAt: nil,
            estimatedResetMinutes: 90,
            now: now))

        let axis = burnAxisDateRange(
            effectiveResetAt: effectiveReset,
            windowMinutes: 300,
            now: now)

        #expect(axis.reset == effectiveReset)
        #expect(axis.start == effectiveReset.addingTimeInterval(-5 * 60 * 60))
    }

    @Test
    func `burn down refreshes immediately after the earliest future reset`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .codex,
            primaryUsed: 20,
            secondaryUsed: 30,
            primaryReset: now.addingTimeInterval(360),
            secondaryReset: now.addingTimeInterval(420))

        #expect(BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: .codex, now: now)
            == now.addingTimeInterval(361))
    }

    @Test
    func `burn down refresh clamps to minimum interval`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .codex,
            primaryUsed: 20,
            secondaryUsed: 30,
            primaryReset: now.addingTimeInterval(60),
            secondaryReset: now.addingTimeInterval(120))

        #expect(BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: .codex, now: now)
            == now.addingTimeInterval(300))
    }

    @Test
    func `burn down refresh ignores past resets and unrelated provider entries`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = Self.burnSnapshot(
            provider: .claude,
            primaryUsed: 20,
            secondaryUsed: 30,
            primaryReset: now.addingTimeInterval(-60),
            secondaryReset: now.addingTimeInterval(-30))
        let fallback = now.addingTimeInterval(30 * 60)

        #expect(BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: .claude, now: now) == fallback)
        #expect(BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: .codex, now: now) == fallback)
    }

    private static func burnSnapshot(
        provider: UsageProvider,
        primaryUsed: Double?,
        secondaryUsed: Double?,
        primaryReset: Date? = Date(timeIntervalSince1970: 1_800_000_000),
        secondaryReset: Date? = Date(timeIntervalSince1970: 1_800_000_000),
        primaryWindowMinutes: Int = 5 * 60,
        secondaryWindowMinutes: Int = 7 * 24 * 60) -> WidgetSnapshot
    {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            primary: primaryUsed.map {
                RateWindow(
                    usedPercent: $0,
                    windowMinutes: primaryWindowMinutes,
                    resetsAt: primaryReset,
                    resetDescription: nil)
            },
            secondary: secondaryUsed.map {
                RateWindow(
                    usedPercent: $0,
                    windowMinutes: secondaryWindowMinutes,
                    resetsAt: secondaryReset,
                    resetDescription: nil)
            },
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        return WidgetSnapshot(entries: [entry], generatedAt: entry.updatedAt)
    }
}

extension CodexBarWidgetProviderTests {
    @Test
    func `switching saves selection before reloading only the stable switcher kind`() {
        var events: [String] = []
        SwitchWidgetProviderIntent(provider: .claude).switchProvider(
            saveSelection: { events.append("save:\($0.rawValue)") },
            reloadTimelines: { events.append("reload:\($0)") })

        #expect(events == ["save:claude", "reload:CodexBarSwitcherWidget"])
    }

    @Test
    func `provider choice supports Cursor`() {
        #expect(ProviderChoice(provider: .cursor) == .cursor)
        #expect(ProviderChoice.cursor.provider == .cursor)
    }

    @Test
    func `supported providers keep Cursor when it is the only enabled provider`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .cursor,
            updatedAt: now,
            primary: RateWindow(usedPercent: 25, windowMinutes: 43200, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], enabledProviders: [.cursor], generatedAt: now)

        #expect(CodexBarSwitcherTimelineProvider.supportedProviders(from: snapshot) == [.cursor])
    }

    @Test
    func `compact cost labels retain billing disclosure without baking in a stale age`() {
        let entryUpdatedAt = Date()
        let staleToken = WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: 1.25,
            sessionTokens: 4200,
            last30DaysCostUSD: 12.50,
            last30DaysTokens: 42000,
            updatedAt: entryUpdatedAt.addingTimeInterval(-45 * 60))
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .codex,
            updatedAt: entryUpdatedAt,
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: staleToken,
            dailyUsage: [])
        let todayMetric = CompactMetricFormatter.display(for: entry, metric: .todayCost)
        let historyMetric = CompactMetricFormatter.display(for: entry, metric: .last30DaysCost)

        #expect(todayMetric.label == "Today API est. · not billed")
        #expect(historyMetric.label == "30d API est. · not billed")
        #expect(CompactMetricFormatter.costMetricLabel("7d", provider: .codex) == "7d API est. · not billed")
        #expect(CompactMetricFormatter.costMetricLabel("90d", provider: .codex) == "90d API est. · not billed")
        #expect(CompactMetricFormatter.costMetricLabel("This month", provider: .codex) ==
            "This month API est. · not billed")
        #expect(CompactMetricFormatter.costMetricLabel(
            "This month API est. · not billed",
            provider: .codex) == "This month API est. · not billed")
    }

    @Test
    func `usage history chart mode requires every point to expose cost`() {
        let costPoints = [
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-01", totalTokens: 100, costUSD: 1.2),
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-02", totalTokens: 200, costUSD: 2.4),
        ]
        let tokenPoints = [
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-01", totalTokens: 100, costUSD: nil),
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-02", totalTokens: 200, costUSD: nil),
        ]
        let mixedPoints = [
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-01", totalTokens: 100, costUSD: 1.2),
            WidgetSnapshot.DailyUsagePoint(dayKey: "2026-07-02", totalTokens: 200, costUSD: nil),
        ]
        let emptyPoints: [WidgetSnapshot.DailyUsagePoint] = []

        #expect(UsageHistoryChartMode.isCostMode(costPoints) == true)
        #expect(UsageHistoryChartMode.isCostMode(tokenPoints) == false)
        #expect(UsageHistoryChartMode.isCostMode(mixedPoints) == false)
        #expect(UsageHistoryChartMode.isCostMode(emptyPoints) == false)
    }

    @MainActor
    @Test
    func `deepseek 365-day widget export strips detail charts and keeps missing cost nil`() async throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = Self.utcGregorianCalendar
        let plan = DeepSeekHistoryPlan.make(period: .allTime, now: now, calendar: utc)
        let fixture = try Self.make365DayDeepSeekFixture(now: now, calendar: utc, plan: plan)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DeepSeekWidgetSize-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotURL = root.appendingPathComponent("widget-snapshot.json", isDirectory: false)

        let settings = testSettingsStore(
            suiteName: "CodexBarWidgetProviderTests-deepseek-size",
            config: testConfigWithAllProvidersDisabled())
        settings.showOptionalCreditsAndExtraUsage = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(homeDirectory: root.path, fileExists: { _ in false }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            widgetSnapshotURL: snapshotURL)
        defer { store.stopSharedSpendDashboardPublication() }

        let otherChart = try ProviderDetailSection.Chart(
            kind: .bars,
            title: "Daily tokens",
            unit: "tokens",
            points: [
                .init(label: "2026-06-13", value: 100),
                .init(label: "2026-06-14", value: 200),
                .init(label: "2026-06-15", value: 300),
            ])
        let otherDetails = try [ProviderDetailSection(
            title: "Cloud credits",
            rows: [ProviderDetailSection.Row(label: "Remaining", value: "$12.00")],
            chart: otherChart)]
        let quota = RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        store._setSnapshotForTesting(fixture.usageSnapshot, provider: .deepseek)
        store._setTokenSnapshotForTesting(fixture.usageSnapshot.costUsage, provider: .deepseek)
        store._setSnapshotForTesting(
            UsageSnapshot(primary: quota, secondary: nil, details: otherDetails, updatedAt: now),
            provider: .claude)

        store.persistWidgetSnapshot(reason: "deepseek-widget-size")
        await store.widgetSnapshotPersistTask?.value

        let afterData = try Data(contentsOf: snapshotURL)
        let decoded = try #require(WidgetSnapshotStore.load(from: snapshotURL))
        let deepseekEntry = try #require(decoded.entries.first { $0.provider == .deepseek })
        let otherEntry = try #require(decoded.entries.first { $0.provider == .claude })

        var beforeSnapshot = decoded
        beforeSnapshot.entries = decoded.entries.map { entry in
            guard entry.provider == .deepseek else { return entry }
            return WidgetSnapshot.ProviderEntry(
                instanceID: entry.provider,
                updatedAt: entry.updatedAt,
                primary: entry.primary,
                secondary: entry.secondary,
                tertiary: entry.tertiary,
                usageRows: entry.usageRows,
                creditsRemaining: entry.creditsRemaining,
                codeReviewRemainingPercent: entry.codeReviewRemainingPercent,
                tokenUsage: entry.tokenUsage,
                dailyUsage: entry.dailyUsage,
                providerCost: entry.providerCost,
                quotaOwnerKey: entry.quotaOwnerKey,
                balanceText: entry.balanceText,
                details: fixture.usageSnapshot.details)
        }
        let beforeData = try WidgetSnapshotStore.encodedData(beforeSnapshot)

        let beforeChartPoints = fixture.usageSnapshot.details.compactMap(\.chart).reduce(0) { $0 + $1.points.count }
        let afterChartPoints = (deepseekEntry.details ?? []).compactMap(\.chart).reduce(0) { $0 + $1.points.count }
        print(
            "[deepseek-widget-size] beforeBytes=\(beforeData.count) afterBytes=\(afterData.count) " +
                "savedBytes=\(beforeData.count - afterData.count) " +
                "rawChartPointsBefore=\(beforeChartPoints) rawChartPointsAfter=\(afterChartPoints) " +
                "dailyUsagePoints=\(deepseekEntry.dailyUsage.count)")

        #expect(beforeChartPoints == 2 * ProviderDetailSection.maximumPointsPerChart)
        #expect(afterChartPoints == 0)
        #expect(afterData.count < beforeData.count)
        #expect(beforeData.count - afterData.count > 4000)

        // App-side live snapshot retains its full charts for menu & Settings previews.
        let liveChartPoints = (store.snapshots[.deepseek]?.details ?? [])
            .compactMap(\.chart).reduce(0) { $0 + $1.points.count }
        #expect(liveChartPoints == beforeChartPoints)

        // DeepSeek keeps text rows while dropping emptied chart-only sections; other providers stay untouched.
        let exportedDetails = try #require(deepseekEntry.details)
        #expect(exportedDetails.map(\.title) == ["Usage"])
        #expect(exportedDetails.allSatisfy { $0.chart == nil })
        let usageRowLabels = exportedDetails.first?.rows.map(\.label) ?? []
        #expect(usageRowLabels == ["Today", "Last 365 days", "Requests", "API keys", "Top model"])
        #expect(otherEntry.details == otherDetails)

        // Verify raw serialized JSON on disk omits `chart` for DeepSeek and keeps it for non-DeepSeek.
        let json = try #require(JSONSerialization.jsonObject(with: afterData) as? [String: Any])
        let jsonEntries = try #require(json["entries"] as? [[String: Any]])
        let deepseekJSON = try #require(jsonEntries.first { $0["provider"] as? String == "deepseek" })
        let deepseekJSONDetails = try #require(deepseekJSON["details"] as? [[String: Any]])
        #expect(deepseekJSONDetails.allSatisfy { $0["chart"] == nil })

        // Grouped daily usage stays <= 45 points, preserves exact sums, and keeps missing cost as nil (never 0).
        #expect(deepseekEntry.dailyUsage.count <= 45)
        #expect(deepseekEntry.dailyUsage.count == 27)
        #expect(deepseekEntry.dailyUsage.compactMap(\.totalTokens).reduce(0, +) == fixture.expectedTotalTokens)
        #expect(abs(deepseekEntry.dailyUsage.compactMap(\.costUSD).reduce(0, +) - fixture.expectedPricedCost) < 1e-6)
        let missingCostBucket = try #require(deepseekEntry.dailyUsage.first)
        #expect(missingCostBucket.dayKey == plan.requestedStartDayKey)
        #expect(missingCostBucket.totalTokens == fixture.missingCostDayTokens)
        #expect(missingCostBucket.costUSD == nil)
        #expect(deepseekEntry.tokenUsage?.last30DaysCostUSD == nil)

        // Widget chart renderer helpers consume the retained grouped payload cleanly in cost mode.
        let tokenUsage = try #require(deepseekEntry.tokenUsage)
        let isCostMode = tokenUsage.chartPrefersCostMode ?? UsageHistoryChartMode.isCostMode(deepseekEntry.dailyUsage)
        #expect(UsageHistoryChartMode.isCostMode(deepseekEntry.dailyUsage) == false)
        #expect(isCostMode == true)
        #expect(UsageHistoryChartCopy.title(
            dayCount: deepseekEntry.dailyUsage.count,
            explicitTitle: tokenUsage.chartTitle) == "Last 365 days")
        let maxBucketCost = deepseekEntry.dailyUsage.compactMap(\.costUSD).max() ?? 0
        let peak = try #require(UsageHistoryChartCopy.peak(
            maximum: maxBucketCost,
            isCostMode: isCostMode,
            currencyCode: tokenUsage.currencyCode,
            bucketDays: tokenUsage.chartBucketDays))
        #expect(peak.hasPrefix("Peak "))
        #expect(peak.hasSuffix("/14d"))
        let range = try #require(UsageHistoryChartCopy.range(
            points: deepseekEntry.dailyUsage,
            explicitStartDayKey: tokenUsage.chartStartDayKey,
            explicitEndDayKey: tokenUsage.chartEndDayKey))
        #expect(range.start == WidgetFormat.dayLabel(plan.requestedStartDayKey))
        #expect(range.end == WidgetFormat.dayLabel(plan.requestedEndDayKey))
    }

    @Test
    func `deepseek widget export keeps spend model rows and mixed missing cost stays nil`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z"))
        let utc = Self.utcGregorianCalendar
        let todayStart = utc.startOfDay(for: now)
        func dayKey(daysAgo: Int) throws -> String {
            let date = try #require(utc.date(byAdding: .day, value: -daysAgo, to: todayStart))
            return CostUsageLocalDay.key(from: date, calendar: utc)
        }

        let summaryWithModels = try DeepSeekUsageSummary(
            todayTokens: 100,
            currentMonthTokens: 200,
            todayCost: 0.5,
            currentMonthCost: 1.0,
            requestCount: 1,
            currentMonthRequestCount: 2,
            topModel: "deepseek-chat",
            categoryBreakdown: [],
            daily: [
                DeepSeekDailyUsage(date: dayKey(daysAgo: 1), totalTokens: 100, cost: 0.5, requestCount: 1),
                DeepSeekDailyUsage(date: dayKey(daysAgo: 0), totalTokens: 100, cost: 0.5, requestCount: 1),
            ],
            currency: "USD",
            modelCosts: [DeepSeekModelCost(model: "deepseek-chat", cost: 1.0)],
            apiKeyCount: 1,
            period: .last30Days,
            timeZoneSeconds: 0,
            updatedAt: now)
        let usageSnapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: 10.0,
            grantedBalance: 0,
            toppedUpBalance: 10.0,
            usageSummary: summaryWithModels,
            updatedAt: now).toUsageSnapshot()

        let stripped = try #require(UsageStore.widgetDetails(
            for: .deepseek,
            snapshot: usageSnapshot,
            showOptionalCreditsAndExtraUsage: true))
        #expect(stripped.map(\.title) == ["Usage", "Spend"])
        #expect(stripped.allSatisfy { $0.chart == nil })
        #expect(stripped.last?.rows.map(\.label) == ["deepseek-chat"])
        #expect(UsageStore.widgetDetails(
            for: .deepseek,
            snapshot: usageSnapshot,
            showOptionalCreditsAndExtraUsage: false) == nil)

        // Chart-only snapshot yields nil details instead of an empty array.
        let chartOnlySnapshot = try UsageSnapshot(
            primary: nil,
            secondary: nil,
            details: [ProviderDetailSection(
                title: "Spend",
                rows: [],
                chart: .init(kind: .bars, points: [.init(label: "2026-06-15", value: 1.0)]))],
            updatedAt: now)
        #expect(UsageStore.widgetDetails(
            for: .deepseek,
            snapshot: chartOnlySnapshot,
            showOptionalCreditsAndExtraUsage: true) == nil)

        // A grouped bucket mixing a priced day and a missing-cost day must keep costUSD == nil (never 0 or partial).
        let d0 = try dayKey(daysAgo: 0)
        let d1 = try dayKey(daysAgo: 1)
        let d2 = try dayKey(daysAgo: 2)
        let d3 = try dayKey(daysAgo: 3)
        let d89 = try dayKey(daysAgo: 89)
        let mixedSnapshot = try CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 1.0,
            last30DaysTokens: 900,
            last30DaysCostUSD: nil,
            currencyCode: "USD",
            historyDays: 90,
            coveredDayIntervals: [
                CostUsageDayInterval(startDay: d89, endDay: dayKey(daysAgo: 60)),
                CostUsageDayInterval(startDay: dayKey(daysAgo: 29), endDay: d0),
            ],
            daily: [
                CostUsageDailyReport.Entry(
                    date: d89,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    costUSD: 1.0,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                CostUsageDailyReport.Entry(
                    date: d3,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 200,
                    costUSD: 2.0,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                CostUsageDailyReport.Entry(
                    date: d2,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 300,
                    costUSD: nil,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                CostUsageDailyReport.Entry(
                    date: d1,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 200,
                    costUSD: 2.0,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                CostUsageDailyReport.Entry(
                    date: d0,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: 100,
                    costUSD: 1.0,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let projection = UsageStore.deepSeekWidgetChartProjection(from: mixedSnapshot)
        #expect(projection.bucketDays == 2)
        let mixedBucket = try #require(projection.points.first { $0.dayKey == d3 })
        #expect(mixedBucket.totalTokens == 500)
        #expect(mixedBucket.costUSD == nil)
        let newestBucket = try #require(projection.points.last)
        #expect(newestBucket.dayKey == d0)
        #expect(newestBucket.totalTokens == 300)
        #expect(newestBucket.costUSD == 3.0)
        // Interior uncovered gap stays nil for both tokens and cost.
        #expect(projection.points.contains { $0.totalTokens == nil && $0.costUSD == nil })
    }

    private struct DeepSeek365DayFixture {
        let usageSnapshot: UsageSnapshot
        let expectedTotalTokens: Int
        let expectedPricedCost: Double
        let missingCostDayTokens: Int
    }

    private static var utcGregorianCalendar: Calendar {
        CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: 0)
    }

    private static func make365DayDeepSeekFixture(
        now: Date,
        calendar: Calendar,
        plan: DeepSeekHistoryPlan) throws -> DeepSeek365DayFixture
    {
        let startOfToday = calendar.startOfDay(for: now)
        let missingCostDayTokens = 750
        var daily: [DeepSeekDailyUsage] = []
        var expectedPricedCost = 0.0
        var expectedTotalTokens = 0
        for daysAgo in 0..<365 {
            let date = try #require(calendar.date(byAdding: .day, value: -daysAgo, to: startOfToday))
            let key = CostUsageLocalDay.key(from: date, calendar: calendar)
            if daysAgo == 364 {
                expectedTotalTokens += missingCostDayTokens
                daily.append(DeepSeekDailyUsage(
                    date: key,
                    totalTokens: missingCostDayTokens,
                    cost: nil,
                    requestCount: 2))
            } else {
                let cost = Double((daysAgo % 5) + 1) * 0.25
                let tokens = (daysAgo + 1) * 10
                expectedPricedCost += cost
                expectedTotalTokens += tokens
                daily.append(DeepSeekDailyUsage(date: key, totalTokens: tokens, cost: cost, requestCount: 1))
            }
        }
        daily.sort { $0.date < $1.date }

        let summary = DeepSeekUsageSummary(
            todayTokens: 10,
            currentMonthTokens: expectedTotalTokens,
            todayCost: 0.25,
            currentMonthCost: nil,
            requestCount: 1,
            currentMonthRequestCount: 366,
            topModel: "deepseek-chat",
            categoryBreakdown: [],
            daily: daily,
            currency: "USD",
            modelCosts: [],
            apiKeyCount: 2,
            period: .last30Days,
            coverage: DeepSeekUsageCoverage(
                requestedPeriod: .allTime,
                requestedStartDay: plan.requestedStartDayKey,
                requestedEndDay: plan.requestedEndDayKey,
                requestedDays: 365,
                coveredIntervals: [CostUsageDayInterval(
                    startDay: plan.requestedStartDayKey,
                    endDay: plan.requestedEndDayKey)],
                coveredDays: 365),
            timeZoneSeconds: 0,
            updatedAt: now)
        let usageSnapshot = DeepSeekUsageSnapshot(
            isAvailable: true,
            currency: "USD",
            totalBalance: 14.50,
            grantedBalance: 2.00,
            toppedUpBalance: 12.50,
            usageSummary: summary,
            updatedAt: now).toUsageSnapshot()
        return DeepSeek365DayFixture(
            usageSnapshot: usageSnapshot,
            expectedTotalTokens: expectedTotalTokens,
            expectedPricedCost: expectedPricedCost,
            missingCostDayTokens: missingCostDayTokens)
    }
}
