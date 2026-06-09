# 菜单架构重构迁移契约（NSMenu → NSPopover + 持久 SwiftUI）

> 目的：把"每次打开/切换都重建 NSMenuItem + 全新 NSHostingView + 同步测高"的菜单，重构为
> "单一长期存活的 SwiftUI 视图树 + `@Observable` 增量更新"，根治交互卡顿。
> 本文是**迁移契约**：列出迁移中必须保留的行为、需替代的 NSMenu 专有能力、新视图蓝图、测试契约与风险。
> 由穷尽式代码盘点工作流产出（2026-06，覆盖 31 个 StatusItemController+*.swift 文件 + 菜单视图 + 现有测试）。

## 0. 已确认的方向决策

| 维度 | 决策 |
|---|---|
| 容器 | **NSPopover(.transient)**，保留 `StatusItemController` + 图标/动画体系不动，仅替换 `statusItem.menu` 赋值为手动弹出 popover |
| 内容承载 | 单一长期存活 SwiftUI 根视图（`NSHostingController`）+ `@Observable` MenuViewModel 驱动 |
| 图表下钻 | **二级级联 popover**，复刻当前 NSMenu 子菜单向侧边弹出的视觉/交互（不是内联展开） |
| 键盘快捷键 | **全保留**：Cmd+R/,/Q、←→ 循环切 provider（含 Overview）、Cmd+1..9 选第 N 个 |
| 测试节奏 | **先双跑过渡**：先在现有 NSMenu 实现上把断言下沉到 view-model 层，新旧架构复用同一批断言 |
| 排除项 | MenuBarExtra（需重构 App 生命周期、放弃自定义动态图标/动画体系，改动过大） |

App 结构：SwiftUI `App` 外壳 + `@NSApplicationDelegateAdaptor(AppDelegate)`，状态项/图标/菜单全部由 AppKit `StatusItemController` 管理；SwiftUI Scene 仅有保活窗口 + Settings。

## 1. 必须保留的行为（MP-01 .. MP-29）

### 状态项与生命周期
- **MP-01/02 双模式状态项**：合并模式单 `NSStatusItem`（autosave `codexbar-merged`）；非合并模式按 provider 多个（`statusItems:[UsageProvider:NSStatusItem]`，autosave `codexbar-<provider>`）。可见性由 enabled/fallback/debugForceAnimation 控制。迁移保留 statusItem 作锚点，移除 `statusItem.menu=`。
- **MP-03 打开初始化序列**（`menuWillOpen`→ `onAppear`/`willShow`）：标记打开、hydrate、populate、装快捷键监听、调度 1.2s 后刷新。
- **MP-04 关闭清理序列**（`menuDidClose`→ `onDisappear`/`willHide`）：移除打开记录、取消刷新任务、清高亮、**关闭后后台预备下次内容**避免下次弹出卡顿。
- **MP-05 登录态变化重建**：`loginTask/activeLoginProvider/loginPhase` 变化 → 失效+重渲；打开期间不中断交互。

### 内容结构
- **MP-10 内容分流**：Overview / 单 provider；单 provider 再按 Codex showAll 堆叠卡片 / Token showAll 堆叠 / Kilo 多 scope 堆叠 / 单卡片分流。
- **MP-11 卡片分段（条件渲染 + 段间分隔符）**：Header（名/邮箱/plan/副标题）→ Usage（主/次/三级窗口 %、reset、pace）→ Storage → Credits（含 Buy Credits…）→ Extra Usage/Provider Cost（Codex 企业花费）→ Cost/Token Usage（会话/月/top model）。
- **MP-17 底部动作区**（`MenuDescriptor.Section`）：账户/登录动作、provider 专属动作、Dashboard、Status Page、Changelog、状态行、Update ready、Refresh/Settings/About/Quit（带快捷键标签）。

### 图表下钻（6 类）
- **MP-12 懒水合 + 重测高**：usageBreakdown/creditsHistory/costHistory/usageHistory/storageBreakdown/zaiHourlyUsage；首开实例化，数据变更刷新；provider 切换关闭所有图表。图表读 store 数据 + 本地 @State 交互（选中天/系列）。
- **MP-13 父内容防抖**：子图表开启时父内容不抖动/闪烁。
- **MP-14 下钻入口**：Overview 行子菜单（OpenAI cost history、Zai 详情、storage）；Usage History（Plan Utilization）与 Zai Hourly 作为独立项。
- StorageBreakdown 高度约束：`min(620, max(360, visibleHeight*0.72))` + 滚动。

### 快捷键/导航/高亮/消失
- **MP-15 持久快捷键** Cmd+R/,/Q：打开期间无需点项即响应。
- **MP-16 provider 导航** Cmd+1..9 选第 N 个 enabled；←→（keyCode 123/124）循环切含 Overview。
- **MP-18 悬停高亮**：仅 enabled 项；`MenuCardHighlightState`（@Observable）注入渲染选中背景/文字色。
- **MP-19 消失语义**：点外部 / Esc / 选中项后关闭（现全靠 NSMenu 模态，迁移须显式实现）。

### 图标/动画（横切，需与面板内容解耦）
- **MP-20 加载动画** DisplayLink 30FPS，最长 30s 或数据到达即停；knightRider/cylon/unbraid 相位。
- **MP-21 闲置 blink/wiggle/tilt** 状态机，作为不可变快照传入 `IconRenderer.makeIcon`。
- **MP-22 图标渲染签名缓存**（命中跳过 makeIcon）+ quota 警告闪烁。**与菜单内容正交**。
- **MP-23 面板可见冻结动画**：`guard !popoverVisible`。

### 外观/无障碍/定位/版本
- **MP-24 vibrancy + 系统色跟随 + 本地化签名**（语言切换重算重布局）；副标题 SwiftUI 化免去 macOS 14.4 版本分支。
- **MP-25 多屏定位**：按钮屏幕坐标换算 + 跨屏最优弹出位 + 响应 screensDidChange/睡眠唤醒；保留 `MenuBarStatusItemPlacementPreflight` 越界清理。
- **MP-26 无障碍树**（**Critical**）：现 NSMenu 免费提供，迁移须手工 `.accessibilityRole(.menu)` + 项 `.isButton` trait + label + hint（含快捷键）+ `.combine`。
- **MP-27 宽度自适应/高度测量**：基础 310pt；SwiftUI 自适应替代 fittingSize 手测。
- **MP-28 readiness 签名 + 版本追踪**：检测数据变更决定增量/全量；迁移改为 `@Observable` Equatable + contentVersion。
- **MP-29 延迟交互刷新**：打开缺数据 → 关闭后 250ms `store.refreshProvider(.background)`；OpenAI dashboard 延迟刷新语义保留。

## 2. 需替代的 NSMenu 专有能力（14 项，摘录高风险）

- `statusItem.menu=` 自动弹出 → 手动 `NSPopover.show(relativeTo:of:preferredEdge:)`（中风险）
- `NSMenuDelegate` 生命周期 → popover delegate / `.onAppear/.onDisappear`（高）
- `StatusItemMenu.performKeyEquivalent` 模态拦截快捷键 → 面板可见期 `NSEvent.addLocalMonitorForEvents(.keyDown)` 或 `.onKeyPress`（**高/Critical**）
- `ProviderSwitcherShortcutEventMonitor`（CFRunLoopObserver .eventTracking）→ popover 非菜单模态，改面板级 monitor / 原生 Button（高），可删 hitTest/handleMenuTracking workaround
- NSMenu 自动消失 → `.transient` + 显式 Esc/选中 dismiss（高）
- `NSMenuItem.view` 逐次新建 NSHostingView → 单一持久 SwiftUI 树 + @Observable（高）
- NSMenu submenu 级联 → 二级级联 popover 复刻（中）
- NSMenu 内置无障碍 → 手工无障碍树（**高/Critical**）
- `NSMenu.allowsVibrancy` / `NSMenuItem.subtitle` → NSVisualEffectView + SwiftUI 文本（中）
- NSStatusBar 自动定位 → popover relativeTo 大体自动，自定义面板需手工（中）
- 大量 `ObjectIdentifier(NSMenu)` 字典 key → 合并模式单面板单版本，删除大部分字典（中）

## 3. 新 SwiftUI 内容视图蓝图

```
PopoverRootView（单一持久，@Observable MenuViewModel；固定宽 ~310pt；NSVisualEffectView vibrancy；
                 .accessibilityRole(.menu)；onAppear=打开序列，onDisappear=关闭序列）
├─ 1. ProviderSwitcher 区（仅 merged && providers>1）：分段控件(Overview + providers)，
│     selection 绑定 selectedMenuProvider + lastSelectedWasOverview（持久化）；←→/Cmd+1..9
├─ Divider
├─ 2. 账户切换器区（二选一，仅 segmented）：Codex 账户 / Token 账户
├─ Divider
├─ 3. 主内容区
│   ├─ Overview 分支：ForEach(overviewProviders) → OverviewMenuCardRowView（可点击切换 + 行内下钻）
│   └─ 单 provider 分支：按账户/scope 分流（Codex/Token showAll 堆叠、Kilo scopes、单卡片）
│       └─ 4. 卡片分段（@ViewBuilder 条件 + Divider）：Header→Usage→Storage→Credits→ExtraUsage→Cost/Token
├─ 5. 图表下钻（6 类，二级级联 popover，懒加载，provider 切换收起）
├─ Divider
└─ 7. 底部动作区：账户/登录→provider 动作→Dashboard→Status→Changelog→状态行→Update→Refresh/Settings/About/Quit

横切：StatusBarIconService(@Observable) 独立于面板（DisplayLink/blink/签名缓存/quota 闪烁；面板可见冻结）
横切：集中式 @State highlightedItemID（.onHover）；面板级事件 monitor（Cmd 系列/←→/Esc/点外部关闭）
```

## 4. 测试契约

### 迁移后必须覆盖
内容结构（读 @Observable model 而非 menu.items）、switcher 切换与持久化、账户切换同步 state+触发刷新、智能更新 vs 全量判定、图表懒加载/刷新/收起/高度约束、打开初始化序列、关闭清理+250ms 延迟刷新、关闭后预备、快捷键全集、图标层独立性（面板可见冻结/签名跳过）、登录态变化、多屏定位、**无障碍（新增）**、本地化重布局、vibrancy/系统色。

### 需重写的现有测试
所有基于 `menu.items[]` 索引/`representedObject`/视图类型断言（`StatusItemControllerMenuTests`、`StatusMenuSwitcherRefreshTests`、`StatusMenuOpenRefreshTests`、`StatusMenuHostedSubmenuRefreshTests` 等 ~50+）→ 改读 view-model；直接驱动 `populateMenu/makeMenu/menuWillOpen` 的同步调用 → 驱动 model 状态 + onAppear/onDisappear。

### 新增可测试接缝
`@Published contentVersion/updateID`（替代 `_test_openMenuRebuildObserver`+menuVersions）；可注入 `isPopoverVisible`；`highlightedItemID` 快照；可注入延迟（1.2s/350ms/250ms 经 environment/init，测试设 .zero）；`@Environment(\.disableMenuRefresh/disableCardRendering)`（替代静态 flag）；DisplayLink onTick mock；图标签名检视保留。

## 5. 风险（按严重度）

| 级别 | 风险 | 缓解 |
|---|---|---|
| **Critical** | 快捷键/事件拦截架构整体失效（依赖 NSMenu 模态 + CFRunLoopObserver） | 面板 willShow 装全局 local monitor / `.onKeyPress`，didClose 移除；先以最小面板验证快捷键链路再迁内容 |
| **Critical** | 无障碍树退化（NSMenu 免费提供，SwiftUI 须手工） | 迁移即同步补全；纳入测试强制覆盖；Accessibility Inspector 验收 |
| High | 面板消失语义易错（动作后忘 dismiss、monitor 冲突） | 优先 `.transient`；frame 边界判定；每动作显式 dismiss；三路径各写测试 |
| High | 性能回归（复用不当/频繁 layout/动画未解耦） | 图标动画迁出独立服务；面板内更新防抖批量；图表懒加载；`.equatable()` 阻无谓重渲；保留签名缓存与 350ms 预备 |
| High | 智能复用/缓存状态机迁移复杂（切 tab 闪烁/内容丢失/Overview 选中重置） | @Observable 响应式 + SwiftUI diff 替代手动缓存；先快照测试锁定判定条件再逐条对拍 |
| High | 测试套件大面积失效 | 先双跑：现有实现上把断言下沉 view-model，新架构复用同一批 |
| Medium | 高度测量/裁剪、多屏定位、双模式隔离、高亮重渲丢失 | SwiftUI 固有尺寸 + maxHeight/ScrollView；按钮坐标换算+screensDidChange；合并/非合并面板管理完全隔离；高亮集中态 + `.id()` |

## 6. 待迁移中决策的次要问题
非合并模式：每 provider 独立面板 vs 共享单面板按点击切换；高亮是否需键盘上下移动（NSMenu 原生）还是仅悬停；动画服务所有权（AppDelegate/单例/StatusItemController）；是否弃用 `NSFont.menuFont` 改系统字体。
