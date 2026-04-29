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
    let width: CGFloat
    let onMiniMaxLayoutChange: (() -> Void)?
    let miniMaxVisibleScreenHeight: CGFloat?

    init(
        model: UsageMenuCardView.Model,
        width: CGFloat,
        onMiniMaxLayoutChange: (() -> Void)? = nil,
        miniMaxVisibleScreenHeight: CGFloat? = nil)
    {
        self.model = model
        self.width = width
        self.onMiniMaxLayoutChange = onMiniMaxLayoutChange
        self.miniMaxVisibleScreenHeight = miniMaxVisibleScreenHeight
    }

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
                    width: self.width,
                    onMiniMaxLayoutChange: self.onMiniMaxLayoutChange,
                    miniMaxVisibleScreenHeight: self.miniMaxVisibleScreenHeight)
            }
        }
        .frame(width: self.width, alignment: .leading)
    }

    private var hasUsageBlock: Bool {
        !self.model.metrics.isEmpty || !self.model.usageNotes.isEmpty || self.model.placeholder != nil ||
            (self.model.minimaxSections?.isEmpty == false)
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
    let showAll: Bool
    let showSwitcher: Bool
}

struct CodexAccountMenuDisplay: Equatable {
    let accounts: [CodexVisibleAccount]
    let activeVisibleAccountID: String?
}
