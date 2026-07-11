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
    let entries: [TokenAccountMenuEntry]
    let snapshots: [TokenAccountUsageSnapshot]
    let activeIndex: Int
    let showAll: Bool
    let showSwitcher: Bool

    static func openCode(accounts: OpenCodeWorkspaceAccounts) -> Self {
        let entries = accounts.accounts.map { account in
            TokenAccountMenuEntry(
                id: account.id,
                title: account.ownerLabel.map { "\(account.label) · \($0)" } ?? account.label,
                tokenAccountID: account.tokenAccountID)
        }
        return Self(
            provider: .opencode,
            accounts: [],
            entries: entries,
            snapshots: [],
            activeIndex: accounts.activeID.flatMap { activeID in entries.firstIndex { $0.id == activeID } } ?? 0,
            showAll: false,
            showSwitcher: entries.count > 1)
    }

    private init(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount],
        entries: [TokenAccountMenuEntry],
        snapshots: [TokenAccountUsageSnapshot],
        activeIndex: Int,
        showAll: Bool,
        showSwitcher: Bool)
    {
        self.provider = provider
        self.accounts = accounts
        self.entries = entries
        self.snapshots = snapshots
        self.activeIndex = activeIndex
        self.showAll = showAll
        self.showSwitcher = showSwitcher
    }

    init(
        provider: UsageProvider,
        accounts: [ProviderTokenAccount],
        snapshots: [TokenAccountUsageSnapshot],
        activeIndex: Int,
        showAll: Bool,
        showSwitcher: Bool)
    {
        self.provider = provider
        self.accounts = accounts
        self.entries = accounts.map {
            TokenAccountMenuEntry(id: $0.id.uuidString, title: $0.displayName, tokenAccountID: $0.id)
        }
        self.snapshots = snapshots
        self.activeIndex = activeIndex
        self.showAll = showAll
        self.showSwitcher = showSwitcher
    }
}

struct TokenAccountMenuEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let tokenAccountID: UUID?
}

struct CodexAccountMenuDisplay: Equatable {
    let accounts: [CodexVisibleAccount]
    let activeVisibleAccountID: String?
}
