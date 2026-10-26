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
    let incompleteRequestCount: Int
    let hasPartialTokens: Bool
    let hasPartialCost: Bool
    let hasPartialModelHistory: Bool
    let modelCount: Int

    var id: String {
        self.provider.rawValue
    }

    var costIsLowerBound: Bool {
        self.subscriptions.contains(where: \.costIsLowerBound)
    }

    var tokensAreLowerBound: Bool {
        self.subscriptions.contains(where: \.tokensAreLowerBound)
    }
}

private let spendProviderModelDisplayLimit = 6

func spendDashboardProviderBreakdowns(
    _ group: SpendDashboardModel.CurrencyGroup) -> [SpendProviderBreakdown]
{
    let providerIDs = Set(group.providers.map(\.provider)).union(group.models.map(\.provider))
    return providerIDs.map { provider in
        let subscriptions = group.providers.filter { $0.provider == provider }
        let models = group.models.filter { $0.provider == provider }
        let costs = subscriptions.compactMap(\.totalCost)
        let tokens = subscriptions.compactMap(\.totalTokens)
        let totalCost = SpendDashboardModel.safeCostSum(costs)
        let totalTokens = tokens.isEmpty ? nil : CheckedSum.integers(tokens)
        let incompleteRequestCount = CostUsageIncompleteRequests.sum(subscriptions.map(\.incompleteRequestCount))
        return SpendProviderBreakdown(
            provider: provider,
            displayName: ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName,
            subscriptions: subscriptions,
            models: models,
            totalTokens: totalTokens,
            totalCost: totalCost,
            incompleteRequestCount: incompleteRequestCount,
            hasPartialTokens: incompleteRequestCount > 0 || tokens.count < subscriptions.count ||
                (totalTokens == nil && !tokens.isEmpty) || subscriptions.contains(where: \.tokensAreLowerBound),
            hasPartialCost: incompleteRequestCount > 0 || costs.count < subscriptions.count ||
                (totalCost == nil && !costs.isEmpty) || subscriptions.contains(where: \.costIsLowerBound),
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
    hasPartialTokens: Bool = false,
    incompleteRequestCount: Int = 0,
    costIsLowerBound: Bool = false,
    tokensAreLowerBound: Bool = false) -> String
{
    let costText = cost.map {
        let formatted = UsageFormatter.currencyString($0, currencyCode: currencyCode)
        if costIsLowerBound { return spendDashboardLowerBoundText(formatted, isLowerBound: true) }
        return hasPartialCost ? "~\(formatted)" : formatted
    }
    let tokenText = tokens.map {
        let formatted = L("%@ tokens", UsageFormatter.tokenCountString($0))
        if tokensAreLowerBound { return spendDashboardLowerBoundText(formatted, isLowerBound: true) }
        return hasPartialTokens ? "~\(formatted)" : formatted
    }
    let components = [costText, tokenText].compactMap(\.self)
    return (components.isEmpty ? "—" : components.joined(separator: " · "))
        + UsageFormatter.incompleteUsageSuffix(incompleteRequestCount)
}

struct SpendProviderBreakdownRows: View {
    let group: SpendDashboardModel.CurrencyGroup
    @State private var expandedProviders: Set<UsageProvider> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(self.breakdowns.enumerated()), id: \.element.id) { index, breakdown in
                if index > 0 {
                    Divider()
                        .padding(.vertical, 6)
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
                SpendProviderIcon(provider: breakdown.provider)
                Text(breakdown.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .help(breakdown.displayName)
                Spacer()
                Text(spendDashboardBreakdownMetricText(
                    cost: breakdown.totalCost,
                    tokens: breakdown.totalTokens,
                    currencyCode: self.group.currencyCode,
                    hasPartialCost: breakdown.hasPartialCost,
                    hasPartialTokens: breakdown.hasPartialTokens,
                    incompleteRequestCount: breakdown.incompleteRequestCount,
                    costIsLowerBound: breakdown.costIsLowerBound,
                    tokensAreLowerBound: breakdown.tokensAreLowerBound))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(breakdown.totalCost == nil && breakdown.totalTokens == nil ? .secondary : .primary)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 5)

            if self.showsSubscriptionChildren(breakdown) {
                self.subsectionLabel(breakdown.subscriptions.contains { $0.sourceKind != .native }
                    ? L("Sources") : L("Accounts"))
                ForEach(Array(breakdown.subscriptions.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        self.childDivider
                    }
                    HStack(spacing: 9) {
                        SpendProviderIcon(
                            provider: row.provider,
                            sourceKind: row.sourceKind,
                            style: .monochrome)
                            .opacity(0.76)
                        Text(row.displayName)
                            .lineLimit(1)
                            .help(row.displayName)
                        Spacer()
                        Text(spendDashboardMetricText(
                            cost: row.totalCost,
                            tokens: row.totalTokens,
                            currencyCode: self.group.currencyCode,
                            incompleteRequestCount: row.incompleteRequestCount,
                            costIsLowerBound: row.costIsLowerBound,
                            tokensAreLowerBound: row.tokensAreLowerBound))
                            .foregroundStyle(row.totalCost == nil && row.totalTokens == nil ? .secondary : .primary)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.subheadline)
                    .padding(.leading, 32)
                    .padding(.vertical, 4)
                }
            }

            if !breakdown.models.isEmpty {
                if breakdown.models.count > 1 || self.showsSubscriptionChildren(breakdown)
                    || breakdown.hasPartialModelHistory
                {
                    self.subsectionLabel(L("Models"), showsPartialWarning: breakdown.hasPartialModelHistory)
                }
                let models = self.expandedProviders.contains(breakdown.provider)
                    ? breakdown.models : Array(breakdown.models.prefix(spendProviderModelDisplayLimit))
                ForEach(Array(models.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        self.childDivider
                    }
                    HStack(spacing: 9) {
                        SpendProviderIcon(provider: row.provider, style: .monochrome)
                            .opacity(0.76)
                        Text(row.modelName)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.modelName)
                            .accessibilityLabel(L("Models") + ": " + row.modelName)
                        Spacer()
                        Text(spendDashboardMetricText(
                            cost: row.totalCost,
                            tokens: row.totalTokens,
                            currencyCode: self.group.currencyCode,
                            incompleteRequestCount: row.incompleteRequestCount))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .font(.subheadline)
                    .padding(.leading, 32)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
                if breakdown.modelCount > spendProviderModelDisplayLimit {
                    let isExpanded = self.expandedProviders.contains(breakdown.provider)
                    Button {
                        if isExpanded {
                            self.expandedProviders.remove(breakdown.provider)
                        } else {
                            self.expandedProviders.insert(breakdown.provider)
                        }
                    } label: {
                        Text(isExpanded ? L("Show less") : L("Show all (%d)", breakdown.modelCount))
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 61)
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
                .padding(.leading, 61)
                .padding(.vertical, 4)
        }
    }

    private func subsectionLabel(_ title: String, showsPartialWarning: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.medium))
            if showsPartialWarning {
                Label(L("Partial model breakdown"), systemImage: "exclamationmark.triangle")
                    .font(.caption2)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 32)
        .padding(.top, 5)
        .padding(.bottom, 2)
    }

    private var childDivider: some View {
        Divider()
            .padding(.leading, 61)
    }
}

struct SpendProviderIcon: View {
    let provider: UsageProvider
    var sourceKind: SpendDashboardModel.SourceKind = .native
    var style: ProviderBrandIcon.Style = .brand
    var size: CGFloat = 20

    var body: some View {
        Group {
            if self.sourceKind == .openCodex {
                Image(systemName: "arrow.triangle.branch")
                    .resizable().scaledToFit()
            } else if let icon = ProviderBrandIcon.image(for: self.provider, style: self.style) {
                Image(nsImage: icon)
                    .resizable()
                    .renderingMode(icon.isTemplate ? .template : .original)
                    .scaledToFit()
                    .frame(
                        width: self.size * self.artworkScale(for: icon),
                        height: self.size * self.artworkScale(for: icon))
            } else {
                Image(systemName: "circle.dotted")
                    .resizable().scaledToFit()
            }
        }
        .foregroundStyle(.primary)
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }

    private func artworkScale(for icon: NSImage) -> CGFloat {
        // Provider-specific by design: normalize each bundled mark's transparent padding in the shared icon slot.
        switch self.provider {
        case .cursor: 1.25
        case .codex: icon.isTemplate ? 1.24 : 1.17
        case .antigravity: icon.isTemplate ? 1.14 : 1.38
        case .bedrock: icon.isTemplate ? 1 : 0.84
        case .muse, .vertexai: icon.isTemplate ? 1 : 1.08
        default: 1
        }
    }
}
