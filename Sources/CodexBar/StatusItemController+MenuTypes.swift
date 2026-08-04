import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
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
        case let .provider(provider):
            provider
        }
    }
}

enum OverviewMenuRowStyle: Equatable {
    case detailed
    case compact
    case providerBars
    case barsOnly

    init(layout: MergedOverviewLayout) {
        self = switch layout {
        case .detailed: .detailed
        case .compact: .compact
        case .providerBars: .providerBars
        case .barsOnly: .barsOnly
        }
    }

    var usesReducedContent: Bool {
        self != .detailed
    }
}

enum OverviewMenuRowInteractionPolicy {
    static func containsInteractiveControls(
        style: OverviewMenuRowStyle,
        model: UsageMenuCardView.Model) -> Bool
    {
        style == .detailed && (model.subtitleStyle == .error || model.usesLiveSubtitle)
    }
}

enum CompactOverviewProjectionResolver {
    static func resolve(
        fallbackModel: UsageMenuCardView.Model,
        layoutModel: UsageMenuCardView.Model?,
        liveModel: () -> UsageMenuCardView.Model) -> CompactOverviewProjection
    {
        if let layoutModel, layoutModel.provider != fallbackModel.provider {
            return CompactOverviewProjection(model: fallbackModel)
        }
        let resolvedLayoutModel = layoutModel ?? fallbackModel
        let layoutProjection = CompactOverviewProjection(model: resolvedLayoutModel)
        guard fallbackModel.usesLiveSubtitle else { return layoutProjection }

        let resolvedLiveModel = liveModel()
        let liveProjection = CompactOverviewProjection(model: resolvedLiveModel)
        guard resolvedLiveModel.provider == fallbackModel.provider,
              liveProjection.providerName == layoutProjection.providerName,
              liveProjection.layoutSignature == layoutProjection.layoutSignature
        else {
            return layoutProjection
        }
        return liveProjection
    }
}

struct OverviewMenuCardRowView: View {
    static let showsHeaderDivider = true
    static let showsSectionDividers = false

    let model: UsageMenuCardView.Model
    let layoutModel: UsageMenuCardView.Model?
    let storageText: String?
    let width: CGFloat
    let style: OverviewMenuRowStyle
    let compactLayout: CompactOverviewLayout?
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor

    init(
        model: UsageMenuCardView.Model,
        layoutModel: UsageMenuCardView.Model? = nil,
        storageText: String?,
        width: CGFloat,
        style: OverviewMenuRowStyle = .detailed,
        compactLayout: CompactOverviewLayout? = nil)
    {
        self.model = model
        self.layoutModel = layoutModel
        self.storageText = storageText
        self.width = width
        self.style = style
        self.compactLayout = compactLayout
    }

    var body: some View {
        switch self.style {
        case .detailed:
            self.detailedContent
        case .compact:
            if let compactLayout = self.compactLayout {
                let projection = self.compactProjection
                CompactOverviewLabeledContent(
                    projection: projection,
                    layout: compactLayout)
                    .preference(
                        key: MenuCardAccessibilityLabelPreferenceKey.self,
                        value: projection.accessibilityLabel)
            }
        case .providerBars:
            if let compactLayout = self.compactLayout {
                let projection = self.compactProjection
                CompactOverviewProviderBarsContent(
                    projection: projection,
                    layout: compactLayout)
                    .preference(
                        key: MenuCardAccessibilityLabelPreferenceKey.self,
                        value: projection.accessibilityLabel)
            }
        case .barsOnly:
            if let compactLayout = self.compactLayout {
                let projection = self.compactProjection
                CompactOverviewBarsOnlyContent(
                    projection: projection,
                    layout: compactLayout)
                    .preference(
                        key: MenuCardAccessibilityLabelPreferenceKey.self,
                        value: projection.accessibilityLabel)
            }
        }
    }

    private var detailedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageMenuCardHeaderSectionView(
                model: self.model,
                showDivider: Self.showsHeaderDivider && self.hasUsageBlock,
                width: self.width)
            if self.hasUsageBlock {
                UsageMenuCardUsageSectionView(
                    model: self.model,
                    showBottomDivider: false,
                    bottomPadding: 6,
                    width: self.width,
                    showsSectionDividers: Self.showsSectionDividers)
            }
            if let storageText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(L("Storage")):")
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    Text(storageText)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                .padding(.top, self.hasUsageBlock ? 0 : 8)
                .padding(.bottom, 6)
                .frame(width: self.width, alignment: .leading)
            }
        }
        .frame(width: self.width, alignment: .leading)
    }

    private var compactProjection: CompactOverviewProjection {
        CompactOverviewProjectionResolver.resolve(
            fallbackModel: self.model,
            layoutModel: self.layoutModel)
        {
            self.refreshMonitor?.model(for: self.model.provider, fallback: self.model) ?? self.model
        }
    }

    private var hasUsageBlock: Bool {
        self.model.hasUsageContent
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
