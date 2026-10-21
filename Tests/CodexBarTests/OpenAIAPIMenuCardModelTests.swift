import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct OpenAIAPIMenuCardModelTests {
    @Test
    func `admin usage model shows summaries and spend without fake quota bars`() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2023-11-14T01:00:00Z"))
        let bucketDay = try #require(ISO8601DateFormatter().date(from: "2023-11-14T00:00:00Z"))
        let metadata = try #require(ProviderDefaults.metadata[.openai])
        let apiUsage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: bucketDay,
                    endTime: bucketDay.addingTimeInterval(86400),
                    costUSD: 12.5,
                    requests: 40,
                    inputTokens: 1000,
                    cachedInputTokens: 250,
                    outputTokens: 500,
                    totalTokens: 1500,
                    lineItems: [
                        OpenAIAPIUsageSnapshot.LineItemBreakdown(name: "Text tokens", costUSD: 12.5),
                    ],
                    models: [
                        OpenAIAPIUsageSnapshot.ModelBreakdown(
                            name: "gpt-5.2",
                            requests: 40,
                            inputTokens: 1000,
                            cachedInputTokens: 250,
                            outputTokens: 500,
                            totalTokens: 1500),
                    ]),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .openai,
            metadata: metadata,
            snapshot: apiUsage.toUsageSnapshot(),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            costSummaryInlineEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            costUsageBucketCalendar: CostUsageBucketTimeZone.calendar(identifier: "America/Los_Angeles"),
            now: now))

        #expect(model.metrics.isEmpty)
        #expect(model.openAIAPIUsage != nil)
        #expect(model.inlineUsageDashboard?.kpis.first?.value == "$12.50")
        #expect(model.inlineUsageDashboard?.kpis.last?.title == "Requests")
        #expect(model.inlineUsageDashboard?.kpis.last?.value == "40")
        #expect(model.inlineUsageDashboard?.points.count == 30)
        #expect(model.inlineUsageDashboard?.points.last?.id == "2023-11-14")
        #expect(model.inlineUsageDashboard?.points.last?.value == 12.5)
        // Requests already appear as a KPI; the dashboard must not repeat them or add a source footer.
        #expect(model.inlineUsageDashboard?.detailLines.contains { $0.contains("requests") } == false)
        #expect(model.inlineUsageDashboard?.detailLines.contains { $0.contains("Reported by") } == false)
        #expect(model.providerCost == nil)
        #expect(model.usageNotes.contains { $0.contains("Today: $12.50") })
        #expect(model.usageNotes.contains("Top model: gpt-5.2"))
        #expect(model.creditsText == nil)
        #expect(model.planText == "Admin API")
    }

    @Test
    func `admin usage dashboard ignores stale token snapshot after fallback refresh`() throws {
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let metadata = try #require(ProviderDefaults.metadata[.openai])
        let staleTokenSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 1500,
            sessionCostUSD: 12.5,
            last30DaysTokens: 1500,
            last30DaysCostUSD: 12.5,
            daily: [
                CostUsageDailyReport.Entry(
                    date: "2023-11-14",
                    inputTokens: 1000,
                    outputTokens: 500,
                    totalTokens: 1500,
                    costUSD: 12.5,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .openai,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: staleTokenSnapshot,
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
        #expect(model.tokenUsage == nil)
    }

    @Test
    func `admin usage model can show cost card summary`() throws {
        let now = try Self.localNoon(year: 2023, month: 11, day: 17)
        let bucketDay = try Self.localNoon(year: 2023, month: 11, day: 14)
        let metadata = try #require(ProviderDefaults.metadata[.openai])
        let apiUsage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: bucketDay,
                    endTime: bucketDay.addingTimeInterval(86400),
                    costUSD: 12.5,
                    requests: 40,
                    inputTokens: 1000,
                    cachedInputTokens: 250,
                    outputTokens: 500,
                    totalTokens: 1500,
                    lineItems: [],
                    models: []),
            ],
            updatedAt: now)

        let model = UsageMenuCardView.Model.make(.init(
            provider: .openai,
            metadata: metadata,
            snapshot: apiUsage.toUsageSnapshot(),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: apiUsage.toCostUsageTokenSnapshot(),
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

        #expect(ProviderDescriptorRegistry.descriptor(for: .openai).tokenCost.supportsTokenCost)
        #expect(model.tokenUsage?.sessionLine == "Today: $0.00 · 0 tokens")
        #expect(model.tokenUsage?.monthLine == "Last 30 days: $12.50 · 1.5K tokens")
        #expect(model.tokenUsage?.hintLine == nil)
    }

    private static func localNoon(year: Int, month: Int, day: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }
}
