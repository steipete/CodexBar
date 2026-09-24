import CodexBarCore
import Foundation
import Testing
@testable import CodexBarWidget

@MainActor
struct WidgetAccountPagerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `pager visits every inactive account without changing the active account`() throws {
        let accounts = (0...6).map { self.account(String($0), active: $0 == 0) }
        var selected = "1"
        var seen: [String] = []
        for _ in 1...6 {
            let pager = try #require(WidgetAccountPager.make(
                accounts: accounts, selectedID: selected, excludingAccountID: "0"))
            seen.append(pager.selected.id)
            selected = pager.next.id
            #expect(pager.total == 6)
            #expect(!pager.selected.isActive)
        }
        #expect(seen == (1...6).map(String.init))
        #expect(selected == "1")
        #expect(accounts.filter(\.isActive).map(\.id) == ["0"])
        let first = try #require(WidgetAccountPager.make(
            accounts: accounts, selectedID: "1", excludingAccountID: "0"))
        #expect(first.previous.id == "6")
        #expect(first.positionText == "1/6")
    }

    @Test
    func `pager keeps identity across reordering and recovers from removal or activation`() throws {
        let accounts = [self.account("active", active: true), self.account("one"), self.account("two")]
        let reordered = try #require(WidgetAccountPager.make(
            accounts: Array(accounts.reversed()), selectedID: "two", excludingAccountID: "active"))
        #expect(reordered.selected.id == "two")
        #expect(reordered.position == 1)
        let removed = try #require(WidgetAccountPager.make(
            accounts: Array(accounts.prefix(2)), selectedID: "two", excludingAccountID: "active"))
        #expect(removed.selected.id == "one")
        #expect(!removed.isPageable)
        let switched = try #require(WidgetAccountPager.make(
            accounts: [self.account("active"), self.account("one"), self.account("two", active: true)],
            selectedID: "two",
            excludingAccountID: "two"))
        #expect(switched.selected.id == "active")
        #expect(WidgetAccountPager.make(accounts: [accounts[0]], selectedID: nil, excludingAccountID: "active") == nil)
    }

    @Test
    func `selection rejects active missing disabled ambiguous and foreign accounts`() {
        let accounts = [self.account("active", active: true), self.account("inactive"), self.account("codex", .codex)]
        let snapshot = self.snapshot(accounts: accounts)
        #expect(WidgetAccountPager.canSelect(accountID: "inactive", provider: .claude, snapshot: snapshot))
        for id in ["active", "missing", "codex"] {
            #expect(!WidgetAccountPager.canSelect(accountID: id, provider: .claude, snapshot: snapshot))
        }
        #expect(!WidgetAccountPager.canSelect(
            accountID: "inactive", provider: .claude, snapshot: self.snapshot(accounts: accounts, enabled: [])))
        #expect(!WidgetAccountPager.canSelect(
            accountID: "inactive",
            provider: .claude,
            snapshot: self.snapshot(accounts: accounts + [self.account("inactive", .codex)])))
        #expect(CodexBarAccountsWidgetView.accounts(in: snapshot, for: .claude).map(\.id) == ["active", "inactive"])
    }

    @Test
    func `account quota and cost rows never borrow provider totals`() throws {
        let quota = self.usage(.claude, used: 70, credits: 7)
        let local = self.usage(.claude, used: 10, credits: 99, activity: true)
        let account = self.account("pin", usage: quota)
        let snapshot = self.snapshot(accounts: [account], entries: [local])
        let pinned = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: snapshot, provider: .claude, accountID: "pin", now: self.now)
        let selected = try #require(pinned.usageEntry.snapshot.entries.first)
        let overview = try #require(CodexBarAccountsWidgetView.accounts(in: snapshot, for: .claude).first?.usage)
        for entry in [selected, overview] {
            #expect(entry.primary?.usedPercent == 70)
            #expect(entry.creditsRemaining == 7)
            #expect(entry.tokenUsage == nil)
            #expect(entry.dailyUsage.isEmpty)
            for size in [WidgetTileSize.small, .medium, .large] {
                let details = WidgetMetricRows.rows(for: entry, size: size)
                #expect(details.allSatisfy { !["session-cost", "last30"].contains($0.id) })
            }
        }
    }

    @Test
    func `account owned activity remains available without using another accounts totals`() throws {
        let owned = self.usage(.claude, used: 70, activity: true)
        let snapshot = self.snapshot(
            accounts: [self.account("pin", usage: owned)],
            entries: [self.usage(.claude, used: 10, credits: 99)])
        let pinned = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: snapshot, provider: .claude, accountID: "pin", now: self.now)
        let selected = try #require(pinned.usageEntry.snapshot.entries.first)
        #expect(selected.primary?.usedPercent == 70)
        #expect(selected.creditsRemaining == nil)
        #expect(selected.dailyUsage.count == 1)
        #expect(selected.tokenUsage?.sessionCostUSD == 1)
        #expect(WidgetMetricRows.rows(for: selected, size: .large).contains { $0.id == "last30" })
    }

    @Test
    func `missing and unconfigured accounts do not inherit provider usage`() {
        let snapshot = self.snapshot(
            accounts: [self.account("empty")], entries: [self.usage(.claude, activity: true)])
        for accountID in [nil, "missing", "empty"] as [String?] {
            let pinned = CodexBarAccountTimelineProvider.makeEntry(
                snapshot: snapshot, provider: .claude, accountID: accountID, now: self.now)
            #expect(pinned.usageEntry.snapshot.entries.isEmpty)
        }
        #expect(CodexBarAccountsWidgetView.accounts(in: snapshot, for: .claude).first?.usage == nil)
    }

    @Test
    func `combined history is labeled and cannot cross provider or account availability boundaries`() throws {
        let account = self.account("pin", usage: self.usage(.claude))
        let local = self.usage(.claude, activity: true)
        let snapshot = self.snapshot(accounts: [account], entries: [local])
        let history = try #require(WidgetAccountHistory.resolve(in: snapshot, for: .claude, accountID: "pin"))
        #expect(history.title == "Combined local Claude history")
        #expect(history.points.count == 1)
        #expect(history.provider == .claude)
        let pinned = CodexBarAccountTimelineProvider.makeEntry(
            snapshot: snapshot, provider: .claude, accountID: "pin", now: self.now)
        #expect(pinned.history?.points.count == 1)
        #expect(pinned.usageEntry.snapshot.entries.first?.tokenUsage == nil)
        #expect(WidgetAccountHistory.resolve(in: snapshot, for: .codex, accountID: "pin") == nil)
        #expect(WidgetAccountHistory.resolve(in: snapshot, for: .claude, accountID: "missing") == nil)
        for invalid in [
            self.snapshot(accounts: [account], entries: [local], enabled: []),
            self.snapshot(accounts: [account], entries: [self.usage(.codex, activity: true)]),
            self.snapshot(accounts: [self.account("pin")], entries: [local]),
            self.snapshot(accounts: [self.account("pin", usage: self.usage(.codex))], entries: [local]),
            self.snapshot(accounts: [self.account("pin", usage: local)], entries: [local]),
        ] {
            #expect(WidgetAccountHistory.resolve(in: invalid, for: .claude, accountID: "pin") == nil)
        }
    }

    private func account(
        _ id: String,
        _ provider: UsageProvider = .claude,
        active: Bool = false,
        usage: WidgetSnapshot.ProviderEntry? = nil) -> WidgetSnapshot.AccountEntry
    {
        .init(id: id, provider: provider.instanceID, label: "Account \(id)", usage: usage, isActive: active)
    }

    private func snapshot(
        accounts: [WidgetSnapshot.AccountEntry],
        entries: [WidgetSnapshot.ProviderEntry] = [],
        enabled: [ProviderInstanceID] = [.claude, .codex]) -> WidgetSnapshot
    {
        WidgetSnapshot(entries: entries, accounts: accounts, enabledProviders: enabled, generatedAt: self.now)
    }

    private func usage(
        _ provider: UsageProvider,
        used: Double = 30,
        credits: Double? = nil,
        activity: Bool = false) -> WidgetSnapshot.ProviderEntry
    {
        WidgetSnapshot.ProviderEntry(
            provider: provider,
            updatedAt: self.now,
            primary: RateWindow(usedPercent: used, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            creditsRemaining: credits,
            codeReviewRemainingPercent: nil,
            tokenUsage: activity ? .init(
                sessionCostUSD: 1,
                sessionTokens: 100,
                last30DaysCostUSD: 10,
                last30DaysTokens: 1000) : nil,
            dailyUsage: activity ? [.init(dayKey: "2026-09-23", totalTokens: 100, costUSD: 1)] : [])
    }
}
