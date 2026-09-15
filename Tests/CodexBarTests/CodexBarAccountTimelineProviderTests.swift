import Foundation
import Testing
@testable import CodexBarCore
@testable import CodexBarWidget

@MainActor
struct CodexBarAccountTimelineProviderTests {
    private let measuredAt = Date(timeIntervalSince1970: 1_782_000_000)
    private let now = Date(timeIntervalSince1970: 1_782_000_600)

    @Test
    func `unconfigured account widget does not show the provider default`() {
        let snapshot = self.snapshot()
        let entry = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: snapshot, provider: .claude, accountID: nil, now: self.now)

        #expect(entry.accountID == nil)
        #expect(entry.accountLabel == nil)
        #expect(entry.usageEntry.provider == .claude)
        #expect(entry.usageEntry.snapshot.entries.isEmpty)
        #expect(entry.date == self.now)
        #expect(snapshot.entries.first { $0.provider == .claude }?.primary?.usedPercent == 80)
    }

    @Test
    func `account timeline entries independently select usage without changing the provider default`() throws {
        let snapshot = self.snapshot()
        let work = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: snapshot, provider: .claude, accountID: "claude/work", now: self.now)
        let personal = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: snapshot, provider: .claude, accountID: "claude/personal", now: self.now)

        #expect(work.accountID == "claude/work")
        #expect(work.accountLabel == "Work")
        #expect(personal.accountID == "claude/personal")
        #expect(personal.accountLabel == "Personal")
        let workUsage = try #require(self.displayedUsage(work))
        let personalUsage = try #require(self.displayedUsage(personal))
        #expect(workUsage.primary?.usedPercent == 10)
        #expect(personalUsage.primary?.usedPercent == 90)
        #expect(workUsage.updatedAt == self.measuredAt)
        #expect(personalUsage.updatedAt == self.measuredAt)
        #expect(work.date == self.now)
        #expect(personal.date == self.now)
        #expect(snapshot.entries.first { $0.provider == .claude }?.primary?.usedPercent == 80)
        #expect(snapshot.selectingAccount(nil, for: .claude).entries.first {
            $0.provider == .claude
        }?.primary?.usedPercent == 80)
    }

    @Test
    func `deleted account selection remains unavailable while sibling and provider quotas exist`() throws {
        let before = self.snapshot()
        let existing = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: before, provider: .claude, accountID: "claude/work", now: self.now)
        #expect(try #require(self.displayedUsage(existing)).primary?.usedPercent == 10)
        let after = self.snapshot(accounts: before.accounts.filter { $0.id != "claude/work" })
        let deleted = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: after, provider: .claude, accountID: "claude/work", now: self.now)

        #expect(deleted.accountID == "claude/work")
        #expect(deleted.accountLabel == nil)
        #expect(self.displayedUsage(deleted) == nil)
        #expect(after.accounts.contains { $0.id == "claude/personal" })
        #expect(after.entries.contains { $0.provider == .claude })
    }

    @Test
    func `missing and wrong provider account IDs never borrow current usage`() {
        let snapshot = self.snapshot()
        for id in ["missing-account", "codex/personal"] {
            let entry = CodexBarAccountTimelineProvider.makeEntry(
                snapshot: snapshot, provider: .claude, accountID: id, now: self.now)
            #expect(entry.accountID == id)
            #expect(entry.accountLabel == nil)
            #expect(self.displayedUsage(entry) == nil)
        }
    }

    @Test
    func `configured account without a quota keeps its identity without using a sibling quota`() {
        let entry = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: self.snapshot(), provider: .claude, accountID: "claude/unavailable", now: self.now)

        #expect(entry.accountID == "claude/unavailable")
        #expect(entry.accountLabel == "Unavailable Work")
        #expect(self.displayedUsage(entry) == nil)
    }

    @Test
    func `disabled provider cannot expose retained account quota or label`() {
        let entry = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: self.snapshot(enabledProviders: [.codex]),
            provider: .claude,
            accountID: "claude/work",
            now: self.now)

        #expect(entry.accountID == "claude/work")
        #expect(entry.accountLabel == nil)
        #expect(self.displayedUsage(entry) == nil)
    }

    @Test
    func `empty shared data does not manufacture preview usage for a configured account`() {
        let snapshot = WidgetSnapshot(entries: [], accounts: [], enabledProviders: [], generatedAt: self.measuredAt)
        let entry = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: snapshot, provider: .claude, accountID: "claude/work", now: self.now)

        #expect(entry.accountID == "claude/work")
        #expect(entry.accountLabel == nil)
        #expect(self.displayedUsage(entry) == nil)
        #expect(entry.usageEntry.snapshot.generatedAt == self.measuredAt)
    }

    private func displayedUsage(_ entry: CodexBarAccountWidgetEntry) -> WidgetSnapshot.ProviderEntry? {
        entry.usageEntry.snapshot.entries.first { $0.provider == entry.usageEntry.provider.instanceID }
    }

    private func snapshot(
        accounts: [WidgetSnapshot.AccountEntry]? = nil,
        enabledProviders: [ProviderInstanceID] = [.claude, .codex]) -> WidgetSnapshot
    {
        WidgetSnapshot(
            entries: [self.usage(provider: .claude, usedPercent: 80), self.usage(provider: .codex, usedPercent: 40)],
            accounts: accounts ?? [
                .init(
                    id: "claude/work",
                    provider: .claude,
                    label: "Work",
                    usage: self.usage(provider: .claude, usedPercent: 10)),
                .init(
                    id: "claude/personal",
                    provider: .claude,
                    label: "Personal",
                    usage: self.usage(provider: .claude, usedPercent: 90)),
                .init(id: "claude/unavailable", provider: .claude, label: "Unavailable Work", usage: nil),
                .init(
                    id: "codex/personal",
                    provider: .codex,
                    label: "Codex Personal",
                    usage: self.usage(provider: .codex, usedPercent: 20)),
            ],
            enabledProviders: enabledProviders,
            generatedAt: self.measuredAt)
    }

    private func usage(provider: UsageProvider, usedPercent: Double) -> WidgetSnapshot.ProviderEntry {
        WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: self.measuredAt,
            primary: RateWindow(usedPercent: usedPercent, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])
    }
}
