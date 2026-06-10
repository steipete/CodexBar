# 菜单 Popover 重构阶段 2：合并模式内容全量对齐 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 popover（`usePopoverMenu` 开时的合并模式菜单）的内容补全到与 NSMenu 等价：底部动作区、完整卡片分流（Codex/Token 堆叠、Kilo 多 scope、Storage、Buy Credits）、账户切换器、Overview 模式、切换器图标、selection 持久化。

**Architecture:** 延续阶段 1：持久 `PopoverRootView` + `@Observable MenuViewModel`。**数据/决策留在 StatusItemController（复用 `MenuDescriptor.build`、`menuCardModel`、`*AccountMenuDisplay`），以闭包注入；PopoverRootView 只做纯渲染**。动作分发用新的 `performMenuAction(_:)`（switch 调既有 @objc 方法），替代 NSMenuItem selector。

**Tech Stack:** 同阶段 1（SwiftUI/Observation/swift-testing；全程 `usePopoverMenu` 开关隔离）。

**前置事实（已核实，file:line）：**
- `MenuDescriptor`：`Section{entries:[Entry]}`，`Entry = text(String,TextStyle)|action(String,MenuAction)|submenu(String,String?,[SubmenuItem])|divider`；`MenuAction` 16 case（MenuDescriptor.swift:5-52）；`build(provider:store:settings:account:managedCodexAccountCoordinator:codexAccountPromotionCoordinator:updateReady:includeContextualActions:)`（74-134）。
- selector 映射：StatusItemController+MenuActionMapping.swift:4-24（`selector(for:) -> (Selector, Any?)`）。
- 账户 display：`TokenAccountMenuDisplay{provider,accounts,snapshots,activeIndex,layout}`、`CodexAccountMenuDisplay{accounts,snapshots,activeVisibleAccountID,layout}`，`showAll == .stacked`、`showSwitcher == .segmented`（+MenuTypes.swift:67-170）。来源 `tokenAccountMenuDisplay(for:)`/`codexAccountMenuDisplay(for:)`（+AccountMenuDisplay.swift:5-53）。
- NSView 切换器 onSelect：Codex `(CodexVisibleAccount) -> Void`（+SwitcherViews.swift:1262），Token `(Int) -> Task<Void,Never>?`（1121）。
- 卡片分流参考：`addMenuCards`（+Menu.swift:645-709）、`addStackedCodexMenuCards`（+CodexStackedMenu.swift:4-61，含 workspace 分组+health）、Kilo `store.kiloScopeSnapshots`（UsageStore+KiloOrgRefresh.swift:4-17）。
- Storage：`store.storageFootprintText(for:)` 非 nil 时显示 `StorageMenuCardSectionView(storageText:topPadding:bottomPadding:width:)`（SwiftUI，StorageBreakdownMenuView.swift:5-24）。
- Buy Credits：`context.openAIContext.canShowBuyCredits` 时显示，动作 `openCreditsPurchase`（+Menu.swift:1422-1434）。
- Overview：`OverviewMenuCardRowView(model:storageText:width:)`（SwiftUI，+MenuTypes.swift:16-58）；行数据构造见 `addOverviewRows`（+Menu.swift:583-629）；空态文案 632-643；tab 出现条件 `includesOverviewTab`（1146-1150）；持久化 `settings.mergedMenuLastSelectedWasOverview`/`selectedMenuProvider`。
- 切换器图标：`switcherIcon(for:)`（+Menu.swift:1362-1420，NSImage）；Overview 图标 `square.grid.2x2`；`settings.switcherShowsIcons`。

---

## 任务总览（顺序执行，每个 TDD + 全量回归 + 提交）

| # | 任务 | 新文件 |
|---|---|---|
| 2.1 | 动作分发 `performMenuAction` + 底部动作区视图 | `Popover/PopoverActionSectionsView.swift`、`StatusItemController+Popover` 扩展 |
| 2.2 | 卡片计划 `PopoverCardPlan` + 完整卡片分流渲染 | `Popover/PopoverCardPlan.swift` |
| 2.3 | SwiftUI 账户切换器（Codex/Token segmented） | `Popover/PopoverAccountSwitcherView.swift` |
| 2.4 | Overview 模式（行复用 + 点击切换 + 空态） | （改 PopoverRootView/+Popover） |
| 2.5 | 切换器升级：provider 图标 + Overview tab | （改 PopoverRootView） |
| 2.6 | selection 持久化 + 阶段验收（dev build + 人工验证） | （改 MenuViewModel 接线） |

### Task 2.1 动作分发与底部动作区

**Files:** Create `Sources/CodexBar/Popover/PopoverActionSectionsView.swift`；Modify `StatusItemController+Popover.swift`；Test `Tests/CodexBarTests/PopoverActionDispatchTests.swift`

1. `StatusItemController+Popover.swift` 加 `func performMenuAction(_ action: MenuDescriptor.MenuAction)`：复用 `selector(for:)` 的映射语义，但直接 switch 调方法（refresh→`refreshNow()`、settings→`showSettingsGeneral()`、quit→`quit()`、dashboard→`openDashboard()`、statusPage/changelog/installUpdate/copyError/openTerminal/loginToProvider/switchAccount/addProviderAccount/addCodexAccount/requestCodexSystemPromotion 同理——带参 case 用现有 @objc 方法所需的 representedObject 语义改为直接传参调用；若个别 @objc 方法只接受 NSMenuItem sender，则在扩展里新增直调重载或构造临时 NSMenuItem 设 representedObject 后 perform，以现有方法实现为准）。执行后除 quit 外关闭 popover。
2. `PopoverActionSectionsView(sections: [MenuDescriptor.Section], onAction: (MenuDescriptor.MenuAction) -> Void)`：ForEach sections（section 间 Divider）；entry 渲染：`.text`→按 TextStyle 的 disabled Text；`.action`→Button（label + 右对齐快捷键标签 ⌘R/⌘,/⌘Q，复用 shortcut(for:) 的映射写死三条）；`.submenu`→SwiftUI `Menu`（item disabled/checked 状态保留）；`.divider`→Divider。
3. `PopoverRootView` 末尾接入：注入 `makeSections: () -> [MenuDescriptor.Section]`（controller 里 `MenuDescriptor.build(...)` 同 populateMenu 的参数）与 `onAction`。
4. 测试：`performMenuAction` 关键 case 触发对应行为（用可注入回调/状态断言，避免真打开 URL——必要时只测安全 case：refresh/settings/quit 的分发 + popover close 行为）；View 层不做渲染快照测试。

### Task 2.2 卡片计划与完整分流

**Files:** Create `Sources/CodexBar/Popover/PopoverCardPlan.swift`；Modify `StatusItemController+Popover.swift`、`PopoverRootView.swift`；Test `Tests/CodexBarTests/PopoverCardPlanTests.swift`

1. ```swift
   struct PopoverCardPlan {
       struct Card: Identifiable { let id: String; let model: UsageMenuCardView.Model; let workspaceHeader: String? }
       var cards: [Card]
       var storageText: String?
       var showBuyCredits: Bool
       var emptyText: String?
   }
   ```
2. `StatusItemController+Popover.swift` 加 `func popoverCardPlan(for provider: UsageProvider) -> PopoverCardPlan`：复刻 `addMenuCards` 分流（+Menu.swift:645-709 与 +CodexStackedMenu.swift）：Codex showAll→按 workspaceSections 展开（header 进 `workspaceHeader`），Token showAll→snapshots compactMap，Kilo 多 scope→kiloScopeSnapshots compactMap，否则单 `menuCardModel(for:)`；storageText=`store.storageFootprintText(for:)`；showBuyCredits 按 openAIWebContext 的 canShowBuyCredits（复用 populateMenu 中 openAIContext 构造，简化为单 provider 场景）。
3. `PopoverRootView.card(for:)` 改为消费 plan：ForEach cards（含可选 workspace header 灰字、卡片间 Divider）→ Storage 段（StorageMenuCardSectionView）→ Buy Credits Button（plus.circle 图标，onAction(.buyCredits) 或直调注入闭包）。注入签名改 `makeCardPlan: (UsageProvider) -> PopoverCardPlan`。
4. 测试：构造假 display/snapshot 数据不易（依赖 store），改为**对 plan 结构本身**与"单卡片回退/空态"路径做窄测试；堆叠路径以现有 NSMenu 测试（同一 menuCardModel 数据源）背书 + Task 2.6 人工验证。

### Task 2.3 SwiftUI 账户切换器

**Files:** Create `Sources/CodexBar/Popover/PopoverAccountSwitcherView.swift`；Modify `PopoverRootView.swift`、`StatusItemController+Popover.swift`；Test `Tests/CodexBarTests/PopoverAccountSwitcherTests.swift`

1. 通用 segmented 视图：
   ```swift
   struct PopoverAccountSwitcherView: View {
       struct Segment: Identifiable, Equatable { let id: String; let title: String; let isSelected: Bool }
       let segments: [Segment]
       let onSelect: (String) -> Void   // segment id
   }
   ```
   视觉对齐 Phase 1 provider 切换器（选中 accent 背景，>3 个自动换行用 LazyVGrid 或 wrap HStack）。
2. controller 提供 `popoverAccountSwitcherSegments(for provider:) -> (segments: [Segment], onSelect: (String) -> Void)?`：Codex 用 `codexAccountMenuDisplay(for:)`（showSwitcher 时，id=account.id，选中= activeVisibleAccountID，onSelect 调用现有 Codex 选择处理——参考 addCodexAccountSwitcherIfNeeded 注入的闭包实现）；Token 用 `tokenAccountMenuDisplay(for:)`（id=index 字符串，onSelect 调现有 token 选择逻辑，注意其返回 `Task<Void,Never>?` 直接丢弃句柄）。
3. PopoverRootView 在切换器 Divider 与内容区之间条件渲染。
4. 测试：Segment 构造纯函数（给定 display→segments 选中态正确）+ onSelect 回调触发。

### Task 2.4 Overview 模式

**Files:** Modify `PopoverRootView.swift`、`StatusItemController+Popover.swift`；Test `Tests/CodexBarTests/PopoverOverviewTests.swift`

1. controller 加 `popoverOverviewRows() -> [PopoverOverviewRow]`，`struct PopoverOverviewRow: Identifiable { let provider: UsageProvider; let model: UsageMenuCardView.Model; let storageText: String? }`——复刻 addOverviewRows 的数据构造（resolvedMergedOverviewProviders + menuCardModel + storageFootprintText）。
2. PopoverRootView `.overview` 分支：rows 为空→`Text(L("No providers selected for Overview."))` 风格空态（文案与 NSMenu 一致，+Menu.swift:632-643）；否则 ForEach → `OverviewMenuCardRowView(model:storageText:width:)`（直接复用 SwiftUI 视图）包 Button/onTapGesture → `viewModel.select(.provider(row.provider))`，行间 Divider。
3. 测试：rows 构造的空态/非空逻辑；点击行后 `viewModel.selection` 切换。

### Task 2.5 切换器升级（图标 + Overview tab）

**Files:** Modify `PopoverRootView.swift`、`StatusItemController+Popover.swift`；Test 复用 MenuViewModelTests

1. `MenuViewModel` 加 `var includesOverview: Bool = false`（attach/click 时由 controller 用 `includesOverviewTab` 等价逻辑刷新；navigationStops 改为 includesOverview ? [.overview]+providers : providers）。
2. 切换器渲染：includesOverview 时首位加 Overview tab（`Image(systemName: "square.grid.2x2")`）；provider tab 按 `settings.switcherShowsIcons` 显示图标（注入 `switcherIcon: (UsageProvider) -> NSImage?`，用 `Image(nsImage:)`）+ 文字；选中态样式不变。
3. 测试：navigationStops 含/不含 overview 的循环导航。

### Task 2.6 selection 持久化 + 阶段验收

**Files:** Modify `StatusItemController+Popover.swift`（wire）、`Popover/MenuViewModel.swift`（onSelectionChanged 回调）；Test 更新 MenuViewModelTests

1. `MenuViewModel` 加 `var onSelectionChanged: ((ProviderSwitcherSelection) -> Void)?`，`select(_:)` 末尾调用。controller wiring：`.overview`→`settings.mergedMenuLastSelectedWasOverview = true`；`.provider(p)`→`settings.selectedMenuProvider = p`（写法对齐现有 onSelect，见 +Menu.swift:1033-1055）+ `mergedMenuLastSelectedWasOverview = false`。
2. 打开 popover（handleStatusItemClick/openMenuFromShortcut）时恢复：用 `resolvedSwitcherSelection(enabledProviders:includesOverview:)` 等价逻辑设置 `viewModel.selection` 初值。
3. 验收：`swift build`、全量 `swift test`、`Scripts/lint.sh lint` 全过；`CODEXBAR_SKIP_WIDGET=1 bash Scripts/compile_and_run.sh` 重建 dev build → 人工验证（完整动作区/账户切换/堆叠/Overview/持久化）+ 复跑 `/tmp/cb_verify_popover.sh` 确认重建帧仍为 0。

---

## 自检
- 覆盖迁移契约 MP-10/11(卡片分流/分段——分段在 UsageMenuCardView 内已有)/14 部分(Overview 行)/17(动作区)/28 部分(持久化)；图表下钻(MP-12/13)留阶段 3，明确不在本计划。
- 所有"复刻/对齐现有逻辑"处均给出了精确参考 file:line；动作分发的带参 case 标注了两种实现策略由实现者按真实方法签名选择。
- 类型一致：`PopoverCardPlan.Card`、`PopoverOverviewRow`、`PopoverAccountSwitcherView.Segment`、`performMenuAction(_:)`、`makeCardPlan`/`makeSections`/`onAction` 注入命名全计划统一。
