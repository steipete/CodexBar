import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

struct ClaudeIncompleteUsagePropagationTests {
    @Test(arguments: ["incomplete", "negative-cost", "negative-tokens", "unnamed"])
    func `same day unpriced and incomplete models retain only valid attributed rows`(scenario: String) throws {
        let pendingName = scenario == "unnamed" ? "" : "fixture-pending-model"
        let entry = CostUsageDailyReport.Entry(
            date: "2026-09-16",
            inputTokens: 100,
            outputTokens: 0,
            totalTokens: 100,
            costUSD: nil,
            modelsUsed: ["fixture-unpriced-model", pendingName],
            modelBreakdowns: [
                .init(modelName: "fixture-unpriced-model", costUSD: nil, totalTokens: 100),
                .init(
                    modelName: pendingName,
                    costUSD: scenario == "negative-cost" ? -1 : nil,
                    totalTokens: scenario == "negative-tokens" ? -1 : nil,
                    incompleteRequestCount: 1),
            ])
        let model = Self.dashboard(snapshot: Self.snapshot(entries: [entry]))
        let group = try #require(model.groups.first)
        let exported = try #require(SpendDashboardExportPayload.make(model: model, hiddenSourceIDs: []).groups.first)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.incompleteRequestCount == 1)
        if scenario != "incomplete" {
            #expect(group.models.isEmpty)
            #expect(exported.models.isEmpty)
            return
        }
        #expect(group.models.count == 2)
        let unpriced = try #require(group.models.first { $0.modelName == "fixture-unpriced-model" })
        let pending = try #require(group.models.first { $0.modelName == pendingName })
        #expect(unpriced.totalTokens == 100)
        #expect(unpriced.totalCost == nil)
        #expect(pending.totalTokens == nil)
        #expect(pending.totalCost == nil)
        #expect(pending.incompleteRequestCount == 1)
        #expect(group.hasPartialTokens)
        #expect(ShareStatsBuilder.make(model: model)?.topModels.isEmpty == true)
        #expect(exported.models.count == 2)
        #expect(exported.models.first { $0.modelName == "fixture-unpriced-model" }?.totalTokens == 100)
        #expect(exported.models.first { $0.modelName == pendingName }?.incompleteRequestCount == 1)
    }

    @Test
    func `CLI retains known subtotals and exposes exclusions at every JSON level`() throws {
        let snapshot = Self.snapshot()
        let payload = CodexBarCLI.makeCostPayload(provider: .claude, snapshot: snapshot, error: nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(json["incompleteRequestCount"] as? Int == 2)
        let totals = try #require(json["totals"] as? [String: Any])
        #expect(totals["totalCost"] as? Double == 5)
        #expect(totals["totalTokens"] as? Int == 300)
        #expect(totals["incompleteRequestCount"] as? Int == 2)
        let daily = try #require(json["daily"] as? [[String: Any]])
        #expect(daily[0]["incompleteRequestCount"] == nil)
        #expect(daily[1]["incompleteRequestCount"] as? Int == 1)
        #expect(daily[2]["totalCost"] == nil)
        #expect(daily[2]["totalTokens"] == nil)
        #expect(daily[2]["incompleteRequestCount"] as? Int == 1)
        let models = try #require(daily[2]["modelBreakdowns"] as? [[String: Any]])
        #expect(models[0]["incompleteRequestCount"] as? Int == 1)
        #expect(models[0]["cost"] == nil)

        let text = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: snapshot,
            useColor: false,
            calendar: Self.calendar,
            includeBreakdown: true)
        #expect(text.contains("Today: — · Incomplete"))
        #expect(text.contains("Incomplete: 2 requests"))
        #expect(text.contains("Top models (last 7 calendar days — partial):"))
        let ranking = try #require(text.split(separator: "\n").first { $0.hasPrefix("1. ") })
        #expect(ranking.contains(UsageFormatter.currencyString(5, currencyCode: "USD")))
        #expect(ranking.contains("300 tokens"))
        #expect(ranking.contains("Incomplete"))
    }

    @Test
    func `older exclusions do not contaminate Today or the seven day detail`() {
        let snapshot = Self.snapshot(entries: [
            Self.entry(day: "2026-09-01", cost: nil, tokens: nil, incomplete: 1),
            Self.entry(day: "2026-09-16", cost: 0, tokens: 0),
        ])
        let text = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: snapshot,
            useColor: false,
            calendar: Self.calendar,
            includeBreakdown: true)
        let today = text.split(separator: "\n").first { $0.hasPrefix("Today:") }
        #expect(today?.contains("Incomplete") == false)
        #expect(text.contains("Top models (last 7 calendar days):"))
        #expect(!text.contains("Top models (last 7 calendar days — partial):"))
        #expect(text.contains("Incomplete: 1 requests"))
    }

    @Test(arguments: [false, true])
    func `native subtotals remain partial and sharing cannot rank an incomplete window`(selectedDay: Bool) throws {
        let model = Self.dashboard(snapshot: Self.snapshot(), selectedDay: selectedDay ? Self.now : nil)
        let group = try #require(model.groups.first)
        #expect(group.totalCost == 5)
        #expect(group.totalTokens == 300)
        #expect(group.incompleteRequestCount == 2)
        #expect(group.providers.first?.incompleteRequestCount == 2)
        #expect(group.hasPartialCost)
        #expect(group.hasPartialTokens)
        #expect(group.modelHistoryCompleteness == .incomplete)
        if !selectedDay {
            #expect(group.models.first?.totalCost == 5)
            #expect(group.models.first?.totalTokens == 300)
            #expect(group.models.first?.incompleteRequestCount == 2)
        }
        #expect(group.dailySummaries.last?.incompleteRequestCount == 1)
        #expect(group.dailySummaries.last?.totalCost == nil)
        let mixedDay = Self.calendar.startOfDay(for: Self.now.addingTimeInterval(-86400))
        let mixedSummary = try #require(group.dailySummaries.first { $0.day == mixedDay })
        #expect(mixedSummary.totalTokens == 200)
        #expect(mixedSummary.incompleteRequestCount == 1)
        // The activity heatmap and cumulative view require complete coverage, unlike subtotal rows.
        let heatmapDay = try #require(model.tokenActivity.first { $0.day == mixedDay })
        #expect(heatmapDay.totalTokens == nil)
        #expect(heatmapDay.isScanned)
        let share = try #require(ShareStatsBuilder.make(model: model))
        #expect(share.topModels.isEmpty)
        #expect(share.currencies.first?.isPartial == true)
        #expect(share.hasPartialTokens)
        let payload = SpendDashboardExportPayload.make(model: model, hiddenSourceIDs: [])
        #expect(payload.groups.first?.incompleteRequestCount == 2)
        #expect(payload.groups.first?.providers.first?.incompleteRequestCount == 2)
    }

    @Test
    func `selecting a complete day does not share it as a complete window ranking`() throws {
        let completeDay = Self.now.addingTimeInterval(-2 * 86400)
        let model = Self.dashboard(snapshot: Self.snapshot(), selectedDay: completeDay)
        let group = try #require(model.groups.first)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.first?.incompleteRequestCount == 0)
        #expect(group.incompleteRequestCount == 2)
        #expect(ShareStatsBuilder.make(model: model)?.topModels.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func `unpriced or zero measured history survives an excluded day`(zero: Bool) throws {
        let entries = [
            Self.entry(day: "2026-09-14", cost: zero ? 0 : nil, tokens: zero ? 0 : 100),
            Self.entry(day: "2026-09-16", cost: nil, tokens: nil, incomplete: 1),
        ]
        let group = try #require(Self.dashboard(snapshot: Self.snapshot(entries: entries)).groups.first)
        #expect(group.totalTokens == (zero ? 0 : 100))
        #expect(group.totalCost == (zero ? 0 : nil))
        #expect(group.models.first?.totalTokens == (zero ? 0 : 100))
        #expect(group.models.first?.totalCost == (zero ? 0 : nil))
        #expect(group.models.first?.incompleteRequestCount == 1)
        #expect(group.hasPartialTokens)
    }

    @Test
    func `currency conversion preserves excluded counts in native exports`() throws {
        let rate = try #require(CurrencyExchange.shared.rate(for: "EUR"))
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: Self.snapshot())],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar,
            preferredCurrencyCode: "EUR")
        let group = try #require(SpendDashboardExportPayload.make(model: model, hiddenSourceIDs: []).groups.first)
        #expect(group.currencyCode == "EUR")
        #expect(abs((group.totalCost ?? -1) - 5 * rate) < 1e-9)
        #expect(group.incompleteRequestCount == 2)
        #expect(group.providers.first?.incompleteRequestCount == 2)
        #expect(group.models.first?.incompleteRequestCount == 2)
    }

    @Test
    func `incomplete only history is unavailable while complete zero keeps the legacy JSON shape`() throws {
        let missing = Self.snapshot(entries: [Self.entry(day: "2026-09-16", cost: nil, tokens: nil, incomplete: 1)])
        let group = try #require(Self.dashboard(snapshot: missing).groups.first)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.models.first?.totalCost == nil)
        #expect(group.models.first?.totalTokens == nil)
        let text = CodexBarCLI.renderCostText(
            provider: .claude,
            snapshot: missing,
            useColor: false,
            calendar: Self.calendar,
            includeBreakdown: true)
        #expect(text.contains("— · — tokens"))
        let zero = Self.snapshot(entries: [Self.entry(day: "2026-09-16", cost: 0, tokens: 0)])
        let payload = CodexBarCLI.makeCostPayload(provider: .claude, snapshot: zero, error: nil)
        let json = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        #expect(!json.contains("incompleteRequestCount"))
        #expect(json.contains("\"totalCost\":0"))
    }

    @Test
    func `inline mode preserves unavailable days and marks its independent totals and hover text`() throws {
        let model = try UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: #require(ProviderDefaults.metadata[.claude]),
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: Self.snapshot(),
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            costSummaryInlineEnabled: true,
            tokenCostMenuSectionEnabled: false,
            costComparisonPeriodsEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: true,
            preferredCurrencyCode: "USD",
            costUsageBucketCalendar: Self.calendar,
            now: Self.now))
        let inline = try #require(model.inlineUsageDashboard)
        #expect(inline.kpis.first?.value == "— · Incomplete")
        #expect(inline.kpis.first(where: { $0.title == "30d tokens" })?.value == "300 · Incomplete")
        #expect(inline.detailLines.contains(where: { $0.contains("Excluded requests with missing final usage: 2") }))
        #expect(!inline.detailLines.contains(where: { $0.contains("Top model") }))
        #expect(inline.detailLines.contains(where: { $0.hasPrefix("Last 7 days:") && $0.contains("Incomplete") }))
        let point = try #require(inline.points.first(where: { $0.id == "2026-09-16" }))
        #expect(point.value == nil)
        #expect(point.hoverDetail?.incompleteRequestCount == 1)
        #expect(point.accessibilityValue.contains("— · — tokens · Incomplete"))
    }

    static let now = Date(timeIntervalSince1970: 1_789_560_000) // 2026-09-16 12:00 UTC.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func entry(day: String, cost: Double?, tokens: Int?, incomplete: Int? = nil) -> CostUsageDailyReport.Entry {
        .init(
            date: day,
            inputTokens: tokens,
            outputTokens: tokens.map { _ in 0 },
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: ["gpt-5.6-sol"],
            modelBreakdowns: [
                .init(modelName: "gpt-5.6-sol", costUSD: cost, totalTokens: tokens, incompleteRequestCount: incomplete),
            ])
    }

    static func snapshot(entries: [CostUsageDailyReport.Entry]? = nil) -> CostUsageTokenSnapshot {
        let entries = entries ?? [
            Self.entry(day: "2026-09-14", cost: 2, tokens: 100),
            Self.entry(day: "2026-09-15", cost: 3, tokens: 200, incomplete: 1),
            Self.entry(day: "2026-09-16", cost: nil, tokens: nil, incomplete: 1),
        ]
        let today = entries.first { $0.date == "2026-09-16" }
        let costs = entries.compactMap(\.costUSD)
        let tokens = entries.compactMap(\.totalTokens)
        return .init(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: today?.costUSD,
            last30DaysTokens: tokens.isEmpty ? nil : tokens.reduce(0, +),
            last30DaysCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            costProvenance: .listPriceEstimate,
            daily: entries,
            updatedAt: Self.now)
    }

    static func dashboard(snapshot: CostUsageTokenSnapshot, selectedDay: Date? = nil) -> SpendDashboardModel {
        .build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 30,
            now: self.now,
            calendar: self.calendar,
            selectedDay: selectedDay)
    }
}
