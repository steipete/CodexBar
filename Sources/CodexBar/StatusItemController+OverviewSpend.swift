import CodexBarCore
import Foundation
import SwiftUI

struct OverviewSpendSummary: Equatable {
    let primarySpendText: String
    let providerCoverageText: String
    let tokenText: String?
    let historyCoverageText: String
    let pricingCoverageText: String
    let provenanceText: String
    let isPartial: Bool

    init(model: SpendDashboardModel, providerCount: Int) {
        let includedProviders = model.groups.flatMap(\.providers)
        let providerCount = max(max(0, providerCount), includedProviders.count)
        let pricedProviderCount = includedProviders.count { $0.totalCost != nil }
        let tokenProviderCount = includedProviders.count { $0.totalTokens != nil }
        let isPartial = pricedProviderCount > 0 && pricedProviderCount < providerCount
        self.isPartial = isPartial

        self.primarySpendText = model.groups.isEmpty
            ? L("Spend unavailable")
            : model.groups.map { group in
                let text = spendDashboardGroupCostText(group)
                guard isPartial, group.totalCost != nil, !text.hasPrefix("~") else { return text }
                return "~\(text)"
            }.joined(separator: " · ")
        self.providerCoverageText = L(
            "%d of %d subscriptions have spend",
            pricedProviderCount,
            providerCount)

        let tokens = Self.safeTokenSum(model.groups.compactMap(\.totalTokens))
        self.tokenText = tokens.map {
            let value = ShareStatsFormatting.compactCount($0)
            let isPartial = tokenProviderCount < providerCount
            return L("%@ tokens", isPartial ? "~\(value)" : value)
        }

        let coveredDays = includedProviders.count < providerCount
            ? 0
            : model.groups.map(\.coveredDayCount).min() ?? 0
        self.historyCoverageText = spendDashboardCoverageText(
            covered: coveredDays,
            requested: model.requestedDays)

        let coverage = model.groups.reduce(into: CostUsageCoverageCounts()) { result, group in
            result.merge(group.coverage)
        }
        self.pricingCoverageText = spendDashboardCoverageChipText(coverage)
        self.provenanceText = model.groups
            .map(\.provenance)
            .reduce(into: [CostProvenance]()) { values, provenance in
                guard !values.contains(provenance) else { return }
                values.append(provenance)
            }
            .map(spendDashboardProvenanceText)
            .joined(separator: " · ")
    }

    private static func safeTokenSum(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        var total = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }
}

struct OverviewSpendSummaryCardView: View {
    let summary: OverviewSpendSummary
    let days: Int
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(L("Usage & Spend"))
                    .font(.headline.weight(.semibold))
                Text("·")
                Text(spendDashboardDayRangeText(self.days))
            }
            .foregroundStyle(.secondary)

            Text(self.summary.primarySpendText)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(self.summary.providerCoverageText)
                if let tokenText = self.summary.tokenText {
                    Text("·")
                    Text(tokenText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Text("\(self.summary.historyCoverageText) · \(self.summary.provenanceText)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(self.summary.pricingCoverageText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 10)
        .frame(width: self.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .padding(.horizontal, 6)
        }
    }
}

extension StatusItemController {
    func overviewSpendDashboardModel(
        providers: [UsageProvider],
        now: Date = Date()) -> SpendDashboardModel
    {
        let inputs = providers.compactMap { provider -> SpendDashboardModel.ProviderInput? in
            guard let snapshot = self.store.tokenSnapshotForCurrentProviderConfig(for: provider)?.snapshot else {
                return nil
            }
            return SpendDashboardModel.ProviderInput(
                provider: provider,
                displayName: self.store.metadata(for: provider).displayName,
                snapshot: snapshot)
        }
        return SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: self.settings.costUsageHistoryDays,
            now: now,
            calendar: self.settings.costUsageBucketCalendar,
            preferredCurrencyCode: self.settings.preferredCurrencyCode)
    }
}
