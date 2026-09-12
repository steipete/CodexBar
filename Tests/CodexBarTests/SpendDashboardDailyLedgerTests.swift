import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendDashboardDailyLedgerTests {
    @Test(arguments: [7, 60])
    func `OpenCodex aggregates and ledger counts cover the full declared history`(days: Int) throws {
        let entries = [0, 45].map { age in
            OpenCodexUsageEntry(
                requestID: "synthetic-\(age)",
                timestamp: Self.now.addingTimeInterval(-Double(age) * 86400),
                provider: "openai",
                model: "gpt-5.2",
                usageStatus: .reported,
                usage: OpenCodexTokenUsage(inputTokens: 100, outputTokens: 50, totalTokens: 150),
                totalTokens: 150)
        }
        let snapshot = OpenCodexUsageAggregator.snapshot(
            entries: entries,
            now: Self.now,
            historyDays: days,
            calendar: Self.calendar,
            modelsDevCatalog: ModelsDevCatalog(providers: [:]))
        let expectedRequests = days == 60 ? 2 : 1
        #expect(snapshot.last30DaysRequests == expectedRequests)
        #expect(snapshot.last30DaysTokens == expectedRequests * 150)
        #expect(snapshot.last30DaysCostUSD == snapshot.daily.compactMap(\.costUSD).reduce(0, +))
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Codex", snapshot: snapshot, sourceKind: .openCodex)],
            requestedDays: days,
            now: Self.now,
            calendar: Self.calendar)
        let group = try #require(model.groups.first)
        #expect(group.dailySummaries.allSatisfy { $0.requestCount != nil })
        #expect(group.dailySummaries.compactMap(\.requestCount).reduce(0, +) == expectedRequests)
        #expect(group.dailySummaries.allSatisfy { $0.totalCost != nil })
    }

    @Test
    func `daily ledger date text follows the selected app locale`() {
        let day = Self.date(day: 16)
        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            spendDashboardLedgerDateText(day, timeZone: Self.calendar.timeZone)
        }
        let german = CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            spendDashboardLedgerDateText(day, timeZone: Self.calendar.timeZone)
        }

        #expect(english != german)
        #expect(german.contains("Juli"))
    }

    @Test
    func `ledger visible and accessibility dates honor the bucket time zone`() throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let midnight = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 7, day: 16)))
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            for accessibility in [false, true] {
                let bucket = spendDashboardLedgerDateText(midnight, timeZone: utc, accessibility: accessibility)
                let machine = spendDashboardLedgerDateText(midnight, timeZone: pacific, accessibility: accessibility)
                #expect(bucket.contains("16"))
                #expect(machine.contains("15"))
            }
        }
    }

    @Test
    func `zero cost with unavailable activity totals is not a known idle day`() throws {
        let input = Self.input(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            entries: [Self.entry(day: "2026-07-16", cost: 0, tokens: 20, requests: nil)],
            totalTokens: 99)
        let group = try #require(Self.group(inputs: [input]))
        let row = try #require(group.dailySummaries.last?.providers.first)
        #expect(row.totalCost == 0)
        #expect(row.totalTokens == nil)
        #expect(row.requestCount == nil)
        #expect(!row.isKnownIdle)
    }

    @Test
    func `unpriced day preserves priced neighboring ledger days without becoming zero`() throws {
        var entries = [
            Self.entry(day: "2026-07-14", cost: 2, tokens: 10, requests: 1),
            Self.entry(day: "2026-07-16", cost: 0, tokens: 20, requests: 2),
        ]
        entries[1] = CostUsageDailyReport.Entry(
            date: "2026-07-16",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 20,
            requestCount: 2,
            costUSD: nil,
            modelsUsed: ["fixture-unpriced"],
            modelBreakdowns: [.init(modelName: "fixture-unpriced", costUSD: nil, totalTokens: 20)])
        let input = Self.input(id: "codex", provider: .codex, displayName: "Codex", entries: entries, totalTokens: 30)
        let group = try #require(Self.group(inputs: [input]))
        #expect(group.dailySummaries.count == 3)
        #expect(group.dailySummaries.first?.totalCost == 2)
        #expect(group.dailySummaries[1].totalCost == 0)
        #expect(group.dailySummaries.last?.totalCost == nil)
        #expect(group.dailySummaries.last?.totalTokens == 20)
    }

    @Test
    func `daily ledger aggregates providers and fills covered zero days`() throws {
        let claude = Self.input(
            id: "claude",
            provider: .claude,
            displayName: "Claude",
            entries: [
                Self.entry(day: "2026-07-14", cost: 1, tokens: 100, requests: 2),
                Self.entry(day: "2026-07-16", cost: 3, tokens: 300, requests: 4),
            ],
            totalTokens: 400)
        let openAI = Self.input(
            id: "openai",
            provider: .openai,
            displayName: "OpenAI",
            entries: [
                Self.entry(day: "2026-07-15", cost: 2, tokens: 200, requests: 3),
                Self.entry(day: "2026-07-16", cost: 4, tokens: 400, requests: 5),
            ],
            totalTokens: 600)
        let group = try #require(Self.group(inputs: [claude, openAI]))

        #expect(group.dailySummaries.map(\.totalCost) == [1, 2, 7])
        #expect(group.dailySummaries.map(\.totalTokens) == [100, 200, 700])
        #expect(group.dailySummaries.map(\.requestCount) == [2, 3, 9])

        let firstDay = try #require(group.dailySummaries.first)
        #expect(firstDay.providers.map(\.displayName) == ["Claude", "OpenAI"])
        #expect(firstDay.providers.map(\.totalCost) == [1, 0])
        #expect(firstDay.providers.map(\.totalTokens) == [100, 0])
        #expect(firstDay.providers.map(\.requestCount) == [2, 0])
    }

    @Test
    func `daily requests derive from complete rows without a snapshot aggregate`() throws {
        let input = Self.input(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            entries: [
                Self.entry(day: "2026-07-14", cost: 1, tokens: 10, requests: 2),
                Self.entry(day: "2026-07-16", cost: 2, tokens: 20, requests: 5),
            ],
            totalTokens: 30,
            totalRequests: nil)
        let group = try #require(Self.group(inputs: [input]))

        #expect(group.dailySummaries.map(\.requestCount) == [2, 0, 5])
        #expect(group.dailySummaries.flatMap(\.providers).map(\.requestCount) == [2, 0, 5])
    }

    @Test
    func `daily requests fail closed when the aggregate contradicts rows`() throws {
        let input = Self.input(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            entries: [Self.entry(day: "2026-07-16", cost: 2, tokens: 20, requests: 5)],
            totalTokens: 20,
            totalRequests: 99)
        let group = try #require(Self.group(inputs: [input]))

        #expect(group.dailySummaries.last?.totalCost == 2)
        #expect(group.dailySummaries.allSatisfy { $0.requestCount == nil })
        #expect(group.dailySummaries.allSatisfy { $0.providers.first?.requestCount == nil })
    }

    @Test
    func `daily requests stay unavailable when a covered row omits its count`() throws {
        let input = Self.input(
            id: "codex",
            provider: .codex,
            displayName: "Codex",
            entries: [Self.entry(day: "2026-07-16", cost: 2, tokens: 20, requests: nil)],
            totalTokens: 20,
            totalRequests: nil)
        let group = try #require(Self.group(inputs: [input]))

        #expect(group.dailySummaries.last?.totalCost == 2)
        #expect(group.dailySummaries.allSatisfy { $0.requestCount == nil })
    }

    @Test
    func `daily ledger contains only the common provider coverage`() throws {
        let earlier = Self.input(
            id: "earlier",
            provider: .claude,
            displayName: "Earlier",
            entries: [Self.entry(day: "2026-07-15", cost: 2, tokens: 20, requests: 2)],
            totalTokens: 20,
            updatedAt: Self.date(day: 15))
        let later = Self.input(
            id: "later",
            provider: .codex,
            displayName: "Later",
            entries: [Self.entry(day: "2026-07-14", cost: 3, tokens: 30, requests: 3)],
            totalTokens: 30)
        let group = try #require(Self.group(inputs: [earlier, later]))

        #expect(group.coveredDayCount == 2)
        #expect(group.dailySummaries.map(\.day) == [Self.date(day: 14), Self.date(day: 15)])
        #expect(group.dailySummaries.map(\.totalCost) == [3, 2])
        #expect(group.dailyPoints.map(\.day) == [Self.date(day: 14), Self.date(day: 15)])
    }

    @Test
    func `daily ledger is unavailable for disjoint provider coverage`() throws {
        let earlier = Self.input(
            id: "earlier",
            provider: .claude,
            displayName: "Earlier",
            entries: [Self.entry(day: "2026-07-10", cost: 2, tokens: 20, requests: 2)],
            totalTokens: 20,
            updatedAt: Self.date(day: 10))
        let later = Self.input(
            id: "later",
            provider: .codex,
            displayName: "Later",
            entries: [Self.entry(day: "2026-07-16", cost: 3, tokens: 30, requests: 3)],
            totalTokens: 30)
        let group = try #require(Self.group(inputs: [earlier, later]))

        #expect(group.coveredDayCount == 0)
        #expect(group.dailySummaries.isEmpty)
    }

    @Test
    func `daily ledger is unavailable when aggregate cost is unknown`() throws {
        let input = SpendDashboardModel.ProviderInput(
            id: "claude",
            provider: .claude,
            displayName: "Claude",
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: nil,
                last30DaysCostUSD: nil,
                currencyCode: "USD",
                historyDays: 3,
                daily: [],
                updatedAt: Self.now))
        let group = try #require(Self.group(inputs: [input]))

        #expect(group.totalCost == nil)
        #expect(group.dailySummaries.isEmpty)
    }

    private static func group(inputs: [SpendDashboardModel.ProviderInput]) -> SpendDashboardModel.CurrencyGroup? {
        SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 30,
            now: self.now,
            calendar: self.calendar).groups.first
    }

    private static func input(
        id: String,
        provider: UsageProvider,
        displayName: String,
        entries: [CostUsageDailyReport.Entry],
        totalTokens: Int,
        totalRequests: Int? = nil,
        updatedAt: Date = now) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: displayName,
            snapshot: CostUsageTokenSnapshot(
                sessionTokens: nil,
                sessionCostUSD: nil,
                last30DaysTokens: totalTokens,
                last30DaysCostUSD: entries.compactMap(\.costUSD).reduce(0, +),
                last30DaysRequests: totalRequests,
                currencyCode: "USD",
                historyDays: 3,
                daily: entries,
                updatedAt: updatedAt))
    }

    private static func entry(
        day: String,
        cost: Double,
        tokens: Int,
        requests: Int?) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            requestCount: requests,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: [
                .init(
                    modelName: "test-model",
                    costUSD: cost,
                    totalTokens: tokens,
                    requestCount: requests),
            ])
    }

    private static func date(day: Int) -> Date {
        self.calendar.date(from: DateComponents(year: 2026, month: 7, day: day))!
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
