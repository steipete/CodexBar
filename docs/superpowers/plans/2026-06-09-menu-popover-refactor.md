# 菜单 NSMenu → NSPopover + 持久 SwiftUI 重构 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把"每次打开/切换都重建 NSMenuItem + 全新 NSHostingView + 同步测高"的菜单，重构为"单一长期存活的 SwiftUI 视图树 + `@Observable` 增量更新"的 NSPopover，根治打开菜单/切 provider 的卡顿。

**Architecture:** 保留 AppKit `StatusItemController` 与图标/动画体系不动；用 `NSPopover(.transient)` + `NSHostingController` 承载一棵长期存活的 SwiftUI 根视图，由 `@Observable MenuViewModel` 驱动；切 provider = 改 view model 属性 → SwiftUI 增量 diff，不再拆建 NSMenuItem。全程**特性开关 `usePopoverMenu` 隔离**（默认关），逐阶段交付、每阶段可测可回退。

**Tech Stack:** Swift 6 / SwiftPM、AppKit（NSStatusItem/NSPopover/NSHostingController）、SwiftUI、Observation（@Observable）、swift-testing（`@Test`/`#expect`）、macOS 14+。

**配套文档:** 迁移契约见 `docs/refactor/menu-popover-migration-contract.md`（29 条必保留行为 MP-01..29、14 项需替代能力、新视图蓝图、测试契约、风险）。

**构建/测试命令:** `swift build` / `swift test`；本地跑 `Scripts/compile_and_run.sh`；lint `Scripts/lint.sh lint`。采样验证卡顿：用户侧 `bash /tmp/cb_profile.sh`（见 `[[menu-perf-investigation-method]]`）。

---

## 阶段路线图（每阶段独立可交付、特性开关隔离）

| 阶段 | 目标 | 交付物 | 本计划详度 |
|---|---|---|---|
| **0** | 地基：特性开关 + view-model 抽象 + 测试双跑接缝 | 开关关时**零行为变化** | ✅ 完整 TDD 步骤 |
| **1** | popover 骨架 + 架构验证 | 开关开时：点击弹出 popover，渲染切换器+单卡片，切换走增量更新；**采样确认卡顿消失** | ✅ 详细步骤 |
| 2 | 内容全量对齐（合并模式） | 全部卡片分段、Overview、各 provider 分流 | 🔜 独立计划 |
| 3 | 图表二级级联 popover（复刻现子菜单观感） | 6 类图表懒加载、provider 切换收起 | 🔜 独立计划 |
| 4 | 非合并模式（per-provider popover） | `providerPanels` 映射 | 🔜 独立计划 |
| 5 | 动画/图标解耦 + 清理 | 面板可见冻结动画、删除旧 NSMenu 路径 | 🔜 独立计划 |
| 6 | 无障碍 + 完整测试 + 翻转默认开关 | a11y 树、全测试契约覆盖、性能复测、默认开 | 🔜 独立计划 |

> 阶段 2–6 在前一阶段落地后各自展开为 `docs/superpowers/plans/` 下的独立计划（依赖前阶段产出的真实类型，提前写死只会是占位符）。本计划完整覆盖**阶段 0 与阶段 1**。

---

## 文件结构（阶段 0 + 1 新增/修改）

**新增：**
- `Sources/CodexBar/Popover/PopoverMenuController.swift` — NSPopover 生命周期 + 锚定 statusItem.button + 显示/隐藏/dismiss + 键盘事件 monitor
- `Sources/CodexBar/Popover/MenuViewModel.swift` — `@Observable`，持有 selectedProvider/providers/contentVersion/isVisible 等面板状态（替代 NSMenu 字典追踪）
- `Sources/CodexBar/Popover/PopoverRootView.swift` — SwiftUI 持久根视图（阶段 1 仅切换器 + 单卡片）
- `Tests/CodexBarTests/PopoverMenuFeatureFlagTests.swift`
- `Tests/CodexBarTests/MenuViewModelTests.swift`
- `Tests/CodexBarTests/PopoverMenuControllerTests.swift`

**修改：**
- `Sources/CodexBar/SettingsStoreState.swift` — 加 `usePopoverMenu` 字段
- `Sources/CodexBar/SettingsStore.swift` — `loadDefaultsState` 加载该字段
- `Sources/CodexBar/SettingsStore+Defaults.swift` — 暴露 `usePopoverMenu` 计算属性
- `Sources/CodexBar/StatusItemController.swift` — 持有 `PopoverMenuController?`；按开关在 attach 路径分流
- `Sources/CodexBar/StatusItemController+Actions.swift` — `openMenuFromShortcut`/点击触发分流到 popover

---

## 阶段 0：地基（特性开关 + view model + 测试接缝）

> 不变量：`usePopoverMenu == false` 时，App 行为与当前**逐字节一致**（所有新代码处于未激活分支）。

### Task 0.1：新增特性开关 `usePopoverMenu`（默认 false）

**Files:**
- Modify: `Sources/CodexBar/SettingsStoreState.swift`（加字段，照 `usageBarsShowUsed` 范例）
- Modify: `Sources/CodexBar/SettingsStore.swift:~345`（`loadDefaultsState` 内加载）
- Modify: `Sources/CodexBar/SettingsStore+Defaults.swift:~196`（计算属性 get/set）
- Test: `Tests/CodexBarTests/PopoverMenuFeatureFlagTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
import Foundation
@testable import CodexBar

@Suite struct PopoverMenuFeatureFlagTests {
    private func makeSettings() -> SettingsStore {
        let defaults = UserDefaults(suiteName: "test.popover.\(UUID().uuidString)")!
        return SettingsStore(userDefaults: defaults)
    }

    @Test func usePopoverMenuDefaultsToFalse() {
        let settings = makeSettings()
        #expect(settings.usePopoverMenu == false)
    }

    @Test func usePopoverMenuPersists() {
        let suite = "test.popover.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(userDefaults: defaults)
        settings.usePopoverMenu = true
        #expect(settings.usePopoverMenu == true)
        #expect(defaults.bool(forKey: "usePopoverMenu") == true)
        // 重新加载验证持久化
        let reloaded = SettingsStore(userDefaults: defaults)
        #expect(reloaded.usePopoverMenu == true)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter PopoverMenuFeatureFlagTests`
Expected: FAIL（`usePopoverMenu` 未定义，编译错误）

- [ ] **Step 3: 按 `usageBarsShowUsed` 范例实现开关**

精确照抄三处范例（不要发明新模式）：
1. `SettingsStoreState.swift`：在 `SettingsDefaultsState` 加 `var usePopoverMenu: Bool`（参考其中 `usageBarsShowUsed` 字段位置），并在其 init/默认值处补 `usePopoverMenu: false`。
2. `SettingsStore.swift` 的 `loadDefaultsState`（约 345 行，`usageBarsShowUsed` 加载旁）：
   ```swift
   let usePopoverMenu = userDefaults.object(forKey: "usePopoverMenu") as? Bool ?? false
   ```
   并在构造 `SettingsDefaultsState(...)` 处传入 `usePopoverMenu: usePopoverMenu`。
3. `SettingsStore+Defaults.swift`（约 196 行，照 `usageBarsShowUsed`）：
   ```swift
   var usePopoverMenu: Bool {
       get { self.defaultsState.usePopoverMenu }
       set {
           self.defaultsState.usePopoverMenu = newValue
           self.userDefaults.set(newValue, forKey: "usePopoverMenu")
       }
   }
   ```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter PopoverMenuFeatureFlagTests`
Expected: PASS（2 测试）

- [ ] **Step 5: 提交**

```bash
git add Sources/CodexBar/SettingsStoreState.swift Sources/CodexBar/SettingsStore.swift Sources/CodexBar/SettingsStore+Defaults.swift Tests/CodexBarTests/PopoverMenuFeatureFlagTests.swift
git commit -m "feat(menu): add usePopoverMenu feature flag (default off)"
```

### Task 0.2：新增 `MenuViewModel`（@Observable 面板状态）

**Files:**
- Create: `Sources/CodexBar/Popover/MenuViewModel.swift`
- Test: `Tests/CodexBarTests/MenuViewModelTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import CodexBar

@MainActor @Suite struct MenuViewModelTests {
    @Test func defaultsToFirstProviderNotVisible() {
        let vm = MenuViewModel()
        #expect(vm.isVisible == false)
        #expect(vm.selection == .overview || vm.providers.isEmpty)
    }

    @Test func selectingProviderBumpsContentVersionWithoutRebuildFlag() {
        let vm = MenuViewModel()
        vm.providers = [.codex, .claude]
        let v0 = vm.contentVersion
        vm.select(.provider(.claude))
        #expect(vm.selection == .provider(.claude))
        #expect(vm.contentVersion == v0 + 1)
    }

    @Test func markVisibleTogglesState() {
        let vm = MenuViewModel()
        vm.setVisible(true)
        #expect(vm.isVisible == true)
        vm.setVisible(false)
        #expect(vm.isVisible == false)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter MenuViewModelTests`
Expected: FAIL（`MenuViewModel` 未定义）

- [ ] **Step 3: 实现 MenuViewModel**

```swift
import Observation
import CodexBarCore

/// 面板内容的单一可观察状态源。替代旧架构中以 ObjectIdentifier(NSMenu) 为 key 的
/// openMenus/menuVersions/highlightedMenuItems 等字典追踪（迁移契约 MP-28、MP-18、MP-19）。
@MainActor
@Observable
final class MenuViewModel {
    /// 切换器选择：Overview 或具体 provider。复用既有 ProviderSwitcherSelection 语义。
    var selection: ProviderSwitcherSelection = .overview
    /// 当前可显示的 provider 列表（合并模式切换器用）。
    var providers: [UsageProvider] = []
    /// 内容版本号，数据/选择变化时自增，供 SwiftUI 视图 .id()/diff 参考（替代 menuContentVersion）。
    private(set) var contentVersion: Int = 0
    /// popover 是否可见（替代 openMenus 字典；图标动画据此冻结，见 MP-23）。
    private(set) var isVisible: Bool = false
    /// 当前高亮项 id（集中式高亮，替代 highlightedMenuItems 字典，见 MP-18）。
    var highlightedItemID: String?

    init() {}

    func select(_ newSelection: ProviderSwitcherSelection) {
        guard newSelection != self.selection else { return }
        self.selection = newSelection
        self.contentVersion &+= 1
    }

    func bumpContentVersion() { self.contentVersion &+= 1 }

    func setVisible(_ visible: Bool) { self.isVisible = visible }
}
```

> 注：若 `ProviderSwitcherSelection` 不是 `Equatable`，本任务内为其补 `Equatable` 一致性（它已是带 `.overview`/`.provider(UsageProvider)` 的枚举，编译器可自动合成）。验证其定义位置后再决定是否需要显式声明。

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter MenuViewModelTests`
Expected: PASS（3 测试）

- [ ] **Step 5: 提交**

```bash
git add Sources/CodexBar/Popover/MenuViewModel.swift Tests/CodexBarTests/MenuViewModelTests.swift
git commit -m "feat(menu): add @Observable MenuViewModel for popover state"
```

### Task 0.3：`PopoverMenuController` 骨架（开关关时 no-op）

**Files:**
- Create: `Sources/CodexBar/Popover/PopoverMenuController.swift`
- Create: `Sources/CodexBar/Popover/PopoverRootView.swift`（阶段 0 占位最小视图，阶段 1 扩展）
- Test: `Tests/CodexBarTests/PopoverMenuControllerTests.swift`

- [ ] **Step 1: 写失败测试**（控制器构造 + 显隐切换不崩，且与 view model 同步）

```swift
import Testing
import AppKit
@testable import CodexBar

@MainActor @Suite struct PopoverMenuControllerTests {
    @Test func showAndCloseUpdatesViewModelVisibility() {
        let vm = MenuViewModel()
        let button = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength).button!
        let controller = PopoverMenuController(viewModel: vm, contentView: { EmptyContentProbe() })
        controller.show(relativeTo: button)
        #expect(vm.isVisible == true)
        controller.close()
        #expect(vm.isVisible == false)
    }
}

// 测试探针视图，避免依赖真实内容
import SwiftUI
private struct EmptyContentProbe: View { var body: some View { Color.clear.frame(width: 1, height: 1) } }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --filter PopoverMenuControllerTests`
Expected: FAIL（`PopoverMenuController` 未定义）

- [ ] **Step 3: 实现 PopoverMenuController 骨架**

```swift
import AppKit
import SwiftUI

/// 用 NSPopover(.transient) 承载持久 SwiftUI 根视图，替代 statusItem.menu。
/// 阶段 0 仅实现显隐 + view model 可见性同步；键盘/dismiss 监听在阶段 1 加入。
@MainActor
final class PopoverMenuController<Content: View> {
    private let viewModel: MenuViewModel
    private let popover: NSPopover
    private let hostingController: NSHostingController<Content>

    init(viewModel: MenuViewModel, contentView: () -> Content) {
        self.viewModel = viewModel
        let hosting = NSHostingController(rootView: contentView())
        self.hostingController = hosting
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hosting
        self.popover = popover
    }

    var isShown: Bool { self.popover.isShown }

    func show(relativeTo button: NSStatusBarButton) {
        guard !self.popover.isShown else { return }
        self.viewModel.setVisible(true)
        self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        self.popover.performClose(nil)
        self.viewModel.setVisible(false)
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if self.popover.isShown { self.close() } else { self.show(relativeTo: button) }
    }
}
```

`PopoverRootView.swift`（阶段 0 占位）：

```swift
import SwiftUI

/// 持久面板根视图。阶段 0 占位；阶段 1 接入切换器 + 单卡片。
struct PopoverRootView: View {
    @Bindable var viewModel: MenuViewModel
    var body: some View {
        Color.clear.frame(width: 310, height: 1)
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `swift test --filter PopoverMenuControllerTests`
Expected: PASS

> 若 swift-testing 在无 GUI 环境创建 NSPopover/NSWindow 受限，则改为断言 `controller.isShown` 状态机而非真实窗口；必要时给 controller 注入一个可 mock 的 presenter 协议（记录 show/close 调用）。优先真实路径，受限再降级。

- [ ] **Step 5: 提交**

```bash
git add Sources/CodexBar/Popover/PopoverMenuController.swift Sources/CodexBar/Popover/PopoverRootView.swift Tests/CodexBarTests/PopoverMenuControllerTests.swift
git commit -m "feat(menu): add PopoverMenuController + PopoverRootView skeleton (inactive)"
```

### Task 0.4：在 StatusItemController 持有 controller（开关关时不激活）

**Files:**
- Modify: `Sources/CodexBar/StatusItemController.swift`（加 `var popoverMenuController` 惰性属性 + `usePopoverMenu` 便捷读取）

- [ ] **Step 1: 写失败测试**（开关关时 `mergedMenu` 仍被 attach、popover 不创建）

```swift
// 追加到 PopoverMenuFeatureFlagTests.swift
@MainActor
@Test func attachUsesNSMenuWhenFlagOff() {
    // 复用现有测试构造 StatusItemController 的 helper（见 StatusItemControllerSplitLifecycleTests）
    // 断言：settings.usePopoverMenu == false 时，attachMenus 后 statusItem.menu !== nil
}
```

> 实现前先读 `StatusItemControllerSplitLifecycleTests.swift` 与 `StatusMenuTests.swift`，复用它们构造 `StatusItemController` 的既有 helper（factory/mock store），不要新发明构造方式。

- [ ] **Step 2: 运行确认失败** — `swift test --filter PopoverMenuFeatureFlagTests`，Expected: FAIL

- [ ] **Step 3: 加属性与开关读取**

在 `StatusItemController.swift` 属性区（约 144 行附近，monitor 字段旁）加：

```swift
var popoverMenuController: PopoverMenuController<PopoverRootView>?
let menuViewModel = MenuViewModel()

var usePopoverMenu: Bool { self.settings.usePopoverMenu }
```

> 本任务**不**改 attach 逻辑（保持开关关行为不变）；仅引入持有点，证明编译与现有测试不回归。

- [ ] **Step 4: 运行确认通过** — `swift test`（全量），Expected: 现有测试全 PASS（无回归）

- [ ] **Step 5: 提交**

```bash
git add -A && git commit -m "feat(menu): hold PopoverMenuController in StatusItemController (gated, inactive)"
```

### Task 0.5：阶段 0 验收

- [ ] 运行 `swift build` → 成功
- [ ] 运行 `swift test` → 全绿（无回归）
- [ ] `Scripts/lint.sh lint` → 通过
- [ ] 人工确认：`usePopoverMenu` 默认关，App 行为与重构前一致

---

## 阶段 1：popover 骨架 + 架构验证

> 目标：开关开时，点击状态项弹出 **NSPopover**，渲染 **provider 切换器 + 当前 provider 的单张用量卡片**，切换 provider = 改 `MenuViewModel.select(...)`（SwiftUI 增量更新，**不重建**）。dismiss（transient/Esc）+ 键盘快捷键（Cmd+R/,/Q、←→、Cmd+1..9）。**采样确认主线程不再有重建/测高突发**。这是架构正确性的最小可验证证明。

### Task 1.1：点击状态项 → 弹出 popover（开关开）

**Files:**
- Modify: `Sources/CodexBar/StatusItemController.swift`（attach 路径按开关分流：开关开时不设 `statusItem.menu`，改设 button.action → toggle popover）
- Modify: `Sources/CodexBar/StatusItemController+Actions.swift`（`openMenuFromShortcut` 分流）
- Test: `Tests/CodexBarTests/PopoverMenuControllerTests.swift`（追加：开关开时点击切换 popover 显隐）

- [ ] **Step 1: 写失败测试**

```swift
@MainActor
@Test func buttonClickTogglesPopoverWhenFlagOn() {
    // 构造 settings.usePopoverMenu = true 的 controller（复用既有 helper）
    // 模拟 statusItem.button 点击 → 期望 menuViewModel.isVisible 翻转
    // 再次点击 → 关闭
}
```

- [ ] **Step 2: 运行确认失败** — Expected: FAIL

- [ ] **Step 3: 实现 attach 分流 + 点击 target/action**

在 `attachMenus`（StatusItemController.swift:795-824）开关开分支：
```swift
if self.usePopoverMenu {
    self.statusItem.menu = nil
    if self.popoverMenuController == nil {
        self.menuViewModel.providers = self.store.enabledProvidersForDisplay()
        self.popoverMenuController = PopoverMenuController(viewModel: self.menuViewModel) {
            PopoverRootView(viewModel: self.menuViewModel)
        }
    }
    self.statusItem.button?.target = self
    self.statusItem.button?.action = #selector(self.handleStatusItemClick(_:))
    return
}
// ...既有 NSMenu 赋值逻辑保持不变...
```

加方法（建议放 `StatusItemController+Actions.swift`）：
```swift
@objc func handleStatusItemClick(_ sender: Any?) {
    guard self.usePopoverMenu, let button = self.statusItem.button else { return }
    self.menuViewModel.providers = self.store.enabledProvidersForDisplay()
    self.popoverMenuController?.toggle(relativeTo: button)
}
```

`openMenuFromShortcut`（+Actions.swift:271-285）开关开分支：直接 `popoverMenuController?.show(relativeTo: button)` 而非 `performClick`。

- [ ] **Step 4: 运行确认通过** — `swift test --filter PopoverMenuControllerTests`，Expected: PASS

- [ ] **Step 5: 提交** — `git commit -m "feat(menu): open NSPopover on status item click when flag on"`

### Task 1.2：切换器 + 单卡片渲染（持久视图，切换走增量更新）

**Files:**
- Modify: `Sources/CodexBar/Popover/PopoverRootView.swift`（接入 ProviderSwitcher + 单 provider 用量卡片）
- Test: `Tests/CodexBarTests/MenuViewModelTests.swift`（追加：选择切换驱动 selection，不触发任何"重建"副作用）

- [ ] **Step 1: 写失败测试**（view model 选择切换的语义；视图本身用 SwiftUI 预览/快照在阶段 6 补充 a11y/渲染测试）

```swift
@MainActor
@Test func switchingProviderUpdatesSelectionInPlace() {
    let vm = MenuViewModel()
    vm.providers = [.codex, .claude]
    vm.select(.provider(.codex))
    let v1 = vm.contentVersion
    vm.select(.provider(.claude))
    #expect(vm.selection == .provider(.claude))
    #expect(vm.contentVersion == v1 + 1)   // 仅 +1，证明是单次增量而非多次重建
}
```

- [ ] **Step 2: 运行确认失败** — Expected: FAIL（若 select 语义不符）或先 PASS（model 已就绪）→ 则本步重点在视图接线，测试作回归护栏

- [ ] **Step 3: 实现 PopoverRootView 渲染**

```swift
import SwiftUI
import CodexBarCore

struct PopoverRootView: View {
    @Bindable var viewModel: MenuViewModel
    let store: UsageStore            // 注入既有 store，复用现成卡片视图
    let settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.providers.count > 1 {
                ProviderSwitcherView(/* 复用既有切换器视图，selection 绑定 viewModel.selection */)
                Divider()
            }
            content
        }
        .frame(width: 310)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder private var content: some View {
        switch viewModel.selection {
        case .overview:
            // 阶段 2 补全 Overview；阶段 1 暂展示首个 provider 卡片
            providerCard(for: viewModel.providers.first ?? .codex)
        case let .provider(p):
            providerCard(for: p)
        }
    }

    @ViewBuilder private func providerCard(for provider: UsageProvider) -> some View {
        if let snapshot = store.snapshot(for: provider) {
            UsageMenuCardView(/* 复用既有卡片视图 + 既有 model 构造 */)
        } else {
            Text("Loading…").foregroundStyle(.secondary).padding()
        }
    }
}
```

> 关键：`PopoverRootView` 持有 `store`/`settings`（@Observable），SwiftUI 自动订阅其变化；切 provider 仅改 `viewModel.selection`，无 NSMenuItem 拆建、无手动测高。`UsageMenuCardView` / `ProviderSwitcherView` **复用现有视图**，不重写——它们已是 SwiftUI。构造参数照现有 `makeMenuCardItem`/`makeProviderSwitcherItem` 的调用方式（实现时读取并对齐）。

`PopoverMenuController` 与 `attachMenus` 构造处补传 `store`/`settings`。

- [ ] **Step 4: 运行确认通过** — `swift test`，Expected: 全绿

- [ ] **Step 5: 提交** — `git commit -m "feat(menu): render switcher + provider card in persistent popover view"`

### Task 1.3：dismiss（Esc / 点外部 / 选中动作后）

**Files:**
- Modify: `Sources/CodexBar/Popover/PopoverMenuController.swift`（`.transient` 已含点外部关闭；加 Esc local monitor + 暴露 dismiss 给动作回调）
- Test: 追加 `PopoverMenuControllerTests`

- [ ] **Step 1: 写失败测试**（Esc 触发 close；动作回调触发 close）

```swift
@MainActor
@Test func escapeKeyClosesPopover() {
    let vm = MenuViewModel()
    let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
    let button = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength).button!
    controller.show(relativeTo: button)
    controller.handleKeyDownForTesting(keyCode: 53) // Esc
    #expect(vm.isVisible == false)
}
```

- [ ] **Step 2: 运行确认失败** — Expected: FAIL

- [ ] **Step 3: 实现键盘 monitor**

在 controller 中，`show` 时安装 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`，`close` 时移除；Esc(53) → close。暴露 `handleKeyDownForTesting(keyCode:)` 内部接缝供测试。

```swift
private var keyMonitor: Any?

private func installKeyMonitor() {
    self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }
        if self.handleKeyDown(keyCode: event.keyCode, modifiers: event.modifierFlags) { return nil }
        return event
    }
}
private func removeKeyMonitor() {
    if let m = self.keyMonitor { NSEvent.removeMonitor(m); self.keyMonitor = nil }
}
@discardableResult func handleKeyDownForTesting(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
    self.handleKeyDown(keyCode: keyCode, modifiers: modifiers)
}
private func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
    if keyCode == 53 { self.close(); return true }   // Esc
    return false   // 其余快捷键在 Task 1.4 接入
}
```

`show()` 末尾调 `installKeyMonitor()`；`close()` 开头调 `removeKeyMonitor()`。

- [ ] **Step 4: 运行确认通过** — Expected: PASS
- [ ] **Step 5: 提交** — `git commit -m "feat(menu): Esc + transient dismissal for popover"`

### Task 1.4：键盘快捷键全保留（Cmd+R/,/Q、←→、Cmd+1..9）

**Files:**
- Modify: `Sources/CodexBar/Popover/PopoverMenuController.swift`（在 `handleKeyDown` 接入；分发到既有 action 与 provider 导航）
- Modify: 注入 action 回调（refresh/settings/quit）与 provider 导航闭包（复用 `StatusItemController+ProviderNavigation.swift` 的 `navigateProviderSwitcher`/`providerSelectionIndex` 语义）
- Test: 追加 `PopoverMenuControllerTests`（每个快捷键各一断言，用 `handleKeyDownForTesting`）

- [ ] **Step 1: 写失败测试**

```swift
@MainActor @Test func commandRTriggersRefresh() {
    var refreshed = false
    let vm = MenuViewModel()
    let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
    controller.onRefresh = { refreshed = true }
    _ = controller.handleKeyDownForTesting(keyCode: 15, modifiers: .command) // R
    #expect(refreshed == true)
}
@MainActor @Test func rightArrowNavigatesNext() {
    var moved: ProviderNavigationDirection?
    let vm = MenuViewModel(); vm.providers = [.codex, .claude]
    let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
    controller.onNavigate = { moved = $0 }
    _ = controller.handleKeyDownForTesting(keyCode: 124, modifiers: []) // →
    #expect(moved == .next)
}
@MainActor @Test func commandOneSelectsFirstProvider() {
    var picked: Int?
    let vm = MenuViewModel(); vm.providers = [.codex, .claude]
    let controller = PopoverMenuController(viewModel: vm) { EmptyContentProbe() }
    controller.onSelectIndex = { picked = $0 }
    _ = controller.handleKeyDownForTesting(keyCode: 18, modifiers: .command) // 1
    #expect(picked == 0)
}
```

- [ ] **Step 2: 运行确认失败** — Expected: FAIL（回调/keyCode 未接入）

- [ ] **Step 3: 实现快捷键分发**

在 controller 加注入回调 `var onRefresh/onSettings/onQuit: (() -> Void)?`、`var onNavigate: ((ProviderNavigationDirection) -> Void)?`、`var onSelectIndex: ((Int) -> Void)?`；在 `handleKeyDown` 内：
```swift
if modifiers.contains(.command) {
    switch keyCode {
    case 15: self.onRefresh?(); return true            // R
    case 43: self.onSettings?(); return true           // ,
    case 12: self.onQuit?(); return true               // Q
    case 18...26:                                      // 1..9
        let index = Int(keyCode) - 18
        self.onSelectIndex?(index); return true
    default: break
    }
}
switch keyCode {
case 53: self.close(); return true                     // Esc
case 123: self.onNavigate?(.previous); return true     // ←
case 124: self.onNavigate?(.next); return true         // →
default: return false
}
```
> keyCode 1..9 映射：18,19,20,21,23,22,26,28,25。实现时用映射表精确对应（上面的 `18...26` 仅示意，需替换为正确的离散映射）。`ProviderNavigationDirection` 复用既有类型（确认其定义后对齐 case 名）。

在 `attachMenus` 创建 controller 处接线：
```swift
controller.onRefresh = { [weak self] in self?.refreshFromMenu(); self?.popoverMenuController?.close() }
controller.onSettings = { [weak self] in self?.openSettings(); self?.popoverMenuController?.close() }
controller.onQuit = { [weak self] in self?.quitFromMenu() }
controller.onNavigate = { [weak self] dir in self?.navigateProviderSwitcher(dir) }   // 复用既有
controller.onSelectIndex = { [weak self] i in self?.selectProvider(atIndex: i) }     // 复用既有语义
```
> 上述 `refreshFromMenu/openSettings/quitFromMenu/selectProvider(atIndex:)` 对齐既有 action 方法名（实现时从 `StatusItemController+Actions.swift`/`+PersistentMenuActions.swift`/`+ProviderNavigation.swift` 找到真实方法名复用，勿新建）。

- [ ] **Step 4: 运行确认通过** — `swift test --filter PopoverMenuControllerTests`，Expected: PASS
- [ ] **Step 5: 提交** — `git commit -m "feat(menu): keep Cmd+R/,/Q, arrows, Cmd+1..9 in popover"`

### Task 1.5：架构验证 — 采样确认卡顿消失

**Files:** 无（验证步骤）

- [ ] **Step 1: 构建并以开关开运行**

```bash
swift build
defaults write com.steipete.codexbar usePopoverMenu -bool true
Scripts/compile_and_run.sh
```

- [ ] **Step 2: 采样**（用户侧执行，回放 `[[menu-perf-investigation-method]]` 的脚本）

让用户运行 `bash /tmp/cb_profile.sh` 并在 15s 内反复打开 popover + 切 provider。

- [ ] **Step 3: 判定**

Expected:
- 主线程**不再出现** `populateMenu`/`rebuildMenuContent`/`makeMenuCardItem`/`measuredHeight`/`hostedSubviewFittingHeight` 的工作帧（切换走 SwiftUI 增量更新）。
- 切 provider 的主线程突发显著下降（与开关关时对比）。
- 若仍有可观测卡顿 → 回到 systematic-debugging Phase 1，定位是否 store 频繁触发整树重渲（用 `.equatable()`/拆分 @Observable 子模型缓解）。

- [ ] **Step 4: 记录对比数据到** `docs/refactor/menu-popover-migration-contract.md` 的"验证记录"小节。

- [ ] **Step 5: 提交**（若有文档更新）— `git commit -m "docs(menu): record popover phase-1 perf verification"`

### Task 1.6：阶段 1 验收

- [ ] `swift build` 成功；`swift test` 全绿；lint 通过
- [ ] 开关关：行为与重构前一致（NSMenu 路径未受影响）
- [ ] 开关开：弹出 popover、切换器/单卡片可用、切换增量更新、Esc/点外部/快捷键全部工作
- [ ] 采样证明主线程重建/测高突发消失
- [ ] 已知缺口（留待阶段 2+）：完整卡片分段、Overview、账户切换器、图表下钻、非合并模式、悬停高亮、无障碍树、动画解耦——均在路线图中

---

## 自检（Self-Review）

- **Spec 覆盖**：阶段 0/1 覆盖了迁移契约的 MP-01/02（状态项保留）、MP-15/16（快捷键）、MP-19（dismiss）、MP-23（可见性信号基础）、MP-28（contentVersion）、测试接缝（contentVersion/isVisible/highlightedItemID/handleKeyDownForTesting）。MP-10/11/12/14/17/18/20-22/24-27/29 明确标注留待阶段 2–6，并列入路线图，无静默遗漏。
- **占位符扫描**：所有"实现时对齐既有方法名/类型"处均给出了**确切的参考文件与现成范例**（usageBarsShowUsed、navigateProviderSwitcher、UsageMenuCardView 等），非 TODO。keyCode 1..9 离散映射已标注需替换示意值为精确表。
- **类型一致性**：`MenuViewModel.select(_:)`/`contentVersion`/`isVisible`/`setVisible(_:)`、`PopoverMenuController.show/close/toggle/handleKeyDownForTesting`、回调 `onRefresh/onSettings/onQuit/onNavigate/onSelectIndex` 在各 Task 间命名一致。
- **风险对齐**：Critical「快捷键/事件拦截」在 Task 1.3/1.4 以 local monitor 优先验证；Critical「无障碍」明确排期阶段 6 并在契约中标注；High「性能回归」在 Task 1.5 设采样判定 + 缓解预案。
