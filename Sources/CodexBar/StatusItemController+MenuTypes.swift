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

struct OverviewMenuCardRowView: View {
    static let showsSectionDividers = false
    static let rowHeight: CGFloat = 88
    static let accessibilityRowHeight: CGFloat = 112

    let model: UsageMenuCardView.Model
    let storageText: String?
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let liveModel = self.liveModel
        let liveSubtitle = Self.liveSubtitle(for: liveModel, refreshMonitor: self.refreshMonitor)
        let metric = Self.primaryMetric(for: liveModel)
        let prioritizesStatus = Self.prioritizesStatus(for: liveSubtitle.style)
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
                Text(Self.spendReference(for: liveModel) ?? liveModel.subtitleText)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if metric != nil || prioritizesStatus {
                    Text(Self.spendReference(for: liveModel) ?? liveModel.subtitleText)
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

    static func primaryMetric(for model: UsageMenuCardView.Model) -> UsageMenuCardView.Model.Metric? {
        model.metrics.first
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
