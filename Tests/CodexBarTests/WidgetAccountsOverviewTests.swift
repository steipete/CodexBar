import CodexBarCore
import Foundation
import Testing
import WidgetKit
@testable import CodexBarWidget

@MainActor
struct WidgetAccountsOverviewTests {
    @Test(arguments: [WidgetFamily.systemMedium, .systemLarge])
    func `overview sorts by binding remaining quota and combines visible and snapshot overflow`(family: WidgetFamily) {
        let entry = self.entry(remaining: [70, 10, 90, 40, 20, 60], overflow: 3)
        let result = WidgetAccountsOverview.make(entry: entry, family: family)
        let expected = family == .systemLarge ? [2, 5, 4, 6, 1, 3] : [2, 5, 4, 6]
        #expect(result.rows.map(\.id) == expected.map { "fixture-\($0)" })
        #expect(result.rows.map(\.quota?.title).allSatisfy { $0 == "Weekly" })
        #expect(result.overflowCount == (family == .systemLarge ? 3 : 5))
        #expect(result.rows.first?.account.usage?.updatedAt == entry.date)
    }

    @Test(arguments: [WidgetFamily.systemMedium, .systemLarge])
    func `family cutoff stays four or eight with larger synthetic snapshots`(family: WidgetFamily) {
        let entry = self.entry(remaining: (1...10).map { Double($0 * 9) })
        let result = WidgetAccountsOverview.make(entry: entry, family: family)
        #expect(result.rows.count == (family == .systemLarge ? 8 : 4))
        #expect(result.overflowCount == (family == .systemLarge ? 2 : 6))
    }

    @Test
    func `used preference cannot reverse ordering and equal percentages keep snapshot order`() {
        for showUsed in [false, true] {
            let entry = self.entry(remaining: [20, 20, 10], showUsed: showUsed)
            let result = WidgetAccountsOverview.make(entry: entry, family: .systemMedium)
            #expect(result.rows.map(\.id) == ["fixture-3", "fixture-1", "fixture-2"])
            #expect(result.overflowCount == 0)
        }
    }

    @Test
    func `unavailable accounts stay last without borrowing provider data or old labels`() throws {
        let fixture = self.entry(remaining: [20])
        let usage = fixture.snapshot.accounts[0].usage
        let snapshot = try WidgetSnapshot(
            entries: [#require(usage)],
            accounts: [
                .init(id: "private-owner-id", provider: .codex, label: "Account 2", usage: nil),
                .init(id: "verified", provider: .codex, label: "Account 1", usage: usage),
            ],
            enabledProviders: [.codex],
            generatedAt: fixture.date)
        let entry = CodexBarWidgetEntry(date: fixture.date, provider: .codex, snapshot: snapshot)
        let result = WidgetAccountsOverview.make(entry: entry, family: .systemMedium)
        #expect(result.rows.map(\.account.label) == ["Account 1", "Account 2"])
        #expect(result.rows.last?.quota == nil)
        #expect(result.rows.last?.account.usage == nil)
    }

    @Test
    func `disabled foreign mismatched and ambiguous accounts cannot supply rows`() {
        let fixture = self.entry(remaining: [20])
        let usage = fixture.snapshot.accounts[0].usage
        let accounts: [WidgetSnapshot.AccountEntry] = [
            .init(id: "duplicate", provider: .codex, label: "Hidden", usage: usage),
            .init(id: "duplicate", provider: .claude, label: "Hidden", usage: nil),
            .init(id: "mismatch", provider: .claude, label: "Hidden", usage: usage),
            .init(id: "foreign", provider: .codex, label: "Hidden", usage: usage),
            .init(id: "unavailable", provider: .claude, label: "Account 1", usage: nil),
        ]
        for enabled in [[], [.claude]] as [[ProviderInstanceID]] {
            let snapshot = WidgetSnapshot(
                entries: [],
                accounts: accounts,
                accountOverflowCounts: ["claude": 2, "codex": 7],
                enabledProviders: enabled,
                generatedAt: fixture.date)
            let entry = CodexBarWidgetEntry(date: fixture.date, provider: .claude, snapshot: snapshot)
            let result = WidgetAccountsOverview.make(entry: entry, family: .systemMedium)
            #expect(result.rows.map(\.id) == (enabled.isEmpty ? [] : ["unavailable"]))
            #expect(result.overflowCount == (enabled.isEmpty ? 0 : 2))
        }
    }

    @Test
    func `legacy snapshot has no overflow and new counts round trip`() throws {
        let snapshot = self.entry(remaining: [20], overflow: 3).snapshot
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(decoded.accountOverflowCounts == ["codex": 3])
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "accountOverflowCounts")
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.accountOverflowCounts.isEmpty)
        #expect(legacy.accounts.map(\.id) == snapshot.accounts.map(\.id))
    }

    func entry(
        remaining: [Double],
        overflow: Int = 0,
        showUsed: Bool = false,
        includeExtras: Bool = true) -> CodexBarWidgetEntry
    {
        let now = Date().addingTimeInterval(-300)
        let accounts: [WidgetSnapshot.AccountEntry] = remaining.enumerated().map { index, left in
            let usage = WidgetSnapshot.ProviderEntry(
                provider: .codex,
                updatedAt: now,
                primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 100 - left,
                    windowMinutes: 10080,
                    resetsAt: nil,
                    resetDescription: nil),
                tertiary: nil,
                creditsRemaining: includeExtras ? 999 : nil,
                codeReviewRemainingPercent: includeExtras ? 0 : nil,
                tokenUsage: nil,
                dailyUsage: [])
            return .init(id: "fixture-\(index + 1)", provider: .codex, label: "Account \(index + 1)", usage: usage)
        }
        return CodexBarWidgetEntry(date: now, provider: .codex, snapshot: WidgetSnapshot(
            entries: [],
            accounts: accounts,
            accountOverflowCounts: ["codex": overflow],
            enabledProviders: [.codex],
            usageBarsShowUsed: showUsed,
            generatedAt: now))
    }
}
