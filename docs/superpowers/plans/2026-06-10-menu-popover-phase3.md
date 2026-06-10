# 菜单 Popover 重构阶段 3：图表二级级联 popover 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development。

**Goal:** popover 菜单补全 6 类图表下钻（usage breakdown / credits history / cost history / plan utilization(usage history) / storage breakdown / Zai hourly），以**二级 popover 从入口侧边级联弹出**复刻 NSMenu 子菜单观感；懒加载、provider 切换自动收起。

**Architecture:** 6 类图表视图全是纯 SwiftUI（直接复用）。controller 提供"图表入口清单 + 视图工厂"（数据/条件判定复用 NSMenu 同源逻辑）；PopoverRootView 用 `@State presentedChart: PopoverChartKind?` + `.popover(item:arrowEdge:.trailing)` 侧弹。入口呈现为"下钻行"（标题 + chevron，对齐 NSMenu 独立行样式）；与 NSMenu"hover 段级联"的差异（点击行弹出）在最终界面对比时确认。

**前置事实（已核实）：**
- 视图构造：`UsageBreakdownChartMenuView(breakdown:width:)`（数据 `store.openAIDashboard?.usageBreakdown`）；`CreditsHistoryChartMenuView(breakdown:width:)`（`store.openAIDashboard?.dailyBreakdown`）；`CostHistoryChartMenuView(provider:daily:totalCostUSD:currencyCode:historyDays:windowLabel:width:)`（`tokenSnapshotForCostHistorySubmenu(provider)`，构造参数取法见 +HostedSubmenus.swift:234-252）；`PlanUtilizationHistoryChartMenuView(provider:histories:snapshot:width:)`（`store.planUtilizationHistory(for:)` + `store.snapshot(for:)`）；`StorageBreakdownMenuView(footprint:width:maxHeight:)`（`store.storageFootprint(for:)`，maxHeight=`min(620,max(360,floor(visibleHeight*0.72)))` 见 +HostedSubmenus.swift:304-307）；`ZaiHourlyUsageChartMenuView(modelUsage:width:)`（`snapshot.zaiUsage?.modelUsage`）。
- 入口条件：usage 卡片 submenu 判定 `makeUsageSubmenu`（+Menu.swift:1471-1487）：hasUsageBreakdown→breakdown；openai→API usage(=costHistory)；zai→Zai details（非图表，阶段 3 暂记待办）；credits=`hasCreditsHistory`、cost=`hasCostHistory`（openAIWebContext，+Menu.swift:528-548）；usage history=`store.supportsPlanUtilizationHistory(for:) && !store.shouldHidePlanUtilizationMenuItem(for:)`（+UsageHistoryMenu.swift:36-46）；storage=`store.storageFootprint(for:)?.components` 非空（+Menu.swift:1577-1586）；zai hourly=`.zai && modelUsage != nil`（+ZaiHourlyChartMenu.swift:8-14）。
- Overview 行 submenu 判定（+OverviewSubmenus.swift:5-29）：openai→costHistory；zai→details；tokenUsage!=nil→costHistory；plan utilization 可用→usageHistory；否则 storage。
- NSMenu 独立行：Usage History "Subscription Utilization"、Zai "Hourly Usage"（+Menu.swift:791-804）。

## Task 3.1 图表种类 + controller 工厂

**Files:** Create `Sources/CodexBar/Popover/PopoverChartKind.swift`；Modify `StatusItemController+Popover.swift`；Test `Tests/CodexBarTests/PopoverChartTests.swift`

```swift
enum PopoverChartKind: Identifiable, Equatable {
    case usageBreakdown
    case creditsHistory
    case costHistory(UsageProvider)
    case usageHistory(UsageProvider)
    case storageBreakdown(UsageProvider)
    case zaiHourly(UsageProvider)
    var id: String { ... }   // 稳定字符串
    var title: String { ... } // 入口行标题（与 NSMenu 对应 submenu 项标题一致，本地化）
}
```
controller：
- `popoverChartEntries(for provider:) -> [PopoverChartKind]`：按上面入口条件返回该 provider 卡片下方应显示的下钻入口（usage breakdown / credits / cost / usage history / storage / zai hourly，顺序对齐 NSMenu）。
- `popoverOverviewChart(for provider:, model:) -> PopoverChartKind?`：Overview 行的下钻（按 +OverviewSubmenus.swift 判定，Zai details 暂返回 nil）。
- `popoverChartView(for kind:, width:) -> AnyView?`：懒构造对应 SwiftUI 图表（数据取法与 +HostedSubmenus.swift 各 append* 完全一致；数据缺失返回 nil）。
- 测试：PopoverChartKind id/title 稳定；条件判定可单测部分（依赖重则全量回归+人工兜底）。

## Task 3.2 UI 接入 + 切换收起

**Files:** Modify `Popover/PopoverRootView.swift`、`Popover/PopoverCardPlan.swift`（可选扩展）；Test 更新

- PopoverRootView：`@State private var presentedChart: PopoverChartKind?`；注入 `makeChartEntries: (UsageProvider) -> [PopoverChartKind]`、`makeOverviewChart: (PopoverOverviewRow) -> PopoverChartKind?`、`makeChartView: (PopoverChartKind, CGFloat) -> AnyView?`。
- 单 provider 内容：卡片之后渲染入口行（每个 entry 一行：`Button { presentedChart = kind } label: { HStack { Text(kind.title); Spacer(); Image(systemName: "chevron.right") } }`，样式对齐动作区行）。
- Overview 行：行尾 chevron（有 chart 时），点击 `presentedChart = chart`（不触发 provider 切换；行主体点击仍切 provider）。
- 弹出：在入口行容器上 `.popover(item: $presentedChart, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) { kind in (makeChartView(kind, 360) ?? AnyView(Text("No data").padding())) }`——宽度与 NSMenu 渲染宽度对齐（≥310）。StorageBreakdown 已内置 maxHeight 滚动。
- 收起：`.onChange(of: viewModel.selection) { presentedChart = nil }`；popover 关闭（isVisible false）时也置 nil。
- 测试：presentedChart 状态流转用 MenuViewModel/纯逻辑测试覆盖能测的部分；视觉靠人工。

## Task 3.3 验收
build/test/lint 全过 → `CODEXBAR_SKIP_WIDGET=1 bash Scripts/compile_and_run.sh` → 人工验证 6 类图表弹出/数据/收起 → 采样复查仍无重建帧。

**已知待办（不在本阶段）：** Zai MCP details 子菜单（非图表）；I2 action disabled 态。
