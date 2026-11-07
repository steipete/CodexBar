import AppKit
import CodexBarCore
import SwiftUI

extension OverviewDailySpend {
    /// One bar per day of the range, across providers. Single currency only: spend cannot be summed across them.
    static func make(model: SpendDashboardModel) -> OverviewDailySpend? {
        guard model.groups.count == 1, let group = model.groups.first, !group.dailySummaries.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = group.timeZone
        let summaries = Dictionary(
            group.dailySummaries.map { (calendar.startOfDay(for: $0.day), $0) },
            uniquingKeysWith: { first, _ in first })
        // The domain ends at the midnight after the reporting period, which is not a day the period includes.
        let last = calendar.startOfDay(for: group.chartDomain.upperBound.addingTimeInterval(-1))
        guard let first = calendar.date(byAdding: .day, value: 1 - model.requestedDays, to: last) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = codexBarLocalizedLocale()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        formatter.timeZone = group.timeZone
        // Daily summaries cover only days every provider can report; range shares use each full window.
        // A provider can still contribute priced days when its full-window total is unavailable.
        let legend = OverviewDailySpend.legend(
            totals: group.providers.compactMap { row in row.totalCost.map { (row.provider, $0) } },
            dailyRows: summaries.filter { $0.key >= first && $0.key <= last }.values.flatMap(\.providers),
            rangeSharesAvailable: group.providers.allSatisfy {
                $0.totalCost != nil && !$0.costIsLowerBound && $0.incompleteRequestCount == 0
            })
        var points: [MenuUsageBarPoint] = []
        var stacks: [String: [OverviewDailySpend.Segment]] = [:]
        var day = first
        while day <= last {
            let cost = summaries[day]?.totalCost
            let valueText = cost.flatMap { _ in summaries[day] }
                .map { spendDashboardLedgerCostText($0, currencyCode: group.currencyCode) }
            let summary = "\(formatter.string(from: day)): \(valueText ?? L("Unknown"))"
            let id = "\(day.timeIntervalSince1970)"
            let rows = summaries[day]?.providers ?? []
            stacks[id] = OverviewDailySpend.segments(rows: rows, legend: legend)
            let breakdown = rows.filter { ($0.totalCost ?? 0) > 0 }.map { row in
                let amount = spendDashboardBreakdownMetricText(
                    cost: row.totalCost,
                    tokens: nil,
                    currencyCode: group.currencyCode,
                    incompleteRequestCount: row.incompleteRequestCount,
                    costIsLowerBound: row.costIsLowerBound)
                return "\(row.displayName) \(amount)"
            }
            points.append(MenuUsageBarPoint(
                id: id,
                value: cost,
                hoverSummary: summary,
                accessibilityValue: ([summary] + breakdown).joined(separator: ", ")))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let todayCost = summaries[calendar.startOfDay(for: Date())]
            .map { spendDashboardLedgerCostText($0, currencyCode: group.currencyCode) } ?? "—"
        return OverviewDailySpend(
            points: points,
            todayText: "\(L("Today")) \(todayCost)",
            stacks: stacks,
            legend: legend)
    }
}
