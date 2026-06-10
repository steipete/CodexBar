import AppKit
import CodexBarCore
import SwiftUI

/// 持久面板根视图。阶段 1：provider 切换器 + 当前 provider 用量卡片。
/// 阶段 2：底部动作区（PopoverActionSectionsView）；完整卡片分流渲染（PopoverCardPlan）；
///         账户切换器（PopoverAccountSwitcherView）。
/// 阶段 3：图表二级 popover 下钻入口（PopoverChartKind）。
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
    /// 返回 action 对应的禁用 subtitle（nil = 可用；非 nil = 禁用并显示 subtitle 小字）。
    /// 对齐 NSMenu addActionableSections switchAccount/addCodexAccount disabled 逻辑。
    var actionSubtitle: ((MenuDescriptor.MenuAction) -> String?)?
    /// Buy Credits 动作回调；仅当 plan.showBuyCredits 为 true 时渲染对应按钮。
    let onBuyCredits: () -> Void
    /// provider 图标注入闭包：由 controller 按 switcherShowsIcons 设置返回 NSImage? 或 nil。
    /// nil 表示不显示图标（纯文字降级）。视图不读 settings，由闭包内部决定。
    let switcherIcon: (UsageProvider) -> NSImage?
    /// 返回指定 provider 的下钻图表入口列表（Task 3.1）。
    let makeChartEntries: (UsageProvider) -> [PopoverChartKind]
    /// 返回 Overview 行对应的下钻图表（nil 表示该行无下钻）。
    let makeOverviewChart: (StatusItemController.PopoverOverviewRow) -> PopoverChartKind?
    /// 懒构造图表视图；数据缺失返回 nil。
    let makeChartView: (PopoverChartKind, CGFloat) -> AnyView?

    /// 当前呈现的二级图表；非 nil 时触发 .popover(item:) 弹出侧边浮层。
    @State private var presentedChart: PopoverChartKind?

    private static let menuWidth: CGFloat = 310

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if self.viewModel.providers.count > 1 || self.viewModel.includesOverview {
                self.switcher
                Divider()
            }
            self.content
            Divider()
            PopoverActionSectionsView(
                sections: self.makeSections(),
                onAction: self.onAction,
                actionSubtitle: self.actionSubtitle)
                .padding(.bottom, 6)
        }
        .frame(width: Self.menuWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // 无障碍：整个菜单根容器
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CodexBar menu")
        // 二级图表 popover：锚点用整体 bounds（实现最简单稳定，macOS 侧边弹出效果符合预期）
        .popover(
            item: self.$presentedChart,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .trailing)
        { kind in
            Group {
                if let chart = self.makeChartView(kind, 360) {
                    chart
                } else {
                    Text("No data available")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .frame(minWidth: 320)
        }
        // 切 provider 时关闭子 popover
        .onChange(of: self.viewModel.selection) { _, _ in self.presentedChart = nil }
        // popover 隐藏时关闭子 popover
        .onChange(of: self.viewModel.isVisible) { _, isVisible in
            if !isVisible { self.presentedChart = nil }
        }
    }

    // MARK: - 切换器（Phase 2：Overview tab + provider 图标）

    /// tab 多时（>4，与 NSView 版"均宽不足即换行"语义对齐）切换为自适应网格自动分行；
    /// 少量 tab 保持紧凑单行 HStack。
    private var switcher: some View {
        let tabCount = self.viewModel.providers.count + (self.viewModel.includesOverview ? 1 : 0)
        return Group {
            if tabCount > 4 {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 64), spacing: 4)],
                    alignment: .leading,
                    spacing: 4)
                {
                    self.switcherTabs(fillWidth: true)
                }
            } else {
                HStack(spacing: 4) {
                    self.switcherTabs(fillWidth: false)
                }
            }
        }
        .padding(8)
        // 无障碍：切换器容器
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func switcherTabs(fillWidth: Bool) -> some View {
        if self.viewModel.includesOverview {
            self.overviewTab(fillWidth: fillWidth)
        }
        ForEach(self.viewModel.providers, id: \.self) { provider in
            self.providerTab(provider, fillWidth: fillWidth)
        }
    }

    private func overviewTab(fillWidth: Bool) -> some View {
        let selected = self.viewModel.selection == .overview
        return Button {
            self.viewModel.select(.overview)
        } label: {
            Image(systemName: "square.grid.2x2")
                .font(.caption)
                .fontWeight(selected ? .semibold : .regular)
                .frame(maxWidth: fillWidth ? .infinity : nil)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        // 无障碍
        .accessibilityLabel("Overview")
    }

    private func providerTab(_ provider: UsageProvider, fillWidth: Bool) -> some View {
        let selected = self.isSelected(provider)
        return Button {
            self.viewModel.select(.provider(provider))
        } label: {
            HStack(spacing: 3) {
                if let icon = self.switcherIcon(provider) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(provider.rawValue)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: fillWidth ? .infinity : nil)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        // 无障碍
        .accessibilityLabel(provider.rawValue)
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
    /// Task 3.2：当 makeOverviewChart(row) 非 nil 时，在行尾添加 chevron 按钮触发二级图表 popover。
    /// 布局：HStack { 行主体 Button（切 provider）; chevronButton（呈现子 popover）}
    /// 两个 Button 互不干扰：行主体点击执行 viewModel.select；chevron 点击设置 presentedChart。
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
                    let chart = self.makeOverviewChart(row)
                    OverviewRowView(
                        row: row,
                        chart: chart,
                        menuWidth: Self.menuWidth,
                        overviewChevronWidth: Self.overviewChevronWidth,
                        onSelectProvider: { self.viewModel.select(.provider(row.provider)) },
                        onPresentChart: { self.presentedChart = chart })
                    if row.id != rows.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    /// Overview 行尾 chevron 占位宽（不影响 OverviewMenuCardRowView 布局计算）。
    private static let overviewChevronWidth: CGFloat = 28

    /// 单 provider 视图：账户切换器（有时）+ 卡片内容 + 图表下钻入口（有时）。
    @ViewBuilder private func providerContent(for provider: UsageProvider) -> some View {
        if let switcher = self.makeAccountSwitcher(provider) {
            PopoverAccountSwitcherView(segments: switcher.segments, onSelect: switcher.onSelect)
            Divider()
        }
        self.card(for: provider)
        self.chartEntries(for: provider)
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
                    BuyCreditsRowView(onBuyCredits: self.onBuyCredits)
                }
            }
        }
    }

    /// 单 provider 图表下钻入口行（Task 3.2）。
    /// 出现在卡片区（含 storage/buyCredits）之后、动作区 Divider 之前。
    /// entries 为空时不渲染（EmptyView）。
    @ViewBuilder private func chartEntries(for provider: UsageProvider) -> some View {
        let entries = self.makeChartEntries(provider)
        if !entries.isEmpty {
            Divider()
            ForEach(entries) { kind in
                ChartEntryRowView(kind: kind) {
                    self.presentedChart = kind
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

// MARK: - OverviewRowView（独立视图，持有 isHovered @State）

/// Overview 单行：行主体 Button（切 provider）+ 可选 chevron Button（呈现图表）。
/// 抽出为独立 View 以便持有 @State private var isHovered。
private struct OverviewRowView: View {
    let row: StatusItemController.PopoverOverviewRow
    let chart: PopoverChartKind?
    let menuWidth: CGFloat
    let overviewChevronWidth: CGFloat
    let onSelectProvider: () -> Void
    let onPresentChart: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button {
                self.onSelectProvider()
            } label: {
                OverviewMenuCardRowView(
                    model: self.row.model,
                    storageText: self.row.storageText,
                    width: self.chart != nil
                        ? self.menuWidth - self.overviewChevronWidth
                        : self.menuWidth)
            }
            .buttonStyle(.plain)
            // 无障碍
            .accessibilityLabel("\(self.row.provider.rawValue) overview")
            .accessibilityHint("Show \(self.row.provider.rawValue) details")
            if let chart = self.chart {
                Button {
                    self.onPresentChart()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(self.isHovered ? Color.white.opacity(0.75) : Color.secondary)
                        .frame(width: self.overviewChevronWidth, alignment: .center)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // 无障碍
                .accessibilityLabel(chart.title)
            }
        }
        .background(self.isHovered ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 5)
        .onHover { self.isHovered = $0 }
    }
}

// MARK: - ChartEntryRowView（独立视图，持有 isHovered @State）

/// 图表下钻入口行，持有自己的 hover 状态。
private struct ChartEntryRowView: View {
    let kind: PopoverChartKind
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            self.onTap()
        } label: {
            HStack {
                Text(self.kind.title).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(self.isHovered ? Color.white.opacity(0.75) : Color.secondary)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(self.isHovered ? Color.accentColor : Color.clear)
        .foregroundStyle(self.isHovered ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 5)
        .onHover { self.isHovered = $0 }
        // 无障碍：Button 标题即 label，hint 说明用途
        .accessibilityHint("Show chart")
    }
}

// MARK: - BuyCreditsRowView（独立视图，持有 isHovered @State）

/// Buy Credits 行，持有自己的 hover 状态。
private struct BuyCreditsRowView: View {
    let onBuyCredits: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            self.onBuyCredits()
        } label: {
            Label(L("Buy Credits..."), systemImage: "plus.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 17)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(self.isHovered ? Color.accentColor : Color.clear)
        .foregroundStyle(self.isHovered ? Color.white : Color.primary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 5)
        .onHover { self.isHovered = $0 }
    }
}
