import AppKit
import CodexBarCore
import SwiftUI

// MARK: - ProviderSwitcherTabView（独立 view，持有 isHovered @State）

/// 单个切换器 tab——垂直布局（图标在上、标题在下），与 NSView 版 StackedToggleButton 外观对齐。
/// - 选中态：实心 accentColor 圆角胶囊 + 白色图标/文字（NSView 版 controlAccentColor 背景）
/// - 未选中态：透明底 + secondary 文字
/// - 底部用量条：高 3pt 圆角小条，背景灰 track + provider 品牌色 fill（仅未选中时显示）
private struct ProviderSwitcherTabView: View {
    let icon: NSImage?
    let title: String
    /// 用量指示条数据：(fraction 0-1, color)；nil 表示无数据不显示条。
    let indicator: (fraction: Double, color: NSColor)?
    let selected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    // 对齐 NSView 版常量
    private static let indicatorHeight: CGFloat = 3
    private static let indicatorBottomInset: CGFloat = 2
    private static let indicatorHorizontalInset: CGFloat = 8

    var body: some View {
        Button(action: self.onTap) {
            VStack(spacing: 3) {
                // 图标（约 18pt），与 NSView StackedToggleButton 图标区域对齐
                Group {
                    if let nsImage = self.icon {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "square.fill")
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: 18, height: 18)
                // 标题（.caption2 大小，lineLimit 1 + 截断）
                Text(self.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // 用量指示条（仅在未选中时可见，选中时隐藏，与 NSView 版行为一致）
                if let indicator = self.indicator {
                    self.indicatorBar(fraction: indicator.fraction, color: indicator.color)
                        .opacity(self.selected ? 0 : 1)
                } else {
                    // 无数据时保留等高占位，避免 tab 高度抖动
                    Color.clear
                        .frame(height: Self.indicatorHeight + Self.indicatorBottomInset)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(self.selected ? Color.accentColor : (self.isHovered ? self.hoverColor : Color.clear))
        .foregroundStyle(self.selected ? Color.white : Color.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .focusEffectDisabled()
        .onHover { self.isHovered = $0 }
        // 无障碍
        .accessibilityLabel(self.title)
        .accessibilityAddTraits(self.selected ? [.isSelected] : [])
    }

    private func indicatorBar(fraction: Double, color: NSColor) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // 灰色 track
                RoundedRectangle(cornerRadius: Self.indicatorHeight / 2)
                    .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.22))
                    .frame(height: Self.indicatorHeight)
                // 品牌色 fill
                if fraction > 0 {
                    RoundedRectangle(cornerRadius: Self.indicatorHeight / 2)
                        .fill(Color(nsColor: color))
                        .frame(
                            width: max(0, (geo.size.width - Self.indicatorHorizontalInset * 2) * CGFloat(fraction)),
                            height: Self.indicatorHeight)
                        .offset(x: Self.indicatorHorizontalInset)
                }
            }
        }
        .frame(height: Self.indicatorHeight + Self.indicatorBottomInset)
        .padding(.horizontal, Self.indicatorHorizontalInset)
    }

    private var hoverColor: Color {
        // 对齐 NSView 版 hoverPlateColor（不区分深浅模式，让 Color 自适应）
        Color.primary.opacity(0.07)
    }
}

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
    /// 用量指示条数据：返回 (fraction 0-1, color)；nil 表示该 provider 无数据不显示条。
    /// 由 StatusItemController 注入，调用 switcherWeeklyRemaining + branding.color 计算。
    let switcherIndicator: (UsageProvider) -> (fraction: Double, color: NSColor)?
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

    // MARK: - 切换器（垂直布局，对齐 NSView ProviderSwitcherView stackedIcons 模式）

    /// 固定 3 列网格布局，与 NSView 版 stackedIcons 行为对齐。
    /// tab ≤ 3 时 HStack 等分；> 3 时 3 列网格自动换行。
    private var switcher: some View {
        let tabCount = self.viewModel.providers.count + (self.viewModel.includesOverview ? 1 : 0)
        return Group {
            if tabCount > 3 {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3),
                    alignment: .leading,
                    spacing: 4)
                {
                    self.switcherTabs
                }
            } else {
                HStack(spacing: 4) {
                    self.switcherTabs
                }
            }
        }
        .padding(8)
        // 无障碍：切换器容器
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var switcherTabs: some View {
        if self.viewModel.includesOverview {
            self.overviewTab
        }
        ForEach(self.viewModel.providers, id: \.self) { provider in
            self.providerTab(provider)
        }
    }

    private var overviewTab: some View {
        let selected = self.viewModel.selection == .overview
        return ProviderSwitcherTabView(
            icon: Self.overviewNSImage,
            title: L("Overview"),
            indicator: nil,
            selected: selected,
            onTap: { self.viewModel.select(.overview) })
    }

    private func providerTab(_ provider: UsageProvider) -> some View {
        let selected = self.isSelected(provider)
        let title = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        let icon = self.switcherIcon(provider)
        let indicator = self.switcherIndicator(provider)
        return ProviderSwitcherTabView(
            icon: icon,
            title: title,
            indicator: indicator,
            selected: selected,
            onTap: { self.viewModel.select(.provider(provider)) })
    }

    /// Overview tab 图标（对齐 NSView 版 overviewIcon()）。
    private static let overviewNSImage: NSImage? = {
        let img = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }()

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
        if let sectioned = plan.sectioned {
            // 拆段模式（对齐 NSMenu addMenuCardSections）
            self.sectionedCard(sectioned)
        } else if plan.cards.isEmpty {
            Text(plan.emptyText ?? "Loading…")
                .foregroundStyle(.secondary)
                .padding()
        } else {
            // 整卡模式（stacked / 无 webItems provider）
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

    /// 拆段渲染（对齐 NSMenu addMenuCardSections 顺序与 Divider 规律）。
    @ViewBuilder private func sectionedCard(_ s: PopoverCardPlan.SectionedCard) -> some View {
        let bottomPadding = CGFloat(s.hasCredits ? 4 : 6)
        let sectionSpacing = CGFloat(6)
        let width = Self.menuWidth

        VStack(alignment: .leading, spacing: 0) {
            // ── 1. Header + Usage 段 ──
            if s.hasUsageBlock {
                ChartSectionContainer(
                    chart: s.usageChart,
                    onPresentChart: { self.presentedChart = $0 },
                    content: {
                        UsageMenuCardHeaderAndUsageSectionView(
                            model: s.model,
                            bottomPadding: bottomPadding,
                            width: width)
                    })
            } else {
                // 无 usage 内容：仅 Header（无 chevron）
                UsageMenuCardHeaderSectionView(
                    model: s.model,
                    showDivider: false,
                    width: width)
            }

            // ── Divider 规律（对齐 1283-1291）──
            if s.hasStorage || s.hasCredits || s.hasExtraUsage || s.hasCost {
                Divider()
            }

            // ── 2. Storage 段 ──
            if let storageText = s.storageText {
                ChartSectionContainer(
                    chart: s.storageChart,
                    onPresentChart: { self.presentedChart = $0 },
                    content: {
                        StorageMenuCardSectionView(
                            storageText: storageText,
                            topPadding: 6,
                            bottomPadding: 6,
                            width: width)
                    })
                // storage 后若还有 credits/extraUsage/cost，加 Divider（对齐 1287-1291）
                if s.hasCredits || s.hasExtraUsage || s.hasCost {
                    Divider()
                }
            }

            // ── 3. Credits 段 ──
            if s.hasCredits {
                // credits 在 storage 之后；storage 已在上方加了 Divider，
                // 此处无需重复。
                ChartSectionContainer(
                    chart: s.creditsChart,
                    onPresentChart: { self.presentedChart = $0 },
                    content: {
                        UsageMenuCardCreditsSectionView(
                            model: s.model,
                            showBottomDivider: false,
                            topPadding: sectionSpacing,
                            bottomPadding: bottomPadding,
                            width: width)
                    })
                if s.showBuyCredits {
                    BuyCreditsRowView(onBuyCredits: self.onBuyCredits)
                }
                // credits → extraUsage / cost 间的 separator（对齐 1316: if hasCredits）
                if s.hasExtraUsage || s.hasCost {
                    Divider()
                }
            }

            // ── 4. Extra Usage 段 ──
            if s.hasExtraUsage {
                ChartSectionContainer(
                    chart: s.extraUsageChart,
                    onPresentChart: { self.presentedChart = $0 },
                    content: {
                        UsageMenuCardExtraUsageSectionView(
                            model: s.model,
                            topPadding: sectionSpacing,
                            bottomPadding: bottomPadding,
                            width: width)
                    })
                // extraUsage → cost 间的 separator（对齐 1334: if hasCredits || hasExtraUsage）
                if s.hasCost {
                    Divider()
                }
            }

            // ── 5. Cost 紧凑行 ──
            if s.hasCost {
                ChartSectionContainer(
                    chart: s.costChart,
                    onPresentChart: { self.presentedChart = $0 },
                    content: { PopoverCostCompactRow(model: s.model) })
            }
        }
    }

    /// 单 provider 图表下钻入口行（Task 3.2）。
    /// 拆段模式下只显示 usageHistory 与 zaiHourly（原版仅有的两个独立行）；
    /// 整卡模式下同样只显示这两个入口（对齐原版整卡 provider 没有别的入口的语义）。
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
            .focusEffectDisabled()
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
                .focusEffectDisabled()
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
        .focusEffectDisabled()
        // 无障碍：Button 标题即 label，hint 说明用途
        .accessibilityHint("Show chart")
    }
}

// MARK: - ChartSectionContainer（段容器：可选 chevron + hover 高亮 + 点击呈现图表）

/// 可复用段容器：wrap 任意段内容，chart 非 nil 时显示行尾 chevron + hover 高亮 + 点击触发图表 popover。
/// chart 为 nil 时纯展示，无任何交互修饰。
private struct ChartSectionContainer<Content: View>: View {
    let chart: PopoverChartKind?
    let onPresentChart: (PopoverChartKind) -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        if let chart {
            Button {
                self.onPresentChart(chart)
            } label: {
                ZStack(alignment: .topTrailing) {
                    self.content()
                        // 与 NSMenu 同机制：hover 时注入 menuItemHighlighted，
                        // 段视图（MenuCardView 各 SectionView）自动切换高亮配色（文字变白等）。
                            .environment(\.menuItemHighlighted, self.isHovered)
                    // 行尾 chevron（topTrailing，对齐 NSMenu MenuCardSectionContainerView 指示器）
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(self.isHovered ? Color.white.opacity(0.75) : Color.secondary)
                        .padding(.top, 8)
                        .padding(.trailing, 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(self.isHovered ? Color.accentColor : Color.clear)
            .foregroundStyle(self.isHovered ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 5)
            .onHover { self.isHovered = $0 }
            .focusEffectDisabled()
            .accessibilityLabel(chart.title)
            .accessibilityHint("Show chart")
        } else {
            self.content()
        }
    }
}

// MARK: - PopoverCostCompactRow（Cost 紧凑行，对齐 NSMenuItem title+subtitle 观感）

/// Cost 紧凑行：标题 "Cost" + subtitle 详情行（对齐 NSMenu makeCostMenuCardItem）。
private struct PopoverCostCompactRow: View {
    let model: UsageMenuCardView.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(StatusItemController.costMenuTitle)
                .font(.callout)
            let lines = StatusItemController.costMenuVisibleDetailLines(tokenUsage: self.model.tokenUsage)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .focusEffectDisabled()
    }
}
