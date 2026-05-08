import AppKit
import CodexBarCore
import SwiftUI

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

struct OverviewMenuCardRowView: View {
    let model: UsageMenuCardView.Model
    let storageText: String?
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageMenuCardHeaderSectionView(
                model: self.model,
                showDivider: self.hasUsageBlock,
                width: self.width)
            if self.hasUsageBlock {
                UsageMenuCardUsageSectionView(
                    model: self.model,
                    showBottomDivider: false,
                    bottomPadding: 6,
                    width: self.width)
            }
            if let storageText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Storage:")
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    Text(storageText)
                        .font(.footnote)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, self.hasUsageBlock ? 0 : 8)
                .padding(.bottom, 6)
                .frame(width: self.width, alignment: .leading)
            }
        }
        .frame(width: self.width, alignment: .leading)
    }

    private var hasUsageBlock: Bool {
        !self.model.metrics.isEmpty || !self.model.usageNotes.isEmpty || self.model.placeholder != nil
    }
}

struct OpenAIWebMenuItems {
    let hasUsageBreakdown: Bool
    let hasCreditsHistory: Bool
    let hasCostHistory: Bool
    let canShowBuyCredits: Bool
}

struct TokenAccountMenuDisplay {
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
