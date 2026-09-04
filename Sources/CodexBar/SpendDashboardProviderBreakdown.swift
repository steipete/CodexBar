import AppKit
import CodexBarCore
import SwiftUI

struct SpendProviderBreakdown: Identifiable, Equatable {
    let provider: UsageProvider
    let displayName: String
    let subscriptions: [SpendDashboardModel.ProviderRow]
    let models: [SpendDashboardModel.ModelRow]
    let totalTokens: Int?
    let totalCost: Double?
    let hasPartialTokens: Bool
    let hasPartialCost: Bool
    let hasPartialModelHistory: Bool
    let modelCount: Int

    var id: String {
        self.provider.rawValue
    }
}

private let spendProviderModelDisplayLimit = 6

private func spendDashboardProviderTokenSum(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    var total = 0
    for value in values {
        let result = total.addingReportingOverflow(value)
        guard !result.overflow else { return nil }
        total = result.partialValue
    }
    return total
}

private func spendDashboardProviderCostSum(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let total = values.reduce(0, +)
    return total.isFinite ? total : nil
}

func spendDashboardProviderBreakdowns(
    _ group: SpendDashboardModel.CurrencyGroup) -> [SpendProviderBreakdown]
{
    let providerIDs = Set(group.providers.map(\.provider)).union(group.models.map(\.provider))
    return providerIDs.map { provider in
        let subscriptions = group.providers.filter { $0.provider == provider }
        let models = group.models.filter { $0.provider == provider }
        let costs = subscriptions.compactMap(\.totalCost)
        let tokens = subscriptions.compactMap(\.totalTokens)
        let totalCost = spendDashboardProviderCostSum(costs)
        let totalTokens = spendDashboardProviderTokenSum(tokens)
        return SpendProviderBreakdown(
            provider: provider,
            displayName: ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName,
            subscriptions: subscriptions,
            models: Array(models.prefix(spendProviderModelDisplayLimit)),
            totalTokens: totalTokens,
            totalCost: totalCost,
            hasPartialTokens: tokens.count < subscriptions.count || (totalTokens == nil && !tokens.isEmpty),
            hasPartialCost: costs.count < subscriptions.count || (totalCost == nil && !costs.isEmpty),
            hasPartialModelHistory: group.incompleteModelProviders.contains(provider),
            modelCount: models.count)
    }
    .sorted { lhs, rhs in
        switch (lhs.totalCost, rhs.totalCost) {
        case let (left?, right?) where left != right: left > right
        case (_?, nil): true
        case (nil, _?): false
        default:
            switch (lhs.totalTokens, rhs.totalTokens) {
            case let (left?, right?) where left != right: left > right
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
        }
    }
}

func spendDashboardBreakdownMetricText(
    cost: Double?,
    tokens: Int?,
    currencyCode: String,
    hasPartialCost: Bool = false,
    hasPartialTokens: Bool = false) -> String
{
    let costText = cost.map {
        let formatted = UsageFormatter.currencyString($0, currencyCode: currencyCode)
        return hasPartialCost ? "~\(formatted)" : formatted
    }
    let tokenText = tokens.map {
        let formatted = "\(UsageFormatter.tokenCountString($0)) \(L("token usage"))"
        return hasPartialTokens ? "~\(formatted)" : formatted
    }
    let components = [costText, tokenText].compactMap(\.self)
    return components.isEmpty ? "—" : components.joined(separator: " · ")
}

struct SpendProviderBreakdownRows: View {
    let group: SpendDashboardModel.CurrencyGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(self.breakdowns.enumerated()), id: \.element.id) { index, breakdown in
                if index > 0 {
                    Divider()
                        .padding(.vertical, 8)
                }
                self.providerGroup(breakdown)
            }
        }
    }

    private var breakdowns: [SpendProviderBreakdown] {
        spendDashboardProviderBreakdowns(self.group)
    }

    private func showsSubscriptionChildren(_ breakdown: SpendProviderBreakdown) -> Bool {
        breakdown.subscriptions.count > 1
            || breakdown.subscriptions.contains {
                $0.displayName != breakdown.displayName || $0.sourceKind != .native
            }
    }

    private func providerGroup(_ breakdown: SpendProviderBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SpendProviderIcon(provider: breakdown.provider, size: 22)
                Text(breakdown.displayName)
                    .font(.headline)
                Spacer()
                Text(spendDashboardBreakdownMetricText(
                    cost: breakdown.totalCost,
                    tokens: breakdown.totalTokens,
                    currencyCode: self.group.currencyCode,
                    hasPartialCost: breakdown.hasPartialCost,
                    hasPartialTokens: breakdown.hasPartialTokens))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(breakdown.totalCost == nil && breakdown.totalTokens == nil ? .secondary : .primary)
                    .monospacedDigit()
            }
            .padding(.vertical, 7)

            if self.showsSubscriptionChildren(breakdown) {
                self.subsectionLabel(L("Accounts"))
                ForEach(Array(breakdown.subscriptions.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        self.childDivider
                    }
                    HStack(spacing: 9) {
                        SpendProviderIcon(provider: row.provider, sourceKind: row.sourceKind, size: 16)
                            .opacity(0.76)
                        Text(row.displayName)
                            .lineLimit(1)
                            .help(row.displayName)
                        Spacer()
                        Text(spendDashboardMetricText(
                            cost: row.totalCost,
                            tokens: row.totalTokens,
                            currencyCode: self.group.currencyCode))
                            .foregroundStyle(row.totalCost == nil && row.totalTokens == nil ? .secondary : .primary)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .padding(.leading, 34)
                    .padding(.vertical, 6)
                }
            }

            if !breakdown.models.isEmpty {
                self.subsectionLabel(L("Models"), showsPartialWarning: breakdown.hasPartialModelHistory)
                ForEach(Array(breakdown.models.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        self.childDivider
                    }
                    HStack(spacing: 9) {
                        SpendProviderIcon(provider: row.provider, size: 16)
                            .opacity(0.76)
                        Text(row.modelName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(row.modelName)
                        Spacer()
                        Text(spendDashboardMetricText(
                            cost: row.totalCost,
                            tokens: row.totalTokens,
                            currencyCode: self.group.currencyCode))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                    .padding(.leading, 34)
                    .padding(.vertical, 6)
                }
                if breakdown.modelCount > breakdown.models.count {
                    let otherModelCount = breakdown.modelCount - breakdown.models.count
                    Text("\(L("Other models")): \(codexBarLocalizedInteger(otherModelCount))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 59)
                        .padding(.top, 5)
                }
            } else if breakdown.hasPartialModelHistory {
                self.modelHistoryState(L("Model breakdown unavailable"))
            } else if self.group.models.isEmpty {
                self.modelHistoryState(L("No model-level history"))
            }
        }
    }

    private func modelHistoryState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            self.subsectionLabel(L("Models"))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 59)
                .padding(.vertical, 6)
        }
    }

    private func subsectionLabel(_ title: String, showsPartialWarning: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
            if showsPartialWarning {
                Label(L("Partial model breakdown"), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 34)
        .padding(.top, 7)
        .padding(.bottom, 2)
    }

    private var childDivider: some View {
        Divider()
            .padding(.leading, 59)
    }
}

struct SpendProviderIcon: View {
    let provider: UsageProvider
    var sourceKind: SpendDashboardModel.SourceKind = .native
    var size: CGFloat = 20

    var body: some View {
        Group {
            if self.sourceKind == .openCodex {
                Image(systemName: "arrow.triangle.branch")
                    .font(.body.weight(.semibold))
            } else if let icon = ProviderBrandIcon.image(for: self.provider) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "circle.dotted")
            }
        }
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}
