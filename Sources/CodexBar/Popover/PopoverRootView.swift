import CodexBarCore
import SwiftUI

/// 持久面板根视图。阶段 1：provider 切换器 + 当前 provider 用量卡片。
/// 阶段 2：底部动作区（PopoverActionSectionsView）；完整卡片分流渲染（PopoverCardPlan）；
///         账户切换器（PopoverAccountSwitcherView）。
/// 整个 popover 生命周期只构造一次；切 provider 通过 viewModel.select(_:) 增量更新，不重建视图。
struct PopoverRootView: View {
    /// 账户切换器绑定：segments 数据 + onSelect 回调。由 makeAccountSwitcher 构造闭包返回。
    struct AccountSwitcherBinding {
        let segments: [PopoverAccountSwitcherView.Segment]
        let onSelect: (String) -> Void
    }

    @Bindable var viewModel: MenuViewModel
    /// 注入 UsageStore 引用，用于在 body 中建立 @Observable 观察链：
    /// store 数据变化时 SwiftUI 自动重渲而无需外部 bump。
    let store: UsageStore
    /// 由 StatusItemController 注入的卡片计划构造闭包（self.popoverCardPlan(for:)）。
    /// 持有 weak self 引用，避免强引用环。
    let makeCardPlan: (UsageProvider) -> PopoverCardPlan
    /// 账户切换器构造闭包：由 StatusItemController 注入，返回非 nil 时显示切换器。
    /// 仅在单 provider 视图（非 overview）且 display.showSwitcher 时有值。
    let makeAccountSwitcher: (UsageProvider) -> AccountSwitcherBinding?
    /// 返回底部动作区所需的 sections（与 NSMenu 路径共用 MenuDescriptor.build 数据源）。
    /// 在 body 中调用以建立 @Observable 观察链，store/settings 变化时自动重算。
    let makeSections: () -> [MenuDescriptor.Section]
    /// Overview 行数据构造闭包（Task 2.4）：与 NSMenu addOverviewRows 同源。
    let makeOverviewRows: () -> [StatusItemController.PopoverOverviewRow]
    /// Overview 空态文案：nil 表示有内容行；否则返回本地化文案。
    let overviewEmptyText: () -> String?
    /// 动作分发回调，由 StatusItemController.performMenuAction(_:) 实现。
    let onAction: (MenuDescriptor.MenuAction) -> Void
    /// Buy Credits 动作回调；仅当 plan.showBuyCredits 为 true 时渲染对应按钮。
    let onBuyCredits: () -> Void

    private static let menuWidth: CGFloat = 310

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if self.viewModel.providers.count > 1 {
                self.switcher
                Divider()
            }
            self.content
            Divider()
            PopoverActionSectionsView(
                sections: self.makeSections(),
                onAction: self.onAction)
                .padding(.bottom, 6)
        }
        .frame(width: Self.menuWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 最小 SwiftUI 切换器（Phase 1：纯文字按钮；图标/配额指示留 Phase 2）

    private var switcher: some View {
        HStack(spacing: 4) {
            ForEach(self.viewModel.providers, id: \.self) { provider in
                Button {
                    self.viewModel.select(.provider(provider))
                } label: {
                    Text(provider.rawValue)
                        .font(.caption)
                        .fontWeight(self.isSelected(provider) ? .semibold : .regular)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(self.isSelected(provider) ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(8)
    }

    // MARK: - 内容区

    @ViewBuilder private var content: some View {
        switch self.viewModel.selection {
        case .overview:
            self.overviewContent
        case let .provider(p):
            self.providerContent(for: p)
        }
    }

    /// Overview 内容区（Task 2.4）：多 provider 概览行，与 NSMenu addOverviewRows 等价。
    @ViewBuilder private var overviewContent: some View {
        let rows = self.makeOverviewRows()
        if rows.isEmpty {
            let emptyText = self.overviewEmptyText() ?? L("No overview data available.")
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    Button {
                        self.viewModel.select(.provider(row.provider))
                    } label: {
                        OverviewMenuCardRowView(
                            model: row.model,
                            storageText: row.storageText,
                            width: Self.menuWidth)
                    }
                    .buttonStyle(.plain)
                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    /// 单 provider 视图：账户切换器（有时）+ 卡片内容。
    @ViewBuilder private func providerContent(for provider: UsageProvider) -> some View {
        if let switcher = self.makeAccountSwitcher(provider) {
            PopoverAccountSwitcherView(segments: switcher.segments, onSelect: switcher.onSelect)
            Divider()
        }
        self.card(for: provider)
    }

    /// makeCardPlan 内部读取 store 属性，在 body 同步求值以建立 @Observable 观察链；
    /// store 数据变化时 SwiftUI 自动重渲而无需外部 bump。
    @ViewBuilder private func card(for provider: UsageProvider) -> some View {
        let plan = self.makeCardPlan(provider)
        if plan.cards.isEmpty {
            Text(plan.emptyText ?? "Loading…")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(plan.cards) { card in
                    if let header = card.workspaceHeader {
                        Text(header)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                    }
                    UsageMenuCardView(model: card.model, width: Self.menuWidth)
                    if card.id != plan.cards.last?.id {
                        Divider()
                    }
                }
                if let storageText = plan.storageText {
                    Divider()
                    StorageMenuCardSectionView(
                        storageText: storageText,
                        topPadding: 6,
                        bottomPadding: 6,
                        width: Self.menuWidth)
                }
                if plan.showBuyCredits {
                    Divider()
                    Button {
                        self.onBuyCredits()
                    } label: {
                        Label(L("Buy Credits..."), systemImage: "plus.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    // MARK: - 辅助

    private func isSelected(_ provider: UsageProvider) -> Bool {
        if case let .provider(p) = viewModel.selection { return p == provider }
        return false
    }
}
