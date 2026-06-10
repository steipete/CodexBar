# 菜单 Popover 阶段 4：非合并模式 per-provider popover 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 非合并模式（mergeIcons=false）下，每个 enabled provider 的 NSStatusItem 使用独立 popover 替代 NSMenu，保持与合并模式 popover 行为一致，实现 per-provider `PopoverMenuController<PopoverRootView>` + `MenuViewModel`。

**Architecture:** 在 `StatusItemController+Popover.swift` 中提取 `makePopoverController(viewModel:)` 私有 helper 供合并模式和 per-provider 两路复用，消除代码重复；新增 `attachProviderPopovers(fallback:)` 复刻 `attachMenus(fallback:)` 遍历逻辑；`handleProviderStatusItemClick(_:)` 通过恒等比较反查 provider；多面板互斥通过 `closeAllProviderPopovers(except:)` 实现。

**Tech Stack:** Swift 5.9+，SwiftUI，AppKit，NSPopover，`@Observable`，Swift Testing

---

## 文件结构

| 文件 | 改动 |
|------|------|
| `Sources/CodexBar/StatusItemController.swift` | 新增 `providerPopoverControllers` / `providerMenuViewModels` 两个字典属性（放在 Popover 属性区） |
| `Sources/CodexBar/StatusItemController+Popover.swift` | 提取 `makePopoverController(viewModel:)`；新增 `attachProviderPopovers(fallback:)`、`ensureProviderPopover(for:)`、`closeAllProviderPopovers(except:)` |
| `Sources/CodexBar/StatusItemController+Actions.swift` | 新增 `handleProviderStatusItemClick(_:)`；修改 `openMenuFromShortcut` 非合并分支；`attachMenus(fallback:)` 开头加 popover 分流 |
| `Sources/CodexBar/Popover/MenuViewModel.swift` | 新增 `static func singleProvider(_ p: UsageProvider) -> MenuViewModel` 便利工厂（供测试） |
| `Tests/CodexBarTests/PopoverPerProviderTests.swift` | 新建测试文件：singleProvider 工厂语义测试 |

---

## Task 1：在 MenuViewModel 添加 `singleProvider` 便利工厂

**Files:**
- Modify: `Sources/CodexBar/Popover/MenuViewModel.swift`
- Test: `Tests/CodexBarTests/PopoverPerProviderTests.swift`（新建）

### 1.1 先写测试

- [ ] **新建测试文件 `Tests/CodexBarTests/PopoverPerProviderTests.swift`**

```swift
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite struct PopoverPerProviderTests {
    // MARK: - MenuViewModel.singleProvider 工厂

    @Test func singleProviderFactorySetProviders() {
        let vm = MenuViewModel.singleProvider(.claude)
        #expect(vm.providers == [.claude])
    }

    @Test func singleProviderFactoryNoOverview() {
        let vm = MenuViewModel.singleProvider(.claude)
        #expect(vm.includesOverview == false)
    }

    @Test func singleProviderFactorySelectionIsProvider() {
        let vm = MenuViewModel.singleProvider(.codex)
        #expect(vm.selection == .provider(.codex))
    }

    @Test func singleProviderFactoryNoSelectionChangedCallback() {
        let vm = MenuViewModel.singleProvider(.openai)
        // 单 provider 不接 onSelectionChanged，不应触发持久化
        #expect(vm.onSelectionChanged == nil)
    }

    @Test func singleProviderFactorySelectDoesNotCrash() {
        let vm = MenuViewModel.singleProvider(.claude)
        // 调用 select 不应崩溃（onSelectionChanged 为 nil 时）
        vm.select(.provider(.openai))
        #expect(vm.selection == .provider(.openai))
    }
}
```

- [ ] **运行测试验证失败**

```bash
cd /Users/jassy/Documents/glm/codexbar
swift test --filter PopoverPerProviderTests 2>&1 | tail -20
```

期望：编译错误（`singleProvider` 尚未存在）。

### 1.2 实现 `singleProvider` 工厂

- [ ] **修改 `MenuViewModel.swift`，在 `init()` 后添加工厂方法**

在 `MenuViewModel.swift` 的 `init() {}` 行后面插入：

```swift
    /// 单 provider 模式便利工厂：providers=[p]、includesOverview=false、selection=.provider(p)、不设 onSelectionChanged。
    /// 供非合并模式 per-provider popover 和测试使用。
    static func singleProvider(_ provider: UsageProvider) -> MenuViewModel {
        let vm = MenuViewModel()
        vm.providers = [provider]
        vm.includesOverview = false
        // 不调用 select()（避免触发 onSelectionChanged），直接设置 selection
        vm.selection = .provider(provider)
        return vm
    }
```

- [ ] **运行测试验证通过**

```bash
swift test --filter PopoverPerProviderTests 2>&1 | tail -20
```

期望：5 个测试全部 PASS。

- [ ] **提交**

```bash
git add Sources/CodexBar/Popover/MenuViewModel.swift Tests/CodexBarTests/PopoverPerProviderTests.swift
git commit -m "feat(popover): add MenuViewModel.singleProvider factory for per-provider mode

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2：在 StatusItemController 添加 per-provider 存储属性

**Files:**
- Modify: `Sources/CodexBar/StatusItemController.swift`（属性区 Popover 段）

### 2.1 添加两个字典属性

- [ ] **在 `StatusItemController.swift` Popover 属性区添加存储**

找到 `var popoverMenuController: PopoverMenuController<PopoverRootView>?` 那行（约第 148 行），在其后插入：

```swift
    // per-provider popover（非合并模式；keyed by UsageProvider）
    var providerPopoverControllers: [UsageProvider: PopoverMenuController<PopoverRootView>] = [:]
    var providerMenuViewModels: [UsageProvider: MenuViewModel] = [:]
```

- [ ] **验证编译**

```bash
swift build 2>&1 | tail -20
```

期望：build succeeded，0 errors。

- [ ] **提交**

```bash
git add Sources/CodexBar/StatusItemController.swift
git commit -m "feat(popover): add providerPopoverControllers/providerMenuViewModels storage for per-provider mode

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3：提取 `makePopoverController(viewModel:)` helper

**Files:**
- Modify: `Sources/CodexBar/StatusItemController+Popover.swift`

提取目的：`attachMergedPopover()` 中构造 `PopoverMenuController` 的注入闭包有 20+ 行，per-provider 版完全同构（仅 vm 参数化），不提取会造成严重重复。

### 3.1 提取 helper

- [ ] **在 `StatusItemController+Popover.swift` 中，将 `attachMergedPopover()` 中 `PopoverMenuController(viewModel:)` 构造块提取为私有 helper**

在 `performLegacyMenuAction` 前面（`// MARK: - popover 动作分发` 上方）插入：

```swift
    // MARK: - Popover controller 工厂（合并模式和 per-provider 复用）

    /// 构造一个 PopoverMenuController，注入所有 make* 闭包。
    /// vm 参数化：不同 controller 的闭包各自捕获自己的 vm，selection 语义自动正确。
    /// - makeOverviewRows 注入：合并模式传 { self.popoverOverviewRows() }；
    ///   per-provider 传 { [] }（单 provider 无 overview）。
    /// - makeOverviewChart 注入：合并模式传真实实现；
    ///   per-provider 传 { _ in nil }（单 provider 无 overview chart，但 PopoverRootView
    ///   要求 non-optional 闭包，因此传返回 nil 的 no-op 闭包）。
    private func makePopoverController(
        viewModel vm: MenuViewModel,
        makeOverviewRows: @escaping () -> [PopoverOverviewRow] = { [] },
        makeOverviewChart: @escaping (PopoverOverviewRow) -> PopoverChartKind? = { _ in nil }
    ) -> PopoverMenuController<PopoverRootView> {
        let store = self.store
        return PopoverMenuController(viewModel: vm) { [weak self] in
            PopoverRootView(
                viewModel: vm,
                store: store,
                makeCardPlan: { [weak self] provider in
                    self?.popoverCardPlan(for: provider) ?? PopoverCardPlan()
                },
                makeAccountSwitcher: { [weak self] provider in
                    self?.popoverAccountSwitcherModel(for: provider).map { model in
                        PopoverRootView.AccountSwitcherBinding(
                            segments: model.segments,
                            onSelect: model.onSelect)
                    }
                },
                makeSections: { [weak self] in
                    guard let self else { return [] }
                    let isOverview = vm.selection == .overview
                    let provider: UsageProvider? = {
                        if isOverview {
                            let enabled = vm.providers
                            if enabled.isEmpty { return UsageProvider.codex }
                            return enabled.first(where: { self.store.isProviderAvailable($0) })
                                ?? enabled.first
                        }
                        if case let .provider(p) = vm.selection { return p }
                        return vm.providers.first
                    }()
                    return MenuDescriptor.build(
                        provider: provider,
                        store: store,
                        settings: self.settings,
                        account: self.account,
                        managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
                        codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
                        updateReady: self.updater.updateStatus.isUpdateReady,
                        includeContextualActions: !isOverview).sections
                },
                makeOverviewRows: makeOverviewRows,
                overviewEmptyText: { [weak self] in
                    self?.popoverOverviewEmptyText()
                },
                onAction: { [weak self] action in self?.performMenuAction(action) },
                onBuyCredits: { [weak self] in
                    self?.openCreditsPurchase()
                    self?.popoverMenuController?.close()
                },
                switcherIcon: { [weak self] provider in
                    (self?.settings.switcherShowsIcons == true)
                        ? self?.popoverSwitcherIcon(for: provider)
                        : nil
                },
                makeChartEntries: { [weak self] provider in
                    self?.popoverChartEntries(for: provider) ?? []
                },
                makeOverviewChart: makeOverviewChart,
                makeChartView: { [weak self] kind, width in
                    self?.popoverChartView(for: kind, width: width)
                })
        }
    }
```

注意：`makeOverviewChart` 的闭包签名需与 `PopoverRootView` 的对应参数一致。先查一下实际签名：

- [ ] **查看 PopoverRootView 的 makeOverviewChart 参数签名**

```bash
grep -n "makeOverviewChart" /Users/jassy/Documents/glm/codexbar/Sources/CodexBar/Popover/PopoverRootView.swift | head -5
```

根据查到的签名调整上面的 `makeOverviewChart` 参数类型。

### 3.2 重构 attachMergedPopover 使用 helper

- [ ] **修改 `attachMergedPopover()`：将其中的 `PopoverMenuController(viewModel: vm) { ... }` 大块替换为调用 `makePopoverController`**

原来 `attachMergedPopover()` 中的构造块（第 25-89 行）替换为：

```swift
            self.popoverMenuController = self.makePopoverController(
                viewModel: vm,
                makeOverviewRows: { [weak self] in self?.popoverOverviewRows() ?? [] },
                makeOverviewChart: { [weak self] row in
                    self?.popoverOverviewChart(for: row.provider, model: row.model)
                })
```

同时删除原来 `PopoverMenuController(viewModel: vm) { ... }` 整个大闭包块（第 25 行的 `self.popoverMenuController = PopoverMenuController(viewModel: vm) { [weak self] in` 到对应的 `}` 行）。

- [ ] **验证编译**

```bash
swift build 2>&1 | tail -20
```

期望：build succeeded，0 errors。

- [ ] **运行全量测试确认没有回归**

```bash
swift test 2>&1 | tail -30
```

期望：所有现有测试 PASS。

- [ ] **提交**

```bash
git add Sources/CodexBar/StatusItemController+Popover.swift
git commit -m "refactor(popover): extract makePopoverController helper to eliminate merged/per-provider duplication

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4：实现 `ensureProviderPopover(for:)` 和 `attachProviderPopovers(fallback:)`

**Files:**
- Modify: `Sources/CodexBar/StatusItemController+Popover.swift`

### 4.1 添加 closeAllProviderPopovers 和 ensureProviderPopover

- [ ] **在 `StatusItemController+Popover.swift` 中，在 `// MARK: - popover 动作分发` 前面插入**

```swift
    // MARK: - Per-provider popover（非合并模式）

    /// 关闭除指定 provider 外的所有 per-provider popover（及合并 popover）。
    /// NSPopover(.transient) 大多自动关，但点击另一 statusItem 不一定触发 transient 关闭，
    /// 显式关闭保证互斥。
    func closeAllProviderPopovers(except provider: UsageProvider? = nil) {
        for (p, ctrl) in self.providerPopoverControllers where p != provider {
            ctrl.close()
        }
        // 合并 popover 也一并关闭（模式切换时兜底）
        self.popoverMenuController?.close()
    }

    /// 懒创建指定 provider 的 MenuViewModel + PopoverMenuController（首次调用后缓存）。
    func ensureProviderPopover(for provider: UsageProvider) {
        if self.providerPopoverControllers[provider] != nil { return }
        let vm = MenuViewModel.singleProvider(provider)
        self.providerMenuViewModels[provider] = vm
        let ctrl = self.makePopoverController(
            viewModel: vm,
            makeOverviewRows: { [] },
            makeOverviewChart: { _ in nil })
        // per-provider 快捷键回调：onRefresh/onSettings/onQuit 照旧；
        // onNavigate/onSelectIndex 单 provider 下 no-op（不设）。
        ctrl.onRefresh = { [weak self] in
            self?.refreshNow()
            self?.providerPopoverControllers[provider]?.close()
        }
        ctrl.onSettings = { [weak self] in
            self?.showSettingsGeneral()
            self?.providerPopoverControllers[provider]?.close()
        }
        ctrl.onQuit = { [weak self] in
            self?.quit()
        }
        // onNavigate/onSelectIndex 留为 nil（单 provider 无切换器，不处理方向键/数字键）
        self.providerPopoverControllers[provider] = ctrl
    }

    /// 非合并模式下为每个 enabled/fallback provider 安装 per-provider popover，复刻 attachMenus(fallback:) 遍历结构。
    func attachProviderPopovers(fallback: UsageProvider?) {
        for provider in UsageProvider.allCases {
            let shouldHaveItem = self.isEnabled(provider) || fallback == provider
            if shouldHaveItem {
                let item = self.lazyStatusItem(for: provider)
                item.menu = nil  // 清掉残留 NSMenu
                self.ensureProviderPopover(for: provider)
                item.button?.target = self
                item.button?.action = #selector(self.handleProviderStatusItemClick(_:))
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            } else if let item = self.statusItems[provider] {
                item.menu = nil
                item.button?.target = nil
                item.button?.action = nil
            }
        }
    }
```

- [ ] **验证编译**

```bash
swift build 2>&1 | tail -20
```

期望：build succeeded，0 errors。（`handleProviderStatusItemClick` 还未定义，可能有编译错误——如有，暂时注释掉该 selector 引用，下一步补全。）

---

## Task 5：实现 `handleProviderStatusItemClick(_:)`

**Files:**
- Modify: `Sources/CodexBar/StatusItemController+Actions.swift`

### 5.1 添加点击处理器

- [ ] **在 `StatusItemController+Actions.swift` 中，在 `handleStatusItemClick(_:)` 方法后面插入**

```swift
    /// 非合并模式 per-provider statusItem 按钮点击处理（popover 路径）。
    /// sender 即 NSStatusBarButton；通过恒等比较反查 provider。
    @objc func handleProviderStatusItemClick(_ sender: Any?) {
        guard self.usePopoverMenu, let button = sender as? NSStatusBarButton else { return }
        guard let provider = self.statusItems.first(where: { $0.value.button === button })?.key else { return }
        self.closeAllProviderPopovers(except: provider)
        self.providerPopoverControllers[provider]?.toggle(relativeTo: button)
    }
```

- [ ] **验证编译**

```bash
swift build 2>&1 | tail -20
```

期望：build succeeded，0 errors。

---

## Task 6：分流接线——attachMenus(fallback:) 和 openMenuFromShortcut

**Files:**
- Modify: `Sources/CodexBar/StatusItemController.swift`（`attachMenus(fallback:)` 开头）
- Modify: `Sources/CodexBar/StatusItemController+Actions.swift`（`openMenuFromShortcut` 非合并分支）

### 6.1 attachMenus(fallback:) 开头加 popover 分流

- [ ] **在 `StatusItemController.swift` 的 `private func attachMenus(fallback: UsageProvider? = nil)` 方法体开头插入**

在 `for provider in UsageProvider.allCases {` 前面加：

```swift
        if self.usePopoverMenu {
            self.attachProviderPopovers(fallback: fallback)
            return
        }
        // NSMenu 路径（从 popover 切回时清残留 button target/action）
        for provider in UsageProvider.allCases {
            if let item = self.statusItems[provider] {
                item.button?.target = nil
                item.button?.action = nil
            }
        }
```

注意：原方法中已有一个 for 循环，上面新加的清理 loop 要放在原 for loop 之前、但在 popover 分流的 `return` 之后；或者更简洁地在原 for loop 头部每次给有 item 的 provider 清掉 target/action（在 `if shouldHaveItem {` 的 else 分支中已有 `item.menu = nil` 但无 target 清理）。

具体插入方式：将 `private func attachMenus(fallback: UsageProvider? = nil) {` 的方法体开头替换为：

```swift
    private func attachMenus(fallback: UsageProvider? = nil) {
        if self.usePopoverMenu {
            self.attachProviderPopovers(fallback: fallback)
            return
        }
        // 从 popover 模式切回时清掉残留 button target/action（保证 NSMenu 路径不残留 action）
        for provider in UsageProvider.allCases {
            if let item = self.statusItems[provider] {
                item.button?.target = nil
                item.button?.action = nil
            }
        }
        for provider in UsageProvider.allCases {
            // Only access/create the status item if it's actually needed
            let shouldHaveItem = self.isEnabled(provider) || fallback == provider
            // ... 以下原逻辑不变 ...
```

（原 `for provider in UsageProvider.allCases {` 开头的 for 循环保持完整不删，只在方法最开头加上面的分流块 + 清理循环。）

### 6.2 openMenuFromShortcut 非合并分支加 popover 分流

- [ ] **修改 `StatusItemController+Actions.swift` 的 `openMenuFromShortcut()` 方法的非合并分支**

找到：

```swift
        let provider = self.resolvedShortcutProvider()
        // Use the lazy accessor to ensure the item exists
        let item = self.lazyStatusItem(for: provider)
        item.button?.performClick(nil)
```

替换为：

```swift
        let provider = self.resolvedShortcutProvider()
        // Use the lazy accessor to ensure the item exists
        let item = self.lazyStatusItem(for: provider)
        if self.usePopoverMenu, let button = item.button {
            // 确保 popover controller 已创建（快捷键可能先于 attachProviderPopovers 触发）
            self.ensureProviderPopover(for: provider)
            self.closeAllProviderPopovers(except: provider)
            self.providerPopoverControllers[provider]?.toggle(relativeTo: button)
        } else {
            item.button?.performClick(nil)
        }
```

- [ ] **验证编译**

```bash
swift build 2>&1 | tail -20
```

期望：build succeeded，0 errors。

- [ ] **运行全量测试**

```bash
swift test 2>&1 | tail -30
```

期望：所有测试 PASS。

- [ ] **提交**

```bash
git add Sources/CodexBar/StatusItemController.swift Sources/CodexBar/StatusItemController+Actions.swift Sources/CodexBar/StatusItemController+Popover.swift
git commit -m "feat(menu): per-provider popovers for split (non-merged) icon mode

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7：lint 检查 + 最终提交

**Files:** 无新增，仅验证

### 7.1 Lint

- [ ] **运行 lint format + lint check**

```bash
cd /Users/jassy/Documents/glm/codexbar
bash Scripts/lint.sh format
bash Scripts/lint.sh lint
```

期望：0 violations。若有 violations，根据提示修复后重新运行。

### 7.2 全量测试再跑一次

- [ ] **最终测试**

```bash
swift test 2>&1 | tail -30
```

期望：所有测试 PASS。

### 7.3 确认 Task 25 可关闭

- [ ] **确认编译 + lint + 测试全部 PASS 后，标记 Task 25 完成（最终验收：新旧界面对比）并口头报告**

---

## 自检 checklist

实现完成后逐项确认：

- [ ] `providerPopoverControllers` / `providerMenuViewModels` 已加入 StatusItemController 主类属性区
- [ ] `makePopoverController(viewModel:makeOverviewRows:makeOverviewChart:)` helper 提取完成，`attachMergedPopover()` 已使用 helper
- [ ] `attachProviderPopovers(fallback:)` 遍历结构与 `attachMenus(fallback:)` 一一对应
- [ ] `ensureProviderPopover(for:)` 使用 `MenuViewModel.singleProvider()`，不接 `onSelectionChanged`
- [ ] `handleProviderStatusItemClick(_:)` 通过恒等比较反查 provider
- [ ] `closeAllProviderPopovers(except:)` 同时关闭合并 popover
- [ ] `attachMenus(fallback:)` 开头有 `usePopoverMenu` 分流到 `attachProviderPopovers`
- [ ] `openMenuFromShortcut` 非合并分支有 popover 路径
- [ ] 从 popover 切回 NSMenu 时 button target/action 被清理（无残留）
- [ ] `swift build` 0 errors，`swift test` 全部 PASS，lint 0 violations
