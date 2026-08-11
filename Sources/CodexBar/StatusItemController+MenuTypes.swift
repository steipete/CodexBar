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

struct OverviewTokenAllocation: Equatable {
    struct CostPerMillionTokens: Equatable {
        let amount: Double
        let currencyCode: String
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let provider: UsageProvider
        let displayName: String
        let tokenCount: Int?
        let tokenFraction: Double?
        let costPerMillionTokens: CostPerMillionTokens?
    }

    let knownTotalTokens: Int
    let isPartial: Bool
    let rows: [Row]

    init?(model: SpendDashboardModel, trackedProviders: Set<UsageProvider>) {
        let sourceRows = model.groups.flatMap { group in
            group.providers.map { row in
                (row: row, currencyCode: group.currencyCode)
            }
        }
        var knownTotalTokens = 0
        for source in sourceRows {
            guard let tokens = source.row.totalTokens else { continue }
            guard tokens >= 0 else { return nil }
            let result = knownTotalTokens.addingReportingOverflow(tokens)
            guard !result.overflow else { return nil }
            knownTotalTokens = result.partialValue
        }
        guard knownTotalTokens > 0 else { return nil }

        self.knownTotalTokens = knownTotalTokens
        self.isPartial = Set(sourceRows.map(\.row.provider)) != trackedProviders ||
            sourceRows.contains { $0.row.totalTokens == nil || $0.row.coveredDayCount < model.requestedDays } ||
            model.groups.contains { $0.coveredDayCount < model.requestedDays }
        self.rows = sourceRows.map { source in
            let tokenFraction = source.row.totalTokens.map {
                Double($0) / Double(knownTotalTokens)
            }
            return Row(
                id: source.row.id,
                provider: source.row.provider,
                displayName: source.row.displayName,
                tokenCount: source.row.totalTokens,
                tokenFraction: tokenFraction,
                costPerMillionTokens: Self.costPerMillionTokens(
                    tokens: source.row.totalTokens,
                    cost: source.row.totalCost,
                    currencyCode: source.currencyCode))
        }
    }

    private static func costPerMillionTokens(
        tokens: Int?,
        cost: Double?,
        currencyCode: String) -> CostPerMillionTokens?
    {
        guard let tokens, tokens > 0,
              let cost, cost.isFinite, cost >= 0,
              !currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let amount = (cost / Double(tokens)) * 1_000_000
        guard amount.isFinite, amount >= 0 else { return nil }
        return CostPerMillionTokens(amount: amount, currencyCode: currencyCode)
    }
}

struct OverviewSpendSummary: Equatable {
    let primarySpendText: String
    let coverageText: String
    let tokenText: String?
    let tokenAllocation: OverviewTokenAllocation?
    let isPartial: Bool

    init(model: SpendDashboardModel, trackedProviders: [UsageProvider]) {
        let trackedProviderSet = Set(trackedProviders)
        let connectedCount = trackedProviderSet.count
        let sourceRows = model.groups.flatMap(\.providers)
        let rowsByProvider = Dictionary(grouping: sourceRows, by: \.provider)
        let modeledProviderSet = Set(rowsByProvider.keys)
        let knownCostProviderSet = Set(rowsByProvider.compactMap { provider, rows in
            rows.allSatisfy { $0.totalCost != nil } ? provider : nil
        })
        let knownCostCount = knownCostProviderSet.intersection(trackedProviderSet).count
        let costCoverageIsComplete = modeledProviderSet == trackedProviderSet &&
            knownCostProviderSet == trackedProviderSet &&
            model.groups.allSatisfy { $0.totalCost != nil }
        let knownTokenRows = sourceRows.compactMap(\.totalTokens)
        let knownTokens = Self.safeTokenSum(knownTokenRows)
        let tokenCoverageIsComplete = modeledProviderSet == trackedProviderSet &&
            sourceRows.allSatisfy { $0.totalTokens != nil && $0.coveredDayCount >= model.requestedDays } &&
            model.groups.allSatisfy { $0.totalTokens != nil }
        self.isPartial = !costCoverageIsComplete

        let spendTexts = model.groups.compactMap { group -> String? in
            guard let cost = group.totalCost ?? group.knownCost else { return nil }
            let formatted = UsageFormatter.currencyString(cost, currencyCode: group.currencyCode)
            let groupIsPartial = group.totalCost == nil || !costCoverageIsComplete
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
        self.tokenAllocation = OverviewTokenAllocation(model: model, trackedProviders: trackedProviderSet)
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
    static let baseRowHeight: CGFloat = 94
    static let rowHeight: CGFloat = 146

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

                if let allocation = self.summary.tokenAllocation {
                    OverviewTokenAllocationView(allocation: allocation)
                }
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
        .frame(
            minHeight: self.summary.tokenAllocation == nil ? Self.baseRowHeight : Self.rowHeight,
            alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .padding(.horizontal, 6)
        }
    }
}

private struct OverviewTokenAllocationView: View {
    private static let displayLimit = 3
    private static let segmentSpacing: CGFloat = 1

    let allocation: OverviewTokenAllocation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(L("Tracked tokens"))
                Spacer(minLength: 4)
                Text(
                    (self.allocation.isPartial ? "~" : "") +
                        ShareStatsFormatting.compactCount(self.allocation.knownTotalTokens))
                    .monospacedDigit()
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)

            self.segmentedBar
                .frame(height: 6)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ForEach(Array(self.visibleRows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(self.allocationText(for: row))
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                        Text(self.rateText(for: row))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(self.accessibilityText(for: row))
                }
                if self.hiddenRowCount > 0 {
                    Text("+\(self.hiddenRowCount)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("%d more items", self.hiddenRowCount))
                }
            }
        }
        .animation(
            self.reduceMotion ? nil : .easeOut(duration: 0.2),
            value: self.allocation.rows)
    }

    private var segmentedBar: some View {
        GeometryReader { geometry in
            let rows = self.segmentRows
            let spacing = Self.segmentSpacing * CGFloat(max(0, rows.count - 1))
            let availableWidth = max(0, geometry.size.width - spacing)
            HStack(spacing: Self.segmentSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(UsageMenuCardView.Model.progressColor(for: row.provider))
                        .frame(width: availableWidth * (row.tokenFraction ?? 0))
                }
            }
        }
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(L("Tracked tokens")) · \(L("Usage breakdown"))")
        .accessibilityValue(self.accessibilityAllocationValue)
    }

    private var orderedRows: [OverviewTokenAllocation.Row] {
        self.allocation.rows.sorted { lhs, rhs in
            switch (lhs.tokenCount, rhs.tokenCount) {
            case let (left?, right?) where left != right: left > right
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.id < rhs.id
            }
        }
    }

    private var visibleRows: [OverviewTokenAllocation.Row] {
        Array(self.orderedRows.prefix(Self.displayLimit))
    }

    private var hiddenRowCount: Int {
        max(0, self.allocation.rows.count - self.visibleRows.count)
    }

    private var segmentRows: [OverviewTokenAllocation.Row] {
        self.orderedRows.filter { ($0.tokenFraction ?? 0) > 0 }
    }

    private var accessibilityAllocationValue: String {
        self.allocation.rows.map(self.accessibilityText).joined(separator: ", ")
    }

    private func allocationText(for row: OverviewTokenAllocation.Row) -> String {
        let percent = row.tokenFraction.map { UsageFormatter.percentString($0 * 100) } ?? L("Unknown")
        return "\(row.displayName) \(percent)"
    }

    private func rateText(for row: OverviewTokenAllocation.Row) -> String {
        guard let rate = row.costPerMillionTokens else { return L("unavailable") }
        return OverviewTokenRateFormatting.text(rate)
    }

    private func accessibilityText(for row: OverviewTokenAllocation.Row) -> String {
        "\(self.allocationText(for: row)), \(self.rateText(for: row))"
    }
}

enum OverviewTokenRateFormatting {
    static func text(_ rate: OverviewTokenAllocation.CostPerMillionTokens) -> String {
        let formatted = UsageFormatter.currencyString(rate.amount, currencyCode: rate.currencyCode)
        let zero = UsageFormatter.currencyString(0, currencyCode: rate.currencyCode)
        if rate.amount > 0, formatted == zero {
            let minimum = self.minimumVisibleAmount(currencyCode: rate.currencyCode)
            return "<\(UsageFormatter.currencyString(minimum, currencyCode: rate.currencyCode)) / 1M"
        }
        return "\(rate.amount == 0 ? "" : "~")\(formatted) / 1M"
    }

    private static func minimumVisibleAmount(currencyCode: String) -> Double {
        let zero = UsageFormatter.currencyString(0, currencyCode: currencyCode)
        var candidate = 1.0
        var minimum = candidate
        for _ in 0..<8 {
            guard UsageFormatter.currencyString(candidate, currencyCode: currencyCode) != zero else { break }
            minimum = candidate
            candidate /= 10
        }
        return minimum
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
