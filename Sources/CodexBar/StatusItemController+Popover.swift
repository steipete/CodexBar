import AppKit
import CodexBarCore
import SwiftUI

// MARK: - Popover 菜单接入（合并模式）

//
// 把 popover 相关的接入逻辑从 StatusItemController 主体抽出，集中于此扩展，
// 既保持主类体在 swiftlint type_body_length 限制内，也便于后续阶段在此扩展。
// 仅当 `usePopoverMenu` 开关开启时这些路径才生效；关闭时主类走原有 NSMenu 逻辑。

extension StatusItemController {
    /// 特性开关：是否启用 NSPopover 菜单（替代 NSMenu）。
    var usePopoverMenu: Bool {
        self.settings.usePopoverMenu
    }

    /// 合并模式下安装 popover：清掉 statusItem.menu，懒创建 PopoverMenuController 并接线快捷键回调，
    /// 再把状态项按钮点击（含右键）路由到 handleStatusItemClick。仅在 usePopoverMenu 开启时调用。
    func attachMergedPopover() {
        self.statusItem.menu = nil
        if self.popoverMenuController == nil {
            self.menuViewModel.providers = self.store.enabledProvidersForDisplay()
            let vm = self.menuViewModel
            let store = self.store
            self.popoverMenuController = PopoverMenuController(viewModel: vm) { [weak self] in
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
                        // overview 时取 resolvedMenuProvider 等价逻辑（与 populateMenu:224-228 对齐）：
                        // 优先选已启用且可用的 provider，不传切换器选择，等价于 NSMenu overview 路径。
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
                    makeOverviewRows: { [weak self] in
                        self?.popoverOverviewRows() ?? []
                    },
                    overviewEmptyText: { [weak self] in
                        self?.popoverOverviewEmptyText()
                    },
                    onAction: { [weak self] action in self?.performMenuAction(action) },
                    onBuyCredits: { [weak self] in
                        self?.openCreditsPurchase()
                        self?.popoverMenuController?.close()
                    })
            }
            self.wirePopoverShortcutCallbacks()
        }
        self.statusItem.button?.target = self
        self.statusItem.button?.action = #selector(self.handleStatusItemClick(_:))
        // 右键也触发 action，使右键可弹出 popover
        self.statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - popover 动作分发

    /// popover 动作分发：通过 selector(for:) 复用 NSMenu 路径的全部逻辑，
    /// 统一构造一个临时 NSMenuItem 传递 representedObject，再对无参/带参 selector 分别分发。
    /// quit 不关闭 popover（应用即将退出）；其余动作执行后关闭。
    func performMenuAction(_ action: MenuDescriptor.MenuAction) {
        self.performLegacyMenuAction(action)
        if action != .quit {
            self.popoverMenuController?.close()
        }
    }

    /// 通过已有的 selector(for:) 映射分发动作，复用 NSMenu 路径全部逻辑。
    /// - 有 payload（带参 selector）：构造临时 NSMenuItem 传递 representedObject，
    ///   调用 perform(_:with:)——AppKit 约定 with: 参数传给 @objc 方法的 sender 参数。
    /// - 无 payload（无参 selector）：调用 perform(_:)，避免向无参方法传入多余参数。
    private func performLegacyMenuAction(_ action: MenuDescriptor.MenuAction) {
        let (sel, payload) = self.selector(for: action)
        if let payload {
            let item = NSMenuItem()
            item.representedObject = payload
            _ = self.perform(sel, with: item)
        } else {
            _ = self.perform(sel)
        }
    }

    // MARK: - 卡片计划（复刻 addMenuCards 分流逻辑，纯数据）

    /// 构造当前 provider 的卡片渲染计划，供 PopoverRootView 纯渲染消费。
    /// 分流次序与 addMenuCards 保持一致：
    ///   1. Codex 多账户 stacked → 按 workspace section 展开 cards
    ///   2. Token 多账户 stacked → snapshot compactMap
    ///   3. Kilo 多 scope → kiloScopeSnapshots compactMap
    ///   4. 单卡片 / 占位
    ///   + storageText / showBuyCredits
    func popoverCardPlan(for provider: UsageProvider) -> PopoverCardPlan {
        var plan = PopoverCardPlan()

        // ── 1. Codex stacked ──
        if let codexDisplay = self.codexAccountMenuDisplay(for: provider), codexDisplay.showAll {
            let snapshotsByAccountID = Dictionary(
                uniqueKeysWithValues: codexDisplay.snapshots.map { ($0.account.id, $0) })
            let sections = codexDisplay.showsWorkspaceGroups
                ? codexDisplay.workspaceSections
                : [CodexAccountWorkspaceSection(title: "", accounts: codexDisplay.accounts)]

            for section in sections {
                var isFirstInSection = true
                for account in section.accounts {
                    let accountSnapshot = snapshotsByAccountID[account.id]
                    let health = CodexAccountHealth.status(for: account, error: accountSnapshot?.error)
                    guard let model = self.menuCardModel(
                        for: .codex,
                        snapshotOverride: accountSnapshot?.snapshot,
                        errorOverride: health.label,
                        forceOverrideCard: accountSnapshot == nil,
                        accountOverride: self.accountInfo(for: account))
                    else { continue }
                    let header: String? = (codexDisplay.showsWorkspaceGroups && isFirstInSection)
                        ? section.title
                        : nil
                    plan.cards.append(PopoverCardPlan.Card(
                        id: account.id,
                        model: model,
                        workspaceHeader: header))
                    isFirstInSection = false
                }
            }
            plan.storageText = self.store.storageFootprintText(for: provider)
            plan.showBuyCredits = self.popoverCanShowBuyCredits(for: provider)
            return plan
        }

        // ── 2. Token stacked ──
        if let tokenDisplay = self.tokenAccountMenuDisplay(for: provider), tokenDisplay.showAll {
            let cards = tokenDisplay.snapshots.compactMap { accountSnapshot in
                self.menuCardModel(
                    for: provider,
                    snapshotOverride: accountSnapshot.snapshot,
                    errorOverride: accountSnapshot.error)
                    .map { model in
                        PopoverCardPlan.Card(
                            id: accountSnapshot.account.id.uuidString,
                            model: model,
                            workspaceHeader: nil)
                    }
            }
            plan.cards = cards
            if plan.cards.isEmpty {
                plan.emptyText = "Loading…"
            }
            plan.storageText = self.store.storageFootprintText(for: provider)
            plan.showBuyCredits = self.popoverCanShowBuyCredits(for: provider)
            return plan
        }

        // ── 3. Kilo multi-scope ──
        if provider == .kilo, self.store.kiloScopeSnapshots.count > 1 {
            let cards = self.store.kiloScopeSnapshots.compactMap { scope in
                self.menuCardModel(
                    for: .kilo,
                    snapshotOverride: scope.snapshot,
                    errorOverride: scope.errorMessage,
                    forceOverrideCard: scope.snapshot == nil)
                    .map { model in
                        PopoverCardPlan.Card(id: scope.id, model: model, workspaceHeader: nil)
                    }
            }
            plan.cards = cards
            if plan.cards.isEmpty {
                plan.emptyText = "Loading…"
            }
            plan.storageText = self.store.storageFootprintText(for: provider)
            plan.showBuyCredits = self.popoverCanShowBuyCredits(for: provider)
            return plan
        }

        // ── 4. 单卡片 ──
        if let model = self.menuCardModel(for: provider) {
            plan.cards = [PopoverCardPlan.Card(id: "single", model: model, workspaceHeader: nil)]
        } else {
            plan.emptyText = "Loading…"
        }
        plan.storageText = self.store.storageFootprintText(for: provider)
        plan.showBuyCredits = self.popoverCanShowBuyCredits(for: provider)
        return plan
    }

    /// 计算 Buy Credits 是否可显示。
    /// 复刻 openAIWebContext 中的 canShowBuyCredits 逻辑（showAllAccounts 时不显示 Buy Credits
    /// 对 popover 单账户路径无影响；多账户 stacked 时与 NSMenu 行为一致：不显示）。
    private func popoverCanShowBuyCredits(for provider: UsageProvider) -> Bool {
        guard self.settings.showOptionalCreditsAndExtraUsage else { return false }
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .liveCard)
        return codexProjection?.canShowBuyCredits == true
    }

    // MARK: - 账户切换器模型

    /// popover 账户切换器的数据模型：segments + onSelect 闭包。
    struct PopoverAccountSwitcherModel {
        let segments: [PopoverAccountSwitcherView.Segment]
        let onSelect: (String) -> Void
    }

    /// 构造指定 provider 的 PopoverAccountSwitcherModel。
    /// - .codex：codexAccountMenuDisplay 且 showSwitcher → Codex 路径。
    /// - 其他：tokenAccountMenuDisplay 且 showSwitcher → Token 路径。
    /// - 不满足或 display == nil → nil。
    func popoverAccountSwitcherModel(for provider: UsageProvider) -> PopoverAccountSwitcherModel? {
        if provider == .codex {
            return self.codexAccountSwitcherModel()
        }
        return self.tokenAccountSwitcherModel(for: provider)
    }

    private func codexAccountSwitcherModel() -> PopoverAccountSwitcherModel? {
        guard let display = self.codexAccountMenuDisplay(for: .codex),
              display.showSwitcher
        else { return nil }
        let segments = PopoverAccountSwitcherView.Segment.make(
            ids: display.accounts.map(\.id),
            titles: display.accounts.map(\.menuDisplayName),
            selectedID: display.activeVisibleAccountID)
        return PopoverAccountSwitcherModel(
            segments: segments,
            onSelect: { [weak self] id in
                guard let self else { return }
                guard let account = display.accounts.first(where: { $0.id == id }) else { return }
                self.handleCodexVisibleAccountSelectionFromPopover(account)
            })
    }

    private func tokenAccountSwitcherModel(for provider: UsageProvider) -> PopoverAccountSwitcherModel? {
        guard let display = self.tokenAccountMenuDisplay(for: provider),
              display.showSwitcher
        else { return nil }
        let segments = PopoverAccountSwitcherView.Segment.make(
            ids: display.accounts.indices.map { "\($0)" },
            titles: display.accounts.map(\.displayName),
            selectedID: "\(display.activeIndex)")
        return PopoverAccountSwitcherModel(
            segments: segments,
            onSelect: { [weak self] idString in
                guard let self, let index = Int(idString) else { return }
                self.handleTokenAccountSelectionFromPopover(index: index, provider: provider)
            })
    }

    /// Codex 账户选择处理：复刻 handleCodexVisibleAccountSelection 的逻辑，但不传 NSMenu。
    private func handleCodexVisibleAccountSelectionFromPopover(_ account: CodexVisibleAccount) {
        self.settings.selectDisplayedCodexVisibleAccount(account)
        _ = self.store.prepareCodexAccountScopedRefreshIfNeeded()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refreshCodexAccountScopedState(
                    allowDisabled: true,
                    phaseDidChange: nil)
            }
        }
    }

    /// Token 账户选择处理：复刻 makeTokenAccountSwitcherItem 中 onSelect 闭包的逻辑，但不传 NSMenu。
    @discardableResult
    private func handleTokenAccountSelectionFromPopover(index: Int, provider: UsageProvider) -> Task<Void, Never> {
        self.settings.setActiveTokenAccountIndex(index, for: provider)
        self.applyIcon(phase: nil)
        return Task { @MainActor [weak self] in
            guard let self else { return }
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refreshProvider(provider)
            }
        }
    }

    // MARK: - Overview 行数据（Task 2.4）

    /// Overview 模式下单行数据：与 NSMenu addOverviewRows 同源构造。
    struct PopoverOverviewRow: Identifiable {
        let provider: UsageProvider
        let model: UsageMenuCardView.Model
        let storageText: String?
        var id: String {
            self.provider.rawValue
        }
    }

    /// 构造 overview 行数据列表，与 addOverviewRows 同源逻辑：
    ///   1. reconcileMergedOverviewSelectedProviders 解析已选 providers；
    ///   2. compactMap menuCardModel，跳过 nil 与 isOverviewErrorOnly；
    ///   3. 每行附带 storageFootprintText。
    func popoverOverviewRows() -> [PopoverOverviewRow] {
        let enabledProviders = self.store.enabledProvidersForDisplay()
        let overviewProviders = self.settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: enabledProviders)
        return overviewProviders.compactMap { provider in
            guard let model = self.menuCardModel(for: provider) else { return nil }
            guard !model.isOverviewErrorOnly else { return nil }
            let storageText = self.store.storageFootprintText(for: provider)
            return PopoverOverviewRow(provider: provider, model: model, storageText: storageText)
        }
    }

    /// Overview 空态文案：nil 表示有内容（rows 非空），否则返回与 NSMenu 一致的本地化文案。
    ///   - resolvedProviders 为空 → "No providers selected for Overview."
    ///   - resolvedProviders 非空但行数据为空 → "No overview data available."
    func popoverOverviewEmptyText() -> String? {
        let enabledProviders = self.store.enabledProvidersForDisplay()
        let resolvedProviders = self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit)
        if resolvedProviders.isEmpty {
            return L("No providers selected for Overview.")
        }
        // rows 非空时返回 nil（有内容，不需要空态）
        let rows = self.popoverOverviewRows()
        return rows.isEmpty ? L("No overview data available.") : nil
    }

    /// 接线 popover 的键盘快捷键回调（只在控制器首次创建时设一次，弱引用防环）。
    private func wirePopoverShortcutCallbacks() {
        self.popoverMenuController?.onRefresh = { [weak self] in
            self?.refreshNow()
            self?.popoverMenuController?.close()
        }
        self.popoverMenuController?.onSettings = { [weak self] in
            self?.showSettingsGeneral()
            self?.popoverMenuController?.close()
        }
        self.popoverMenuController?.onQuit = { [weak self] in
            self?.quit()
        }
        self.popoverMenuController?.onNavigate = { [weak self] direction in
            switch direction {
            case .next: self?.menuViewModel.selectNext()
            case .previous: self?.menuViewModel.selectPrevious()
            }
        }
        self.popoverMenuController?.onSelectIndex = { [weak self] index in
            self?.menuViewModel.selectProvider(atIndex: index)
        }
    }
}
