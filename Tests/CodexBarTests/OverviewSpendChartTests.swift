import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct OverviewSpendChartTests {
    private static func row(
        _ provider: UsageProvider,
        cost: Double?,
        models: [(String, Double)] = []) -> SpendDashboardModel.DailyProviderRow
    {
        SpendDashboardModel.DailyProviderRow(
            modelCosts: models.map { .init(modelName: $0.0, cost: $0.1) },
            sourceID: provider.rawValue,
            provider: provider,
            displayName: provider.rawValue,
            totalTokens: nil,
            requestCount: nil,
            totalCost: cost)
    }

    @Test(arguments: [false, true])
    func `higher effort is darker within every provider`(dark: Bool) {
        for provider in UsageProvider.allCases {
            let lightness = [ModelEffortTier.high, .standard, .fast].map {
                OverviewSpendPalette.oklch(OverviewSpendPalette.color(provider: provider, tier: $0, dark: dark))
                    .lightness
            }
            #expect(lightness[0] < lightness[1] && lightness[1] < lightness[2], "\(provider)")
        }
    }

    @Test(arguments: ModelEffortTier.allCases)
    func `Claude is muted on dark but stays in its brand hue`(tier: ModelEffortTier) {
        let brand = OverviewSpendPalette.oklch(ProviderDescriptorRegistry.descriptor(for: .claude).branding.color)
        let dark = OverviewSpendPalette.oklch(OverviewSpendPalette.color(provider: .claude, tier: tier, dark: true))
        let light = OverviewSpendPalette.oklch(OverviewSpendPalette.color(provider: .claude, tier: tier, dark: false))
        #expect(dark.chroma <= 0.095)
        #expect(dark.chroma > 0.05)
        #expect(abs(dark.hue - brand.hue) <= 10)
        #expect(light.chroma > dark.chroma)
    }

    @Test(arguments: [false, true])
    func `no provider renders as saturated orange`(dark: Bool) {
        for provider in UsageProvider.allCases {
            for tier in ModelEffortTier.allCases {
                let color = OverviewSpendPalette.oklch(OverviewSpendPalette.color(
                    provider: provider,
                    tier: tier,
                    dark: dark))
                let isOrangeHue = (40.0...75.0).contains(color.hue)
                #expect(!(isOrangeHue && color.chroma > 0.11), "\(provider) \(tier)")
            }
        }
    }

    @Test
    func `common providers get separate hues anchored to their brand`() {
        // A mono brand has no meaningful hue to compare.
        let hues = OverviewSpendPalette.anchoredProviders
            .map { OverviewSpendPalette.anchor(for: $0) }
            .filter { $0.chroma > 0.05 }
            .map(\.hue)
        let sorted = hues.sorted()
        for (lhs, rhs) in zip(sorted, sorted.dropFirst()) {
            #expect(rhs - lhs >= 5, "\(lhs) \(rhs)")
        }
        let claude = OverviewSpendPalette.oklch(ProviderDescriptorRegistry.descriptor(for: .claude).branding.color)
        #expect(abs(OverviewSpendPalette.anchor(for: .claude).hue - claude.hue) <= 10)
        let codex = OverviewSpendPalette.oklch(ProviderDescriptorRegistry.descriptor(for: .codex).branding.color)
        #expect(abs(OverviewSpendPalette.anchor(for: .codex).hue - codex.hue) <= 10)
    }

    @Test
    func `segments stack by provider then effort and sum to the day`() {
        let legend = [
            OverviewDailySpend.LegendEntry(provider: .claude, name: "Claude", share: 0.7),
            OverviewDailySpend.LegendEntry(provider: .codex, name: "Codex", share: 0.3),
        ]
        let segments = OverviewDailySpend.segments(
            rows: [
                Self.row(.codex, cost: 3, models: [("gpt-5-codex-mini", 1), ("gpt-5.1-codex-max", 2)]),
                Self.row(.claude, cost: 7, models: [
                    ("claude-haiku-4-5", 1),
                    ("claude-opus-4-5", 4),
                    ("claude-sonnet-4-5", 2),
                ]),
            ],
            legend: legend)
        #expect(segments.map(\.provider) == [.claude, .claude, .claude, .codex, .codex])
        #expect(segments.map(\.tier) == [.high, .standard, .fast, .high, .fast])
        #expect(segments.map(\.cost).reduce(0, +) == 10)
    }

    @Test
    func `cost without model detail stays visible at the standard tier`() {
        let legend = [OverviewDailySpend.LegendEntry(provider: .cursor, name: "Cursor", share: 1)]
        let noDetail = OverviewDailySpend.segments(rows: [Self.row(.cursor, cost: 5)], legend: legend)
        #expect(noDetail == [.init(provider: .cursor, tier: .standard, cost: 5)])

        let partial = OverviewDailySpend.segments(
            rows: [Self.row(.cursor, cost: 5, models: [("cursor-small", 2)])],
            legend: legend)
        #expect(partial == [.init(provider: .cursor, tier: .standard, cost: 5)])
    }

    @Test(arguments: [1.0, 4.0])
    func `inconsistent model totals keep an unclassified provider block`(attributed: Double) {
        let legend = [OverviewDailySpend.LegendEntry(provider: .codex, name: "Codex", share: 1)]
        let segments = OverviewDailySpend.segments(
            rows: [Self.row(.codex, cost: 2, models: [
                ("fixture-max", attributed * 0.75),
                ("fixture-mini", attributed * 0.25),
            ])],
            legend: legend)
        #expect(segments == [.init(provider: .codex, tier: .standard, cost: 2)])
    }

    @Test
    func `a thin tier folds into the largest tier and readable shades stay`() {
        let segments: [OverviewDailySpend.Segment] = [
            .init(provider: .claude, tier: .high, cost: 50),
            .init(provider: .claude, tier: .standard, cost: 29),
            .init(provider: .claude, tier: .fast, cost: 1),
            .init(provider: .kimi, tier: .high, cost: 1),
            .init(provider: .kimi, tier: .fast, cost: 1),
            .init(provider: nil, tier: .standard, cost: 18),
        ]
        let merged = OverviewDailySpend.mergingThinTiers(segments, barHeight: 50, minimumTierHeight: 2.5)
        #expect(merged == [
            .init(provider: .claude, tier: .high, cost: 51),
            .init(provider: .claude, tier: .standard, cost: 29),
            .init(provider: .kimi, tier: .standard, cost: 2),
            .init(provider: nil, tier: .standard, cost: 18),
        ])
    }

    @Test
    func `tiny unattributed provider costs remain visible`() {
        let legend = [OverviewDailySpend.LegendEntry(provider: .codex, name: "Codex", share: 1)]
        let segments = OverviewDailySpend.segments(rows: [Self.row(.codex, cost: 1e-10)], legend: legend)
        #expect(segments == [.init(provider: .codex, tier: .standard, cost: 1e-10)])
    }

    @Test
    func `an unknown provider cost draws nothing`() {
        let legend = [OverviewDailySpend.LegendEntry(provider: .codex, name: "Codex", share: 1)]
        #expect(OverviewDailySpend.segments(rows: [Self.row(.codex, cost: nil)], legend: legend).isEmpty)
    }

    @Test
    func `eight providers all show and a ninth folds the tail into other`() {
        let providers: [UsageProvider] = [
            .claude, .codex, .cursor, .gemini, .copilot, .factory, .windsurf, .kimi, .grok,
        ]
        let rows = providers.enumerated().map { Self.row($0.element, cost: Double(20 - $0.offset)) }
        let totals = rows.compactMap { row in row.totalCost.map { (row.provider, $0) } }
        let eight = OverviewDailySpend.legend(totals: Array(totals.prefix(8)))
        #expect(eight.count == 8)
        #expect(eight.allSatisfy { $0.provider != nil })

        let nine = OverviewDailySpend.legend(totals: totals)
        #expect(nine.count == 8)
        #expect(nine.last?.provider == nil)
        let rangeShares: [Double?] = nine.map(\.share)
        #expect(rangeShares.allSatisfy { $0 != nil })
        #expect(abs(rangeShares.compactMap(\.self).reduce(0, +) - 1) < 0.000_001)

        let segments = OverviewDailySpend.segments(rows: rows, legend: nine)
        #expect(segments.last?.provider == nil)
        #expect(segments.map(\.cost).reduce(0, +) == rows.compactMap(\.totalCost).reduce(0, +))
    }

    @Test
    func `providers without spend stay out of the legend`() {
        let legend = OverviewDailySpend.legend(totals: [(.claude, 4), (.copilot, 0)])
        #expect(legend.map(\.provider) == [.claude])
    }

    @Test
    func `legend shares switch to the hovered day`() {
        let legend = [
            OverviewDailySpend.LegendEntry(provider: .claude, name: "Claude", share: 0.9),
            OverviewDailySpend.LegendEntry(provider: .codex, name: "Codex", share: 0.1),
        ]
        let daily = OverviewDailySpend(
            points: [MenuUsageBarPoint(id: "d", value: 4)],
            todayText: "Today",
            stacks: ["d": [
                .init(provider: .claude, tier: .high, cost: 1),
                .init(provider: .codex, tier: .high, cost: 3),
            ]],
            legend: legend)
        #expect(daily.share(of: legend[1], pointID: nil) == 0.1)
        #expect(daily.share(of: legend[1], pointID: "d") == 0.75)
        #expect(daily.share(of: legend[1], pointID: "missing") == 0)
    }

    @Test
    func `merged accounts take the provider name in the legend`() {
        let legend = OverviewDailySpend.legend(totals: [(.codex, 3), (.codex, 7)])
        #expect(legend.map(\.name) == [ProviderDescriptorRegistry.descriptor(for: .codex).metadata.displayName])
        #expect(legend.first?.share == 1)
    }

    // MARK: - Real dashboard model

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func entry(
        daysAgo: Int,
        cost: Double,
        now: Date,
        calendar: Calendar,
        unpriced: Int? = nil) throws -> CostUsageDailyReport.Entry
    {
        let day = try #require(calendar.date(byAdding: .day, value: -daysAgo, to: now))
        return CostUsageDailyReport.Entry(
            date: Self.dayFormatter.string(from: day),
            inputTokens: 5,
            outputTokens: 5,
            totalTokens: 10,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unpricedRequestCount: unpriced)
    }

    private static func dashboard(
        _ inputs: [(UsageProvider, [CostUsageDailyReport.Entry], Int?)],
        requestedDays: Int,
        reportingPeriod: CostReportingPeriod,
        now: Date,
        calendar: Calendar) -> SpendDashboardModel
    {
        SpendDashboardModel.build(
            inputs: inputs.map { provider, entries, coveredDays in
                .init(
                    provider: provider,
                    displayName: provider.rawValue,
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        historyDays: coveredDays ?? 30,
                        daily: entries,
                        updatedAt: now))
            },
            requestedDays: requestedDays,
            reportingPeriod: reportingPeriod,
            now: now,
            calendar: calendar,
            preferredCurrencyCode: "USD")
    }

    @Test
    @MainActor
    func `the chart ends on the last reporting day and not the day after`() throws {
        let calendar = Calendar.current
        let now = Date()
        let model = try Self.dashboard(
            [(.claude, [
                Self.entry(daysAgo: 0, cost: 4, now: now, calendar: calendar),
                Self.entry(daysAgo: 6, cost: 2, now: now, calendar: calendar),
            ], nil)],
            requestedDays: 7,
            reportingPeriod: .rolling(days: 7),
            now: now,
            calendar: calendar)
        let daily = try #require(OverviewDailySpend.make(model: model))
        #expect(daily.points.count == 7)
        #expect(daily.points.first?.value == 2)
        #expect(daily.points.last?.value == 4)
        #expect(daily.legend.map(\.provider) == [.claude])
        #expect(daily.todayText.contains("4"))
    }

    @Test
    @MainActor
    func `range shares come from full window totals when coverage differs`() throws {
        let calendar = Calendar.current
        let now = Date()
        let model = try Self.dashboard(
            [
                (.claude, [Self.entry(daysAgo: 20, cost: 40, now: now, calendar: calendar)], nil),
                (.codex, [Self.entry(daysAgo: 0, cost: 10, now: now, calendar: calendar)], 7),
            ],
            requestedDays: 30,
            reportingPeriod: .rolling(days: 30),
            now: now,
            calendar: calendar)
        let daily = try #require(OverviewDailySpend.make(model: model))
        let claude = try #require(daily.legend.first { $0.provider == .claude })
        let codex = try #require(daily.legend.first { $0.provider == .codex })
        let claudeShare: Double? = claude.share
        let codexShare: Double? = codex.share
        #expect(claudeShare == 0.8)
        #expect(codexShare == 0.2)
    }

    @Test
    @MainActor
    func `a provider with unavailable range spend retains its priced daily contribution`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
        func entry(_ date: String, cost: Double?) -> CostUsageDailyReport.Entry {
            CostUsageDailyReport.Entry(
                date: date,
                inputTokens: 5,
                outputTokens: 5,
                totalTokens: 10,
                costUSD: cost,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let model = Self.dashboard(
            [
                (.claude, [entry("2026-07-15", cost: nil), entry("2026-07-16", cost: 2)], 2),
                (.codex, [entry("2026-07-15", cost: 0), entry("2026-07-16", cost: 3)], 2),
            ],
            requestedDays: 2,
            reportingPeriod: .rolling(days: 2),
            now: now,
            calendar: calendar)
        let group = try #require(model.groups.first)
        let claude = try #require(group.providers.first { $0.provider == .claude })
        let codex = try #require(group.providers.first { $0.provider == .codex })
        // A known day must not be promoted to a complete range total just to join the chart.
        #expect(claude.totalCost == nil)
        #expect(codex.totalCost == 3)
        #expect(group.hasPartialCost)

        let day = calendar.startOfDay(for: now)
        let summary = try #require(group.dailySummaries.first { $0.day == day })
        #expect(summary.totalCost == 5)
        #expect(!summary.hasPartialCost)
        let daily = try #require(OverviewDailySpend.make(model: model))
        let pointID = "\(day.timeIntervalSince1970)"
        #expect(daily.points.first { $0.id == pointID }?.value == 5)
        let segments = try #require(daily.stacks[pointID])
        #expect(segments.filter { $0.provider == .claude }.map(\.cost).reduce(0, +) == 2)
        #expect(segments.filter { $0.provider == .codex }.map(\.cost).reduce(0, +) == 3)
        #expect(segments.map(\.cost).reduce(0, +) == summary.totalCost)

        let codexLegend = try #require(daily.legend.first { $0.provider == .codex })
        let codexRangeShare: Double? = daily.share(of: codexLegend, pointID: nil)
        #expect(codexRangeShare == nil)
        let claudeLegend = try #require(daily.legend.first { $0.provider == .claude })
        let claudeShare: Double? = daily.share(of: claudeLegend, pointID: pointID)
        let codexShare: Double? = daily.share(of: codexLegend, pointID: pointID)
        #expect(try abs(#require(claudeShare) - 0.4) < 0.000_001)
        #expect(try abs(#require(codexShare) - 0.6) < 0.000_001)
        let claudeRangeShare: Double? = daily.share(of: claudeLegend, pointID: nil)
        #expect(claudeRangeShare == nil)
        // Hovering a complete day does not make the source's other unpriced day complete.
        #expect(group.providers.first { $0.provider == .claude }?.totalCost == nil)
        #expect(group.hasPartialCost)
    }

    @Test
    @MainActor
    func `a partial day keeps its marker in the readouts`() throws {
        let calendar = Calendar.current
        let now = Date()
        let model = try Self.dashboard(
            [(.claude, [Self.entry(daysAgo: 0, cost: 3, now: now, calendar: calendar, unpriced: 2)], nil)],
            requestedDays: 7,
            reportingPeriod: .rolling(days: 7),
            now: now,
            calendar: calendar)
        let daily = try #require(OverviewDailySpend.make(model: model))
        #expect(daily.todayText.contains("~"))
        #expect(daily.points.last?.hoverSummary?.contains("~") == true)
    }

    @Test
    func `daily rows carry model costs through the dashboard build`() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: 30,
            last30DaysCostUSD: 3,
            daily: [CostUsageDailyReport.Entry(
                date: formatter.string(from: now),
                inputTokens: 15,
                outputTokens: 15,
                totalTokens: 30,
                costUSD: 3,
                modelsUsed: ["claude-opus-4-5", "claude-haiku-4-5"],
                modelBreakdowns: [
                    .init(modelName: "claude-opus-4-5", costUSD: 2, totalTokens: 20),
                    .init(modelName: "claude-haiku-4-5", costUSD: 1, totalTokens: 10),
                ])],
            updatedAt: now)
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 30,
            reportingPeriod: .rolling(days: 30),
            now: now,
            calendar: .current,
            preferredCurrencyCode: "USD")
        let rows = model.groups.first?.dailySummaries.flatMap(\.providers).flatMap(\.modelCosts) ?? []
        #expect(rows.map(\.modelName) == ["claude-opus-4-5", "claude-haiku-4-5"])
        #expect(rows.map(\.cost) == [2, 1])
    }
}
