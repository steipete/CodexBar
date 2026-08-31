import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct InlineCostHistoryDashboardLabelTests {
    @Test
    func `local cost history Today KPI uses current day session value`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 0,
            sessionCostUSD: 0,
            last30DaysTokens: 275,
            last30DaysCostUSD: 0.25,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.kpis.first?.title == "Today")
        #expect(model.inlineUsageDashboard?.kpis.first?.value == "$0.00")
        #expect(model.inlineUsageDashboard?.points.first?.accessibilityValue == "2023-11-15: $0.25")
    }

    @Test
    func `local cost history converts from snapshot currency into preferred currency`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 100,
            sessionCostUSD: 10,
            last30DaysTokens: 100,
            last30DaysCostUSD: 10,
            currencyCode: "EUR",
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 75,
                    outputTokens: 25,
                    totalTokens: 100,
                    costUSD: 10,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            preferredCurrencyCode: "USD",
            now: now))

        let expected = UsageFormatter.convertedCostString(
            10,
            preferredCurrency: "USD",
            providerCurrency: "EUR")
        let expectedValue = UsageFormatter.convertedCost(
            10,
            preferredCurrency: "USD",
            providerCurrency: "EUR").value
        #expect(model.inlineUsageDashboard?.currencyCode == "USD")
        #expect(model.inlineUsageDashboard?.kpis.first?.value == expected)
        #expect(model.inlineUsageDashboard?.points.first?.value == expectedValue)
        #expect(model.inlineUsageDashboard?.points.first?.accessibilityValue == "2023-11-15: \(expected)")
    }

    @Test
    func `local cost history KPI titles preserve one day and dynamic windows`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let daily = [
            CostUsageDailyReport.Entry(
                date: "2023-11-14",
                inputTokens: 100,
                outputTokens: 50,
                totalTokens: 150,
                costUSD: 0.12,
                modelsUsed: ["claude-sonnet-4"],
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2023-11-15",
                inputTokens: 200,
                outputTokens: 75,
                totalTokens: 275,
                costUSD: 0.25,
                modelsUsed: ["claude-opus-4"],
                modelBreakdowns: nil),
        ]

        func makeModel(historyDays: Int) -> UsageMenuCardView.Model {
            let tokenSnapshot = CostUsageTokenSnapshot(
                sessionTokens: 275,
                sessionCostUSD: 0.25,
                last30DaysTokens: 425,
                last30DaysCostUSD: 0.37,
                historyDays: historyDays,
                daily: daily,
                updatedAt: now)
            return UsageMenuCardView.Model.make(.init(
                provider: .claude,
                metadata: metadata,
                snapshot: UsageSnapshot(
                    primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                    secondary: nil,
                    updatedAt: now),
                credits: nil,
                creditsError: nil,
                dashboard: nil,
                dashboardError: nil,
                tokenSnapshot: tokenSnapshot,
                tokenError: nil,
                account: AccountInfo(email: nil, plan: nil),
                isRefreshing: false,
                lastError: nil,
                usageBarsShowUsed: false,
                resetTimeDisplayStyle: .countdown,
                tokenCostUsageEnabled: true,
                showOptionalCreditsAndExtraUsage: true,
                hidePersonalInfo: false,
                now: now))
        }

        let oneDay = makeModel(historyDays: 1)
        #expect(oneDay.inlineUsageDashboard?.kpis.map(\.title) == [
            "Today", "Today", "Latest tokens", "Today tokens",
        ])

        let sevenDays = makeModel(historyDays: 7)
        #expect(sevenDays.inlineUsageDashboard?.kpis.map(\.title) == [
            "Today", "This week", "Latest tokens", "This week tokens",
        ])

        let thirtyDays = makeModel(historyDays: 30)
        #expect(thirtyDays.inlineUsageDashboard?.kpis.map(\.title) == [
            "Today", "This week", "Latest tokens", "This week tokens", "30d cost", "30d tokens",
        ])
    }

    @Test
    func `custom cost history KPI title keeps token label distinct`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 275,
            sessionCostUSD: 0.25,
            last30DaysTokens: 425,
            last30DaysCostUSD: 0.37,
            historyLabel: "This month",
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        #expect(model.inlineUsageDashboard?.kpis.map(\.title) == [
            "Today", "This week", "Latest tokens", "This week tokens", "This month", "This month tokens",
        ])
    }

    @Test
    func `costHistoryInlineDashboard sets currencyCode from snapshot`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 275,
            sessionCostUSD: 0.25,
            last30DaysTokens: 425,
            last30DaysCostUSD: 0.37,
            currencyCode: "USD",
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-15",
                    inputTokens: 200,
                    outputTokens: 75,
                    totalTokens: 275,
                    costUSD: 0.25,
                    modelsUsed: ["test-model"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "test-model",
                            costUSD: 0.25,
                            totalTokens: 275),
                    ]),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.currencyCode == "USD")
        #expect(dashboard.accessibilityLabel == "Codex: 30d cost")
        #expect(dashboard.kpis.map(\.title) == [
            "Today",
            "This week",
            "Latest tokens",
            "This week tokens",
            "30d",
            "30d tokens",
        ])
        #expect(dashboard.detailLines == [
            "Top model: test-model",
            "Estimated from token usage · not a subscription bill",
        ])

        let japaneseAccessibilityLabels = CodexBarLocalizationOverride.$appLanguage.withValue("ja") {
            [7, 30].map { historyDays in
                UsageMenuCardView.Model.make(.init(
                    provider: .codex,
                    metadata: metadata,
                    snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
                    credits: nil,
                    creditsError: nil,
                    dashboard: nil,
                    dashboardError: nil,
                    tokenSnapshot: CostUsageTokenSnapshot(
                        sessionTokens: 275,
                        sessionCostUSD: 0.25,
                        last30DaysTokens: 425,
                        last30DaysCostUSD: 0.37,
                        historyDays: historyDays,
                        daily: tokenSnapshot.daily,
                        updatedAt: now),
                    tokenError: nil,
                    account: AccountInfo(email: nil, plan: nil),
                    isRefreshing: false,
                    lastError: nil,
                    usageBarsShowUsed: false,
                    resetTimeDisplayStyle: .countdown,
                    tokenCostUsageEnabled: true,
                    showOptionalCreditsAndExtraUsage: true,
                    hidePersonalInfo: false,
                    now: now)).inlineUsageDashboard?.accessibilityLabel
            }
        }
        #expect(japaneseAccessibilityLabels == ["Codex: 過去7日間のコスト", "Codex: 過去30日間のコスト"])
    }

    @Test
    func `Codex inline cost history preserves zero value calendar days`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 24,
            hour: 12)))
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 400,
            sessionCostUSD: 4,
            last30DaysTokens: 700,
            last30DaysCostUSD: 7,
            historyDays: 4,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-08-21",
                    inputTokens: 250,
                    outputTokens: 50,
                    totalTokens: 300,
                    costUSD: 3,
                    modelsUsed: ["test-model"],
                    modelBreakdowns: nil),
                CostUsageDailyReport.Entry(
                    date: "2026-08-24",
                    inputTokens: 350,
                    outputTokens: 50,
                    totalTokens: 400,
                    costUSD: 4,
                    modelsUsed: ["test-model"],
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let points = try #require(model.inlineUsageDashboard?.points)
        #expect(points.map(\.id) == ["2026-08-21", "2026-08-22", "2026-08-23", "2026-08-24"])
        #expect(points.map(\.value) == [3, 0, 0, 4])
        #expect(points.map(\.accessibilityValue) == [
            "2026-08-21: $3.00",
            "2026-08-22: $0.00",
            "2026-08-23: $0.00",
            "2026-08-24: $4.00",
        ])
    }

    @Test
    func `cursor metered-only snapshot remains visible in inline dashboard`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.cursor])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            historyDays: 30,
            meteredCostUSD: 1.25,
            daily: [],
            updatedAt: now)
        let model = UsageMenuCardView.Model.make(.init(
            provider: .cursor,
            metadata: metadata,
            snapshot: UsageSnapshot(primary: nil, secondary: nil, updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.kpis.first?.title == "Cursor-metered")
        #expect(dashboard.kpis.first?.value == "$1.25")
        #expect(dashboard.points.isEmpty)
    }

    @Test
    func `token-only provider details use token chart units`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.zai])
        let details = try ProviderDetailSection(
            title: "Hourly tokens",
            rows: [.init(label: "glm-test", value: "123")],
            chart: .init(
                kind: .bars,
                title: "Hourly tokens",
                unit: "tokens",
                points: [.init(label: "2023-11-17 00:00", value: 123)]))
        let snapshot = UsageSnapshot(primary: nil, secondary: nil, details: [details], updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .zai,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))
        #expect(model.inlineUsageDashboard == nil)
        #expect(model.providerDetails.last?.chart?.unit == "tokens")
    }

    @Test
    func `codex and claude show this week KPIs and previous week history`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 15,
            hour: 12)))
        let resetAt = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 18,
            hour: 15)))
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 1000,
            sessionCostUSD: 10,
            last30DaysTokens: 1400,
            last30DaysCostUSD: 14,
            historyDays: 30,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-08",
                    inputTokens: 300,
                    outputTokens: 100,
                    totalTokens: 400,
                    costUSD: 4,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 4,
                            totalTokens: 400),
                    ]),
                CostUsageDailyReport.Entry(
                    date: "2026-07-13",
                    inputTokens: 800,
                    outputTokens: 200,
                    totalTokens: 1000,
                    costUSD: 10,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 10,
                            totalTokens: 1000),
                    ]),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 5 * 60,
                    resetsAt: now.addingTimeInterval(4 * 3600),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 50,
                    windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
                    resetsAt: resetAt,
                    resetDescription: nil),
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            costUsageBucketCalendar: calendar,
            now: now))

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.kpis.map(\.title) == [
            "Today",
            "This week",
            "Latest tokens",
            "This week tokens",
            "30d",
            "30d tokens",
        ])
        #expect(dashboard.kpis.map(\.value) == [
            "$10.00",
            "$10.00",
            "1K",
            "1K",
            "$14.00",
            "1.4K",
        ])
        #expect(dashboard.detailLines.contains { $0.contains("Last week") } == false)
        #expect(dashboard.quotaWindows.map(\.title) == ["This week", "Last week"])
        #expect(dashboard.quotaWindows.map(\.value) == ["$10.00 · 1K", "$4.00 · 400"])
        let currentRange = try #require(dashboard.quotaWindows.first?.range)
        #expect(currentRange.contains("11"))
        #expect(currentRange.contains("18"))
    }

    @Test
    func `quota window range labels use the reset instant and collapse same-day windows`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let locale = Locale(identifier: "en_US")
        let start = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 11,
            hour: 15)))
        let end = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 18,
            hour: 15)))
        let sameDayEnd = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 11,
            hour: 18)))

        let weekRange = Self.normalizedDateText(UsageMenuCardView.Model.quotaWindowRangeLabel(
            start: start,
            end: end,
            calendar: calendar,
            locale: locale))
        let sameDayRange = Self.normalizedDateText(UsageMenuCardView.Model.quotaWindowRangeLabel(
            start: start,
            end: sameDayEnd,
            calendar: calendar,
            locale: locale))
        #expect(weekRange.contains("Jul 11"))
        #expect(weekRange.contains("Jul 18"))
        #expect(weekRange.contains("3:00") || weekRange.contains("15:00"))
        #expect(sameDayRange.contains("Jul 11"))
        #expect(sameDayRange.contains("6:00") || sameDayRange.contains("18:00"))
        #expect(sameDayRange.contains("Jul 18") == false)
    }

    @Test
    func `codex recent windows lists a short previous window after a banked reset`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 17,
            hour: 12)))
        let official = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 16,
            hour: 15)))
        let liveNext = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 23,
            hour: 18)))
        let metadata = try #require(ProviderDefaults.metadata[.codex])
        let hour14 = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 16,
            hour: 14)))
        let hour16 = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 16,
            hour: 16)))
        let hour19 = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 16,
            hour: 19)))
        let tokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 300,
            sessionCostUSD: 3,
            last30DaysTokens: 600,
            last30DaysCostUSD: 6,
            historyDays: 30,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-16",
                    inputTokens: 500,
                    outputTokens: 100,
                    totalTokens: 600,
                    costUSD: 6,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: [
                        CostUsageDailyReport.ModelBreakdown(
                            modelName: "gpt-5.4",
                            costUSD: 6,
                            totalTokens: 600),
                    ]),
            ],
            hourly: [
                CostUsageHourlyEntry(hour: hour14, totalTokens: 100, costUSD: 1),
                CostUsageHourlyEntry(hour: hour16, totalTokens: 200, costUSD: 2),
                CostUsageHourlyEntry(hour: hour19, totalTokens: 300, costUSD: 3),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .codex,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: RateWindow(
                    usedPercent: 40,
                    windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
                    resetsAt: liveNext,
                    resetDescription: nil),
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: tokenSnapshot,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            costUsageBucketCalendar: calendar,
            now: now,
            observedWeeklyNextResets: [official]))

        let dashboard = try #require(model.inlineUsageDashboard)
        #expect(dashboard.quotaWindows.map(\.title) == [
            "This week",
            "Previous window",
            "2 weeks ago",
        ])
        #expect(dashboard.quotaWindows.map(\.value) == [
            "$3.00 · 300",
            "$2.00 · 200",
            "$1.00 · 100",
        ])
        #expect(dashboard.detailLines.contains { $0.contains("Previous window") } == false)
    }

    private static func normalizedDateText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}
