import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardDateTruthTests {
    private struct MalformedMetricCase {
        let name: String
        let breakdown: CostUsageDailyReport.ModelBreakdown
        let totalCost: Double?
        let totalTokens: Int?
        let modelHistory: SpendDashboardModel.ModelHistoryCompleteness
        let chartCost: Double?
    }

    @Test
    func `Mistral UTC buckets map into Pacific dashboard days at midnight UTC`() throws {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-02T00:01:00Z"))
        let june30 = try #require(pacific.date(from: DateComponents(year: 2026, month: 6, day: 30)))
        let july1 = try #require(pacific.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let snapshot = Self.snapshot(
            currency: "EUR",
            entries: [
                Self.entry(day: "2026-07-01", cost: 1, tokens: 10),
                Self.entry(day: "2026-07-02", cost: 2, tokens: 20),
            ],
            historyDays: 2,
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .mistral, displayName: "Mistral", snapshot: snapshot)],
            requestedDays: 7,
            now: now,
            calendar: pacific).groups.first)

        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 30)
        #expect(group.coveredDayCount == 2)
        #expect(group.dailyPoints.map(\.day) == [june30, july1])
        #expect(group.dailyPoints.map(\.cost) == [1, 2])
    }

    @Test
    func `Mistral coverage end preserves UTC bucket day after Pacific midnight`() throws {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-02T08:00:00Z"))
        let mistral = SpendDashboardModel.ProviderInput(
            provider: .mistral,
            displayName: "Mistral",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [],
                historyDays: 2,
                updatedAt: now))
        let local = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-02", cost: 1)],
                historyDays: 1,
                updatedAt: now))
        let group = try #require(SpendDashboardModel.build(
            inputs: [mistral, local],
            requestedDays: 7,
            now: now,
            calendar: pacific).groups.first)

        #expect(group.coveredDayCount == 0)
        #expect(group.providers.first(where: { $0.provider == .mistral })?.coveredDayCount == 2)
        #expect(group.providers.first(where: { $0.provider == .claude })?.coveredDayCount == 1)
    }

    @Test
    func `Mistral ended range stays on observed UTC days instead of publishing recent zeros`() throws {
        let formatter = ISO8601DateFormatter()
        let updatedAt = try #require(formatter.date(from: "2026-07-16T12:00:00Z"))
        let startDate = try #require(formatter.date(from: "2026-07-01T00:00:00Z"))
        let endDate = try #require(formatter.date(from: "2026-07-02T00:00:01Z"))
        let usage = MistralUsageSnapshot(
            totalCost: 3,
            currency: "USD",
            currencySymbol: "$",
            totalInputTokens: 30,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 1,
            daily: [
                Self.mistralBucket(day: "2026-07-01", cost: 1, tokens: 10),
                Self.mistralBucket(day: "2026-07-02", cost: 2, tokens: 20),
            ],
            startDate: startDate,
            endDate: endDate,
            updatedAt: updatedAt)
        let snapshot = usage.toCostUsageTokenSnapshot(historyDays: 7)

        let earlierGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .mistral, displayName: "Mistral", snapshot: snapshot)],
            requestedDays: 30,
            now: updatedAt,
            calendar: Self.calendar).groups.first)
        #expect(earlierGroup.providers.first?.coveredDayCount == 2)
        #expect(earlierGroup.providers.first?.totalCost == 3)
        #expect(earlierGroup.dailyPoints.map(\.day) == [startDate, Self.calendar.startOfDay(for: endDate)])

        let recentGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .mistral, displayName: "Mistral", snapshot: snapshot)],
            requestedDays: 7,
            now: updatedAt,
            calendar: Self.calendar).groups.first)
        #expect(recentGroup.providers.first?.coveredDayCount == 0)
        #expect(recentGroup.providers.first?.totalCost == nil)
        #expect(recentGroup.providers.first?.totalTokens == nil)
        #expect(recentGroup.dailyPoints.isEmpty)
    }

    @Test
    func `metadata free Mistral coverage preserves stale valid billing buckets`() throws {
        let formatter = ISO8601DateFormatter()
        let updatedAt = try #require(formatter.date(from: "2026-07-16T12:00:00Z"))
        let july14 = try #require(formatter.date(from: "2026-07-14T00:00:00Z"))
        let july15 = try #require(formatter.date(from: "2026-07-15T00:00:00Z"))
        let usage = MistralUsageSnapshot(
            totalCost: 3,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 30,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 1,
            daily: [
                Self.mistralBucket(day: "2026-07-14", cost: 1, tokens: 10),
                Self.mistralBucket(day: "2026-07-15", cost: 2, tokens: 20),
            ],
            startDate: nil,
            endDate: nil,
            updatedAt: updatedAt)
        let snapshot = usage.toCostUsageTokenSnapshot()
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .mistral, displayName: "Mistral", snapshot: snapshot)],
            requestedDays: 30,
            now: updatedAt,
            calendar: Self.calendar).groups.first)

        #expect(snapshot.updatedAt == july15)
        #expect(group.coveredDayCount == 2)
        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 30)
        #expect(group.dailyPoints.map(\.day) == [july14, july15])
        #expect(group.dailyPoints.map(\.cost) == [1, 2])
    }

    @Test
    func `Mistral without established coverage cannot publish a current zero day`() throws {
        let snapshot = MistralUsageSnapshot(
            totalCost: 0,
            currency: "EUR",
            currencySymbol: "€",
            totalInputTokens: 0,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 0,
            daily: [],
            startDate: nil,
            endDate: nil,
            updatedAt: Self.now)
            .toCostUsageTokenSnapshot(historyDays: 7)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .mistral, displayName: "Mistral", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(group.coveredDayCount == 0)
        #expect(group.providers.first?.coveredDayCount == 0)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `unknown currency spend cannot enter a known currency group`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                Self.input(id: "usd", provider: .claude, currency: "USD", cost: 2),
                Self.input(id: "blank", provider: .mistral, currency: "  ", cost: 100),
                Self.input(id: "unknown", provider: .openai, currency: "XXX", cost: 200),
                Self.input(id: "eur", provider: .codex, currency: "EUR", cost: 3),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        #expect(model.groups.map(\.currencyCode) == ["EUR", "USD"])
        let eur = try #require(model.groups.first(where: { $0.currencyCode == "EUR" }))
        let usd = try #require(model.groups.first(where: { $0.currencyCode == "USD" }))
        #expect(eur.providers.map(\.id) == ["eur"])
        #expect(eur.totalCost == 3)
        #expect(usd.providers.map(\.id) == ["usd"])
        #expect(usd.totalCost == 2)
    }

    @Test
    func `date with a valid prefix and trailing junk fails closed`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-07-16junk", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first?.totalCost == nil)
        #expect(group.providers.first?.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `malformed rows validate cost and tokens independently`() throws {
        let cases: [MalformedMetricCase] = [
            .init(
                name: "cost",
                breakdown: .init(modelName: "spend", costUSD: 1, totalTokens: 0),
                totalCost: nil,
                totalTokens: 30,
                modelHistory: .incomplete,
                chartCost: nil),
            .init(
                name: "tokens",
                breakdown: .init(modelName: "tokens", costUSD: 0, totalTokens: 1),
                totalCost: 3,
                totalTokens: nil,
                modelHistory: .complete,
                chartCost: 3),
            .init(
                name: "requests",
                breakdown: .init(modelName: "requests", costUSD: 0, totalTokens: 0, requestCount: 1),
                totalCost: 3,
                totalTokens: 30,
                modelHistory: .complete,
                chartCost: 3),
        ]

        for testCase in cases {
            let snapshot = Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
                Self.entryWithBreakdowns(
                    day: "malformed",
                    breakdowns: [testCase.breakdown]),
            ])
            let group = try #require(SpendDashboardModel.build(
                inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
                requestedDays: 7,
                now: Self.now,
                calendar: Self.calendar).groups.first)

            #expect(group.providers.first?.totalCost == testCase.totalCost, Comment(rawValue: testCase.name))
            #expect(group.providers.first?.totalTokens == testCase.totalTokens, Comment(rawValue: testCase.name))
            #expect(group.modelHistoryCompleteness == testCase.modelHistory, Comment(rawValue: testCase.name))
            #expect(group.models.map(\.totalCost) == (testCase.totalCost == nil ? [] : [3]))
            #expect(group.dailyPoints.first?.cost == testCase.chartCost, Comment(rawValue: testCase.name))
        }
    }

    @Test
    func `omitted rows preserve independent metrics sources and currencies`() throws {
        let omissions = [(day: "malformed", historyDays: 30), (day: "2026-07-15", historyDays: 1)]

        for omission in omissions {
            let tokenInvalid = SpendDashboardModel.ProviderInput(
                id: "token-invalid",
                provider: .claude,
                displayName: "Token invalid",
                snapshot: Self.snapshot(
                    currency: "USD",
                    entries: [
                        Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
                        Self.entry(day: omission.day, cost: 0, tokens: nil, model: nil),
                    ],
                    historyDays: omission.historyDays))
            let costInvalid = SpendDashboardModel.ProviderInput(
                id: "cost-invalid",
                provider: .openai,
                displayName: "Cost invalid",
                snapshot: Self.snapshot(
                    currency: "CAD",
                    entries: [
                        Self.entry(day: "2026-07-16", cost: 2, tokens: 20),
                        Self.entry(day: omission.day, cost: nil, tokens: 0, model: nil),
                    ],
                    historyDays: omission.historyDays))
            let groups = SpendDashboardModel.build(
                inputs: [
                    tokenInvalid,
                    Self.input(id: "healthy-usd", provider: .codex, currency: "USD", cost: 4),
                    costInvalid,
                    Self.input(id: "healthy-cad", provider: .mistral, currency: "CAD", cost: 5),
                    Self.input(id: "healthy-eur", provider: .bedrock, currency: "EUR", cost: 6),
                ],
                requestedDays: 7,
                now: Self.now,
                calendar: Self.calendar).groups
            let cad = try #require(groups.first(where: { $0.currencyCode == "CAD" }))
            let eur = try #require(groups.first(where: { $0.currencyCode == "EUR" }))
            let usd = try #require(groups.first(where: { $0.currencyCode == "USD" }))

            #expect(usd.totalCost == 7)
            #expect(usd.totalTokens == nil)
            #expect(usd.modelHistoryCompleteness == .complete)
            #expect(usd.models.map(\.totalCost) == [4, 3])
            #expect(usd.models.first(where: { $0.provider == .claude })?.totalTokens == nil)
            #expect(usd.models.first(where: { $0.provider == .codex })?.totalTokens == 10)
            #expect(usd.dailyPoints.map(\.sourceID) == ["healthy-usd", "token-invalid"])
            #expect(SpendDailyChartPresentation(
                dailyPoints: usd.dailyPoints,
                aggregateTotal: usd.totalCost).content == .chart)

            #expect(cad.totalCost == nil)
            #expect(cad.totalTokens == 30)
            #expect(cad.modelHistoryCompleteness == .incomplete)
            #expect(cad.models.isEmpty)
            #expect(cad.dailyPoints.map(\.sourceID) == ["healthy-cad"])
            #expect(SpendDailyChartPresentation(
                dailyPoints: cad.dailyPoints,
                aggregateTotal: cad.totalCost).content == .chart)

            #expect(eur.totalCost == 6)
            #expect(eur.totalTokens == 10)
            #expect(eur.modelHistoryCompleteness == .complete)
            #expect(eur.models.map(\.totalCost) == [6])
            #expect(eur.dailyPoints.map(\.sourceID) == ["healthy-eur"])
        }
    }

    @Test
    func `complete model costs survive invalid aggregate and per-model tokens`() throws {
        let negative = SpendDashboardModel.ProviderInput(
            id: "negative",
            provider: .mistral,
            displayName: "Negative",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entryWithBreakdowns(
                    day: "2026-07-16",
                    totalCost: 5,
                    totalTokens: -1,
                    breakdowns: [.init(modelName: "negative", costUSD: 5, totalTokens: -1)]),
            ]))
        let overflow = SpendDashboardModel.ProviderInput(
            id: "overflow",
            provider: .claude,
            displayName: "Overflow",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entryWithBreakdowns(
                    day: "2026-07-16",
                    totalCost: 3,
                    totalTokens: .max,
                    breakdowns: [.init(modelName: "overflow", costUSD: 3, totalTokens: .max)]),
                Self.entryWithBreakdowns(
                    day: "2026-07-15",
                    totalCost: 4,
                    totalTokens: .max,
                    breakdowns: [.init(modelName: "overflow", costUSD: 4, totalTokens: .max)]),
            ]))
        let mismatch = SpendDashboardModel.ProviderInput(
            id: "mismatch",
            provider: .openai,
            displayName: "Mismatch",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entryWithBreakdowns(
                    day: "2026-07-16",
                    totalCost: 6,
                    totalTokens: 60,
                    breakdowns: [.init(modelName: "mismatch", costUSD: 6, totalTokens: 10)]),
            ]))
        let valid = SpendDashboardModel.ProviderInput(
            id: "valid",
            provider: .codex,
            displayName: "Valid",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entryWithBreakdowns(
                    day: "2026-07-16",
                    totalCost: 2,
                    totalTokens: 2,
                    breakdowns: [.init(modelName: "valid", costUSD: 2, totalTokens: 2)]),
            ]))
        let group = try #require(SpendDashboardModel.build(
            inputs: [negative, overflow, mismatch, valid],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 20)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.modelName) == ["overflow", "mismatch", "negative", "valid"])
        #expect(group.models.map(\.totalCost) == [7, 6, 5, 2])
        #expect(group.models.map(\.totalTokens) == [nil, nil, nil, 2])
        #expect(Set(group.dailyPoints.map(\.sourceID)) == ["mismatch", "negative", "overflow", "valid"])
    }

    @Test
    func `malformed source is omitted without hiding healthy currency peers`() throws {
        let malformed = SpendDashboardModel.ProviderInput(
            id: "malformed",
            provider: .claude,
            displayName: "Malformed",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
                Self.entry(day: "not-a-day", cost: 7, tokens: 70),
            ]))
        let healthyUSD = Self.input(id: "healthy-usd", provider: .codex, currency: "USD", cost: 4)
        let healthyEUR = Self.input(id: "healthy-eur", provider: .openai, currency: "EUR", cost: 5)
        let groups = SpendDashboardModel.build(
            inputs: [malformed, healthyUSD, healthyEUR],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups
        let eur = try #require(groups.first(where: { $0.currencyCode == "EUR" }))
        let usd = try #require(groups.first(where: { $0.currencyCode == "USD" }))

        #expect(usd.providers.first(where: { $0.id == "malformed" })?.totalCost == nil)
        #expect(usd.providers.first(where: { $0.id == "malformed" })?.totalTokens == nil)
        #expect(usd.totalCost == nil)
        #expect(usd.totalTokens == nil)
        #expect(usd.modelHistoryCompleteness == .incomplete)
        #expect(usd.models.isEmpty)
        #expect(usd.dailyPoints.map(\.sourceID) == ["healthy-usd"])
        #expect(usd.dailyPoints.map(\.cost) == [4])
        #expect(eur.totalCost == 5)
        #expect(eur.totalTokens == 10)
        #expect(eur.modelHistoryCompleteness == .complete)
        #expect(eur.dailyPoints.map(\.sourceID) == ["healthy-eur"])
    }

    @Test
    func `coverage contradiction fails source closed across every aggregate`() throws {
        let contradictions = [
            Self.entry(day: "2026-07-15", cost: 7, tokens: 70),
            Self.entry(day: "2026-07-15", cost: nil, tokens: nil, model: nil),
        ]

        for contradiction in contradictions {
            let snapshot = Self.snapshot(
                currency: "USD",
                entries: [
                    Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
                    contradiction,
                ],
                historyDays: 1)
            let group = try #require(SpendDashboardModel.build(
                inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
                requestedDays: 7,
                now: Self.now,
                calendar: Self.calendar).groups.first)

            #expect(group.providers.first?.coveredDayCount == 1)
            #expect(group.providers.first?.totalCost == nil)
            #expect(group.providers.first?.totalTokens == nil)
            #expect(group.totalCost == nil)
            #expect(group.totalTokens == nil)
            #expect(group.modelHistoryCompleteness == .incomplete)
            #expect(group.models.isEmpty)
            #expect(group.dailyPoints.isEmpty)
        }
    }

    @Test
    func `entries inside declared coverage aggregate normally`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-15", cost: 7, tokens: 70),
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
            ],
            historyDays: 2)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 10)
        #expect(group.totalTokens == 100)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.totalCost) == [10])
        #expect(group.dailyPoints.map(\.cost) == [7, 3])
    }

    @Test
    func `aggregate contradictions fail only the affected metric`() throws {
        let entry = Self.entry(day: "2026-07-16", cost: 3, tokens: 30)
        let costContradiction = Self.snapshot(
            currency: "USD",
            entries: [entry],
            last30DaysTokens: 30,
            last30DaysCostUSD: 10)
        let tokenContradiction = Self.snapshot(
            currency: "USD",
            entries: [entry],
            last30DaysTokens: 100,
            last30DaysCostUSD: 3)

        let costGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: costContradiction)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)
        let tokenGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: tokenContradiction)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(costGroup.totalCost == nil)
        #expect(costGroup.totalTokens == 30)
        #expect(costGroup.dailyPoints.isEmpty)
        #expect(costGroup.modelHistoryCompleteness == .incomplete)
        #expect(costGroup.models.isEmpty)

        #expect(tokenGroup.totalCost == 3)
        #expect(tokenGroup.totalTokens == nil)
        #expect(tokenGroup.dailyPoints.map(\.cost) == [3])
        #expect(tokenGroup.modelHistoryCompleteness == .complete)
        #expect(tokenGroup.models.map(\.totalCost) == [3])
        #expect(tokenGroup.models.map(\.totalTokens) == [nil])
    }

    @Test
    func `matching full history aggregates allow shorter selected window`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-06", cost: 7, tokens: 70),
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
            ],
            historyDays: 30,
            last30DaysTokens: 100,
            last30DaysCostUSD: 10)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 30)
        #expect(group.models.map(\.totalCost) == [3])
        #expect(group.models.map(\.totalTokens) == [30])
        #expect(group.dailyPoints.map(\.cost) == [3])
    }

    @Test
    func `out of request usage and proven zero outside coverage are harmless`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-01", cost: 100, tokens: 1000),
                Self.entry(day: "2026-07-15", cost: 0, tokens: 0, model: nil),
                Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
            ],
            historyDays: 1)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 30)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.totalCost) == [3])
        #expect(group.dailyPoints.map(\.cost) == [3])
    }

    @Test
    func `coverage contradiction omits only its source and currency`() throws {
        let contradictory = SpendDashboardModel.ProviderInput(
            id: "contradictory",
            provider: .claude,
            displayName: "Contradictory",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [
                    Self.entry(day: "2026-07-15", cost: 7, tokens: 70),
                    Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
                ],
                historyDays: 1))
        let healthyUSD = Self.input(id: "healthy-usd", provider: .codex, currency: "USD", cost: 4)
        let healthyEUR = Self.input(id: "healthy-eur", provider: .openai, currency: "EUR", cost: 5)
        let groups = SpendDashboardModel.build(
            inputs: [contradictory, healthyUSD, healthyEUR],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups
        let eur = try #require(groups.first(where: { $0.currencyCode == "EUR" }))
        let usd = try #require(groups.first(where: { $0.currencyCode == "USD" }))

        #expect(usd.totalCost == nil)
        #expect(usd.modelHistoryCompleteness == .incomplete)
        #expect(usd.models.isEmpty)
        #expect(usd.dailyPoints.map(\.sourceID) == ["healthy-usd"])
        #expect(usd.dailyPoints.map(\.cost) == [4])
        #expect(eur.totalCost == 5)
        #expect(eur.modelHistoryCompleteness == .complete)
        #expect(eur.models.map(\.totalCost) == [5])
        #expect(eur.dailyPoints.map(\.sourceID) == ["healthy-eur"])
    }

    @Test
    func `empty Mistral history with incomplete aggregates stays unavailable`() throws {
        let snapshot = Self.mistralSnapshot(totalCost: 5, totalTokens: 50)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.last30DaysTokens == nil)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .mistral, displayName: "Mistral", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(group.coveredDayCount == 0)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
    }

    @Test
    func `empty Mistral history with declared coverage preserves explicit zeros`() throws {
        let snapshot = Self.mistralSnapshot(totalCost: 0, totalTokens: 0, establishesCoverage: true)
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysCostUSD == 0)
        #expect(snapshot.last30DaysTokens == 0)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .mistral, displayName: "Mistral", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 0)
        #expect(group.totalTokens == 0)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.isEmpty)
    }

    @Test
    func `malformed zero row cannot prove contradictory nonzero aggregates`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [Self.entry(day: "malformed", cost: 0, tokens: 0, model: nil)],
            historyDays: 1,
            last30DaysTokens: 1,
            last30DaysCostUSD: 1)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `empty history metric proof stays independent and currency scoped`() throws {
        let costOnly = SpendDashboardModel.ProviderInput(
            id: "cost-only",
            provider: .mistral,
            displayName: "Cost only",
            snapshot: Self.mistralSnapshot(
                totalCost: 0,
                totalTokens: 50,
                currency: "USD",
                establishesCoverage: true))
        let completeUSD = SpendDashboardModel.ProviderInput(
            id: "complete-usd",
            provider: .claude,
            displayName: "Complete USD",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [],
                historyDays: 1,
                last30DaysTokens: 0,
                last30DaysCostUSD: 0))
        let tokenOnly = SpendDashboardModel.ProviderInput(
            id: "token-only",
            provider: .mistral,
            displayName: "Token only",
            snapshot: Self.mistralSnapshot(
                totalCost: 5,
                totalTokens: 0,
                currency: "EUR",
                establishesCoverage: true))
        let groups = SpendDashboardModel.build(
            inputs: [costOnly, completeUSD, tokenOnly],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups
        let eur = try #require(groups.first(where: { $0.currencyCode == "EUR" }))
        let usd = try #require(groups.first(where: { $0.currencyCode == "USD" }))

        #expect(usd.totalCost == 0)
        #expect(usd.totalTokens == nil)
        #expect(usd.modelHistoryCompleteness == .complete)
        #expect(eur.totalCost == nil)
        #expect(eur.totalTokens == 0)
        #expect(eur.modelHistoryCompleteness == .incomplete)
    }

    private static func input(
        id: String,
        provider: UsageProvider,
        currency: String,
        cost: Double) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: provider.rawValue,
            snapshot: self.snapshot(
                currency: currency,
                entries: [self.entry(day: "2026-07-16", cost: cost)]))
    }

    private static func snapshot(
        currency: String,
        entries: [CostUsageDailyReport.Entry],
        historyDays: Int = 30,
        last30DaysTokens: Int? = nil,
        last30DaysCostUSD: Double? = nil,
        updatedAt: Date = now) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: last30DaysTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            currencyCode: currency,
            historyDays: historyDays,
            daily: entries,
            updatedAt: updatedAt)
    }

    private static func mistralSnapshot(
        totalCost: Double,
        totalTokens: Int,
        currency: String = "USD",
        establishesCoverage: Bool = false) -> CostUsageTokenSnapshot
    {
        MistralUsageSnapshot(
            totalCost: totalCost,
            currency: currency,
            currencySymbol: currency,
            totalInputTokens: totalTokens,
            totalOutputTokens: 0,
            totalCachedTokens: 0,
            modelCount: 0,
            daily: [],
            startDate: establishesCoverage ? self.now : nil,
            endDate: establishesCoverage ? self.now : nil,
            updatedAt: self.now)
            .toCostUsageTokenSnapshot(historyDays: 7)
    }

    private static func entry(
        day: String,
        cost: Double?,
        tokens: Int? = 10,
        model: String? = "test-model") -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: model.map {
                [.init(modelName: $0, costUSD: cost, totalTokens: tokens)]
            })
    }

    private static func entryWithBreakdowns(
        day: String,
        totalCost: Double = 0,
        totalTokens: Int = 0,
        breakdowns: [CostUsageDailyReport.ModelBreakdown]) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: totalTokens,
            costUSD: totalCost,
            modelsUsed: nil,
            modelBreakdowns: breakdowns)
    }

    private static func mistralBucket(day: String, cost: Double, tokens: Int) -> MistralDailyUsageBucket {
        MistralDailyUsageBucket(
            day: day,
            cost: cost,
            inputTokens: tokens,
            cachedTokens: 0,
            outputTokens: 0,
            models: [
                .init(
                    name: "test-model",
                    cost: cost,
                    inputTokens: tokens,
                    cachedTokens: 0,
                    outputTokens: 0),
            ])
    }

    private static let now = Date(timeIntervalSince1970: 1_784_179_200)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
