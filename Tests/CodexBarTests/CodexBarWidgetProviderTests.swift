import Foundation
import Testing
@testable import CodexBarCore
@testable import CodexBarWidget

struct CodexBarWidgetProviderTests {
    @Test
    func `provider choice supports alibaba`() {
        #expect(ProviderChoice(provider: .alibaba) == .alibaba)
        #expect(ProviderChoice.alibaba.provider == .alibaba)
    }

    @Test
    func `provider choice supports opencode go`() {
        #expect(ProviderChoice(provider: .opencodego) == .opencodego)
        #expect(ProviderChoice.opencodego.provider == .opencodego)
    }

    @Test
    func `provider choice supports cursor`() {
        let choice = ProviderChoice(rawValue: "cursor")

        #expect(choice?.provider == .cursor)
        #expect(ProviderChoice(provider: .cursor)?.provider == .cursor)

        let entry = WidgetSnapshot.ProviderEntry(
            provider: .cursor,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
        let snapshot = WidgetSnapshot(entries: [entry], enabledProviders: [.cursor], generatedAt: Date())

        #expect(CodexBarSwitcherTimelineProvider.supportedProviders(from: snapshot) == [.cursor])
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
    func `open code widget selection follows the stored workspace account`() throws {
        let firstID = try OpenCodeWorkspaceAccount.canonicalID(
            tokenAccountID: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
            workspaceID: "wrk_FIRST")
        let secondID = try OpenCodeWorkspaceAccount.canonicalID(
            tokenAccountID: #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")),
            workspaceID: "wrk_SECOND")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [firstID, secondID].map { accountID in
            WidgetSnapshot.ProviderEntry(
                provider: .opencode,
                updatedAt: now,
                primary: nil,
                secondary: nil,
                tertiary: nil,
                accountID: accountID,
                accountLabel: accountID == firstID ? "First" : "Second",
                creditsRemaining: nil,
                codeReviewRemainingPercent: nil,
                tokenUsage: nil,
                dailyUsage: [])
        }
        let snapshot = WidgetSnapshot(entries: entries, generatedAt: now)
        WidgetSelectionStore.saveSelectedOpenCodeWorkspaceAccountID(secondID)

        #expect(
            CodexBarSwitcherTimelineProvider.selectedOpenCodeWorkspaceAccountID(
                provider: .opencode,
                snapshot: snapshot) == secondID)
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
    func `widget configuration intents default to codex and credits`() {
        let providerIntent = ProviderSelectionIntent()
        let compactIntent = CompactMetricSelectionIntent()

        #expect(providerIntent.provider == .codex)
        #expect(compactIntent.provider == .codex)
        #expect(compactIntent.metric == .credits)
    }
}
