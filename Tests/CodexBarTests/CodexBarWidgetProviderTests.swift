import Foundation
import Testing
@testable import CodexBarCore
@testable import CodexBarWidget

struct CodexBarWidgetProviderTests {
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
                    title: "Gemini Session",
                    percentLeft: 80),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Weekly",
                    percentLeft: 20),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-third-party-session",
                    title: "Claude + GPT Session",
                    percentLeft: 5),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-third-party-weekly",
                    title: "Claude + GPT Weekly",
                    percentLeft: 60),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry, limit: 2)

        #expect(rows.map(\.title) == ["Gemini Weekly", "Claude + GPT Session"])
        #expect(rows.compactMap(\.percentLeft) == [20, 5])
        #expect(WidgetUsageRow.smallWidgetRowLimit(for: entry) == 2)
        #expect(WidgetUsageRow.mediumWidgetRowLimit(for: entry) == 3)
        let mediumRows = WidgetUsageRow.rows(
            for: entry,
            limit: WidgetUsageRow.mediumWidgetRowLimit(for: entry))
        #expect(mediumRows.map(\.title) == [
            "Gemini Weekly",
            "Claude + GPT Session",
            "Claude + GPT Weekly",
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
                    title: "Gemini Session",
                    percentLeft: nil),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-gemini-weekly",
                    title: "Gemini Weekly",
                    percentLeft: 100),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "antigravity-quota-summary-third-party-session",
                    title: "Claude + GPT Session",
                    percentLeft: 80),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        let rows = WidgetUsageRow.rows(for: entry, limit: 2)

        #expect(rows.map(\.title) == ["Gemini Weekly", "Claude + GPT Session"])
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
        #expect(rows.map(\.title) == ["Gemini", "Claude + GPT"])
        #expect(rows.compactMap(\.percentLeft) == [90, 80])
    }

    @Test
    func `widget configuration intents default to codex and credits`() {
        let providerIntent = ProviderSelectionIntent()
        let compactIntent = CompactMetricSelectionIntent()

        #expect(providerIntent.provider == .codex)
        #expect(compactIntent.provider == .codex)
        #expect(compactIntent.metric == .credits)
    }
}
