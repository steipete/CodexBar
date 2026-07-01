import Foundation
import Testing
@testable import CodexBarCore
@testable import CodexBarWidget

struct CodexBarWidgetProviderTests {
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
    func `provider choice excludes unsupported Chutes widgets`() {
        #expect(ProviderChoice(provider: .chutes) == nil)
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
            primaryReset: now.addingTimeInterval(60),
            secondaryReset: now.addingTimeInterval(120))

        #expect(BurnDownRefreshSchedule.nextRefresh(snapshot: snapshot, provider: .codex, now: now)
            == now.addingTimeInterval(61))
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
        primaryReset: Date? = nil,
        secondaryReset: Date? = nil,
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
