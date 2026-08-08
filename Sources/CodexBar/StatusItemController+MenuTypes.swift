import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    var selectedMenuProvider: ProviderInstanceID? {
        get { self.settings.selectedMenuProvider }
        set { self.settings.selectedMenuProvider = newValue }
    }

    var fallbackProvider: UsageProvider? {
        // Intentionally uses availability-filtered list: fallback activates when no provider
        // can actually work, ensuring at least a codex icon is always visible.
        self.store.enabledProviders().isEmpty ? .codex : nil
    }
}

extension ProviderSwitcherSelection {
    var provider: UsageProvider? {
        switch self {
        case .overview:
            nil
        case let .provider(instanceID):
            instanceID.firstPartyProvider
        }
    }

    var instanceID: ProviderInstanceID? {
        switch self {
        case .overview: nil
        case let .provider(instanceID): instanceID
        }
    }
}

struct OverviewSpendSummary: Equatable {
    let primarySpendText: String
    let coverageText: String
    let tokenText: String?
    let isPartial: Bool

    init(model: SpendDashboardModel, connectedProviderCount: Int) {
        let connectedCount = max(0, connectedProviderCount)
        let knownCostCount = model.groups.reduce(0) { $0 + $1.knownCostProviderCount }
        let knownTokenRows = model.groups.flatMap(\.providers).compactMap(\.totalTokens)
        let knownTokens = Self.safeTokenSum(knownTokenRows)
        let tokenCoverageIsComplete = knownTokenRows.count == connectedCount &&
            model.groups.allSatisfy { $0.totalTokens != nil }
        self.isPartial = knownCostCount < connectedCount || model.groups.contains { $0.totalCost == nil }

        let spendTexts = model.groups.compactMap { group -> String? in
            guard let cost = group.totalCost ?? group.knownCost else { return nil }
            let formatted = UsageFormatter.currencyString(cost, currencyCode: group.currencyCode)
            let groupIsPartial = group.totalCost == nil || knownCostCount < connectedCount
            return groupIsPartial ? "~\(formatted)" : formatted
        }
        self.primarySpendText = spendTexts.isEmpty ? L("Spend unavailable") : spendTexts.joined(separator: " · ")
        self.coverageText = "\(codexBarLocalizedInteger(knownCostCount)) / " +
            "\(codexBarLocalizedInteger(connectedCount)) \(L("Providers"))"
        self.tokenText = knownTokens.map {
            let formatted = ShareStatsFormatting.compactCount($0)
            let value = tokenCoverageIsComplete ? formatted : "~\(formatted)"
            return L("%@ tokens", value)
        }
    }

    private static func safeTokenSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return values.isEmpty ? nil : total
    }
}

struct OverviewSpendSummaryCardView: View {
    static let rowHeight: CGFloat = 94

    let summary: OverviewSpendSummary
    let days: Int
    let width: CGFloat
    let canShare: Bool
    let share: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
                    Text(self.summary.coverageText)
                    if let tokenText = self.summary.tokenText {
                        Text("·")
                        Text(tokenText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 6)

            Button(action: self.share) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .menuCardInteractiveControl(isEnabled: self.canShare)
            .disabled(!self.canShare)
            .opacity(self.canShare ? 1 : 0.35)
            .accessibilityLabel(L("Share Stats…"))
            .help(L("Share Stats…"))
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 10)
        .frame(width: self.width, alignment: .leading)
        .frame(minHeight: Self.rowHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .padding(.horizontal, 6)
        }
    }
}

struct OverviewMenuCardRowView: View {
    enum Emphasis: Equatable {
        case prominent
        case compact
    }

    static let showsSectionDividers = false
    static let rowHeight: CGFloat = 88
    static let compactRowHeight: CGFloat = 54
    static let accessibilityRowHeight: CGFloat = 112

    let model: UsageMenuCardView.Model
    let storageText: String?
    let width: CGFloat
    var emphasis: Emphasis = .prominent
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let liveModel = self.liveModel
        let liveSubtitle = Self.liveSubtitle(for: liveModel, refreshMonitor: self.refreshMonitor)
        let metric = Self.primaryMetric(for: liveModel)
        let prioritizesStatus = Self.prioritizesStatus(for: liveSubtitle.style)
        Group {
            switch self.emphasis {
            case .prominent:
                self.prominentContent(
                    liveModel: liveModel,
                    liveSubtitle: liveSubtitle,
                    metric: metric,
                    prioritizesStatus: prioritizesStatus)
            case .compact:
                self.compactContent(
                    liveModel: liveModel,
                    liveSubtitle: liveSubtitle,
                    metric: metric,
                    prioritizesStatus: prioritizesStatus)
            }
        }
    }

    private func prominentContent(
        liveModel: UsageMenuCardView.Model,
        liveSubtitle: MenuCardLiveSubtitle,
        metric: UsageMenuCardView.Model.Metric?,
        prioritizesStatus: Bool) -> some View
    {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(liveModel.providerName)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(liveModel.email)
                    .font(.caption)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if prioritizesStatus {
                Text(liveSubtitle.text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(self.subtitleColor(for: liveSubtitle.style))
                    .lineLimit(self.dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let metric {
                let presentation = metric.linePresentation(
                    title: UsageMenuCardView.popupMetricTitle(provider: liveModel.provider, metric: metric))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(metric.statusText ?? presentation.titleText)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let resetText = presentation.resetText, metric.statusText == nil {
                        Text(resetText)
                            .font(.caption2)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }
                }
                if metric.statusText == nil {
                    UsageProgressBar(
                        percent: metric.percent,
                        tint: liveModel.progressColor,
                        accessibilityLabel: metric.percentStyle.accessibilityLabel)
                }
            } else {
                Text(Self.compactSpendText(for: liveModel))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if metric != nil || prioritizesStatus {
                    Text(Self.compactSpendText(for: liveModel))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)
                if let storageText {
                    Text("\(L("Storage")): \(storageText)")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 7)
        .frame(width: self.width, alignment: .leading)
        .frame(minHeight: Self.rowHeight(for: self.dynamicTypeSize), alignment: .leading)
    }

    private func compactContent(
        liveModel: UsageMenuCardView.Model,
        liveSubtitle: MenuCardLiveSubtitle,
        metric: UsageMenuCardView.Model.Metric?,
        prioritizesStatus: Bool) -> some View
    {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(liveModel.providerName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(self.dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if !liveModel.email.isEmpty {
                    Text(liveModel.email)
                        .font(.caption)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(self.dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if prioritizesStatus {
                    Text(liveSubtitle.text)
                        .foregroundStyle(self.subtitleColor(for: liveSubtitle.style))
                } else if let metric {
                    let title = UsageMenuCardView.popupMetricTitle(provider: liveModel.provider, metric: metric)
                    Text(metric.linePresentation(title: title).titleText)
                } else {
                    Text(liveSubtitle.text)
                }
                Spacer(minLength: 8)
                Text(Self.compactSpendText(for: liveModel))
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            }
            .font(.caption)
            .lineLimit(self.dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 6)
        .frame(width: self.width, alignment: .leading)
        .frame(
            minHeight: self.dynamicTypeSize.isAccessibilitySize
                ? Self.accessibilityRowHeight
                : Self.compactRowHeight,
            alignment: .leading)
    }

    static func primaryMetric(for model: UsageMenuCardView.Model) -> UsageMenuCardView.Model.Metric? {
        model.metrics.first
    }

    static func compactSpendText(for model: UsageMenuCardView.Model) -> String {
        self.spendReference(for: model) ?? L("Spend unavailable")
    }

    static func prioritizesStatus(for style: UsageMenuCardView.Model.SubtitleStyle) -> Bool {
        style != .info
    }

    static func rowHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize ? self.accessibilityRowHeight : self.rowHeight
    }

    static func spendReference(for model: UsageMenuCardView.Model) -> String? {
        model.providerCost?.spendLine
            ?? model.tokenUsage?.monthLine
            ?? model.creditsText
            ?? model.placeholder
    }

    static func liveSubtitle(
        for model: UsageMenuCardView.Model,
        refreshMonitor: MenuCardRefreshMonitor?) -> MenuCardLiveSubtitle
    {
        let fallback = MenuCardLiveSubtitle(text: model.subtitleText, style: model.subtitleStyle)
        guard model.usesLiveSubtitle else { return fallback }
        return refreshMonitor?.subtitle(for: model.provider, fallback: fallback) ?? fallback
    }

    private var liveModel: UsageMenuCardView.Model {
        guard self.model.usesLiveSubtitle else { return self.model }
        return self.refreshMonitor?.model(for: self.model.provider, fallback: self.model) ?? self.model
    }

    private func subtitleColor(for style: UsageMenuCardView.Model.SubtitleStyle) -> Color {
        switch style {
        case .error:
            MenuHighlightStyle.error(self.isHighlighted)
        case .info, .loading:
            MenuHighlightStyle.secondary(self.isHighlighted)
        }
    }
}

struct OpenAIWebMenuItems {
    let hasUsageBreakdown: Bool
    let hasCreditsHistory: Bool
    let hasCostHistory: Bool
    let canShowBuyCredits: Bool
}

struct TokenAccountMenuDisplay: Equatable {
    let provider: UsageProvider
    let accounts: [ProviderTokenAccount]
    let snapshots: [TokenAccountUsageSnapshot]
    let activeIndex: Int
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    static func == (lhs: TokenAccountMenuDisplay, rhs: TokenAccountMenuDisplay) -> Bool {
        lhs.provider == rhs.provider &&
            lhs.accountIdentity == rhs.accountIdentity &&
            lhs.activeIndex == rhs.activeIndex &&
            lhs.layout == rhs.layout &&
            lhs.snapshotIdentity == rhs.snapshotIdentity
    }

    private var accountIdentity: [AccountIdentity] {
        self.accounts.map { account in
            AccountIdentity(
                id: account.id,
                label: account.label,
                externalIdentifier: account.externalIdentifier,
                usageScope: account.usageScope,
                organizationID: account.organizationID,
                workspaceID: account.workspaceID)
        }
    }

    private var snapshotIdentity: [SnapshotIdentity] {
        self.snapshots.map { snapshot in
            SnapshotIdentity(
                id: snapshot.id,
                hasSnapshot: snapshot.snapshot != nil,
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
    }

    private struct AccountIdentity: Equatable {
        let id: UUID
        let label: String
        let externalIdentifier: String?
        let usageScope: String?
        let organizationID: String?
        let workspaceID: String?
    }

    private struct SnapshotIdentity: Equatable {
        let id: UUID
        let hasSnapshot: Bool
        let error: String?
        let sourceLabel: String?
    }
}

struct CodexAccountMenuDisplay: Equatable {
    let accounts: [CodexVisibleAccount]
    let snapshots: [CodexAccountUsageSnapshot]
    let activeVisibleAccountID: String?
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    var workspaceSections: [CodexAccountWorkspaceSection] {
        self.accounts.codexWorkspaceSections()
    }

    var showsWorkspaceGroups: Bool {
        Set(self.workspaceSections.map(\.title)).count > 1
    }

    static func == (lhs: CodexAccountMenuDisplay, rhs: CodexAccountMenuDisplay) -> Bool {
        lhs.accounts == rhs.accounts &&
            lhs.activeVisibleAccountID == rhs.activeVisibleAccountID &&
            lhs.layout == rhs.layout &&
            lhs.snapshotIdentity == rhs.snapshotIdentity
    }

    private var snapshotIdentity: [SnapshotIdentity] {
        self.snapshots.map { snapshot in
            SnapshotIdentity(
                id: snapshot.id,
                hasSnapshot: snapshot.snapshot != nil,
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
    }

    private struct SnapshotIdentity: Equatable {
        let id: String
        let hasSnapshot: Bool
        let error: String?
        let sourceLabel: String?
    }
}
