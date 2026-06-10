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
                    },
                    switcherIcon: { [weak self] provider in
                        (self?.settings.switcherShowsIcons == true)
                            ? self?.popoverSwitcherIcon(for: provider)
                            : nil
                    })
            }
            self.wirePopoverShortcutCallbacks()
            // onSelectionChanged 必须在 refreshPopoverViewModelInputs() 之前注册，
            // 确保首次 restore（select(restored)）触发时回调已就位，不会静默丢失写回 settings 的副作用。
            vm.onSelectionChanged = { [weak self] selection in
                guard let self else { return }
                switch selection {
                case .overview:
                    self.settings.mergedMenuLastSelectedWasOverview = true
                case let .provider(p):
                    self.settings.selectedMenuProvider = p
                    self.settings.mergedMenuLastSelectedWasOverview = false
                }
            }
            // 在控制器创建与回调注册完成后再 refresh，保证首次 selection restore 的写回不丢失。
            self.refreshPopoverViewModelInputs()
        }
        self.statusItem.button?.target = self
        self.statusItem.button?.action = #selector(self.handleStatusItemClick(_:))
        // 右键也触发 action，使右键可弹出 popover
        self.statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - ViewModel 输入刷新

    /// 刷新 menuViewModel 的 providers 与 includesOverview，并从 settings 恢复上次 selection。
    /// 在 attach、click、shortcut 打开 popover 时统一调用，避免三处重复。
    func refreshPopoverViewModelInputs() {
        let enabledProviders = self.store.enabledProvidersForDisplay()
        self.menuViewModel.providers = enabledProviders
        let overviewProviders = self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit)
        // 与 NSMenu 对齐：只有多个 provider 时才显示切换器（含 overview tab）；
        // 单 provider 时即使 overviewProviders 非空也不展示，避免多余的切换器。
        self.menuViewModel.includesOverview = !overviewProviders.isEmpty && enabledProviders.count > 1

        // 从 settings 恢复上次选中项（等价于 NSMenu 的 resolvedSwitcherSelection 逻辑）：
        //   includesOverview && mergedMenuLastSelectedWasOverview → .overview
        //   否则 → .provider(selectedMenuProvider if enabled, else first available, else .codex)
        // 此逻辑同时覆盖"overview tab 已移除但仍选中 overview"的纠正。
        // 恢复时触发 onSelectionChanged 写回 settings 是幂等的，无需特殊处理。
        let restoredProvider: UsageProvider = {
            if let selected = self.settings.selectedMenuProvider,
               enabledProviders.contains(selected)
            {
                return selected
            }
            return enabledProviders.first(where: { self.store.isProviderAvailable($0) })
                ?? enabledProviders.first
                ?? .codex
        }()
        let restored: ProviderSwitcherSelection =
            (self.menuViewModel.includesOverview && self.settings.mergedMenuLastSelectedWasOverview)
            ? .overview
            : .provider(restoredProvider)
        if self.menuViewModel.selection != restored {
            self.menuViewModel.select(restored)
        }
    }

    /// 取 provider 品牌图标，供 switcherIcon 注入闭包使用。
    /// 直接复用 ProviderBrandIcon（internal），不依赖 private switcherIcon(for:)。
    func popoverSwitcherIcon(for provider: UsageProvider) -> NSImage? {
        ProviderBrandIcon.image(for: provider)
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
    /// 始终构造临时 NSMenuItem 并调用 perform(_:with:)：
    ///   - 带 payload 的方法：representedObject 设为 payload，方法正常读取。
    ///   - 无 payload（无参签名）的方法：representedObject 为 nil，ObjC 消息派发下多余实参被忽略，安全。
    /// 消除了两路分支与 addCodexAccount（payload=nil 但方法带 NSMenuItem 参数）的 ABI 歧义。
    private func performLegacyMenuAction(_ action: MenuDescriptor.MenuAction) {
        let (sel, payload) = self.selector(for: action)
        let item = NSMenuItem()
        item.representedObject = payload
        _ = self.perform(sel, with: item)
    }

    // MARK: - 卡片计划（复刻 addMenuCards 分流逻辑，纯数据）

    /// 构造当前 provider 的卡片渲染计划，供 PopoverRootView 纯渲染消费。
    /// 分流次序与 addMenuCards 保持一致：
    ///   1. Codex 多账户 stacked → 按 workspace section 展开 cards
    ///   2. Token 多账户 stacked → snapshot compactMap
    ///   3. Kilo 多 scope → kiloScopeSnapshots compactMap
    ///   4. 单卡片 / 占位
    ///   + storageText
    ///   stacked 路径强制 showBuyCredits = false（与 NSMenu addStackedMenuCards 一致，
    ///   NSMenu stacked 分支 return false 早退，不经过单卡片 canShowBuyCredits 路径）；
    ///   仅单卡片路径（分支 4）保留 popoverCanShowBuyCredits 计算。
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
            // stacked 路径：cards 为空时 fallback 到单卡片，与 NSMenu addStackedCodexMenuCards:49-56 对齐
            self.applyStackedFallback(to: &plan, provider: provider)
            plan.storageText = self.store.storageFootprintText(for: provider)
            // stacked 路径不显示 Buy Credits，与 NSMenu stacked 路径 return false 早退一致
            plan.showBuyCredits = false
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
            // stacked 路径：cards 为空时 fallback 到单卡片，与 NSMenu addStackedMenuCards:716-722 对齐
            self.applyStackedFallback(to: &plan, provider: provider)
            plan.storageText = self.store.storageFootprintText(for: provider)
            // stacked 路径不显示 Buy Credits，与 NSMenu stacked 路径 return false 早退一致
            plan.showBuyCredits = false
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
            // stacked 路径：cards 为空时 fallback 到单卡片，与 NSMenu addStackedMenuCards:716-722 对齐
            self.applyStackedFallback(to: &plan, provider: provider)
            plan.storageText = self.store.storageFootprintText(for: provider)
            // stacked 路径不显示 Buy Credits，与 NSMenu stacked 路径 return false 早退一致
            plan.showBuyCredits = false
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

    /// stacked 路径空 cards 时的 fallback：尝试构造单卡片，否则显示"Loading…"。
    /// 与 NSMenu addStackedCodexMenuCards:49-56 / addStackedMenuCards:716-722 语义对齐。
    private func applyStackedFallback(to plan: inout PopoverCardPlan, provider: UsageProvider) {
        guard plan.cards.isEmpty else { return }
        if let model = self.menuCardModel(for: provider) {
            plan.cards = [PopoverCardPlan.Card(id: "single", model: model, workspaceHeader: nil)]
        } else {
            plan.emptyText = "Loading…"
        }
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

    // MARK: - 图表下钻入口（Task 3.1）

    /// 该 provider 卡片下方应显示的图表下钻入口，顺序对齐 NSMenu：
    ///   usage(breakdown/openAIAPI) → credits → cost → usageHistory → storage → zaiHourly。
    func popoverChartEntries(for provider: UsageProvider) -> [PopoverChartKind] {
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .liveCard)
        let hasUsageBreakdown = codexProjection?.hasUsageBreakdown == true
        let hasCreditsHistory = codexProjection?.hasCreditsHistory == true
        // cost：tokenSnapshotForCostHistorySubmenu 与 appendCostHistoryChartItem 完全对齐
        let tokenSnap = self.tokenSnapshotForCostHistorySubmenu(provider: provider)
        let hasCostHistory = self.settings.isCostUsageEffectivelyEnabled(for: provider) &&
            tokenSnap?.daily.isEmpty == false
        let hasUsageHistory = self.store.supportsPlanUtilizationHistory(for: provider) &&
            !self.store.shouldHidePlanUtilizationMenuItem(for: provider)
        let hasStorageBreakdown = self.store.storageFootprint(for: provider)?.components.isEmpty == false
        let hasZaiHourly = provider == .zai &&
            self.store.snapshot(for: provider)?.zaiUsage?.modelUsage != nil

        var entries: [PopoverChartKind] = []

        // ── usage ──
        // 与 makeUsageSubmenu 对齐：hasUsageBreakdown → .usageBreakdown；
        //   否则 openai + hasOpenAIAPIUsageSubmenu → .costHistory(openai)（即 "API Usage" submenu）。
        if hasUsageBreakdown {
            entries.append(.usageBreakdown)
        } else if provider == .openai,
                  self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false
        {
            // openAI "API Usage" 子菜单等价于 costHistory；在此插入，后面 cost 入口去重跳过
            entries.append(.costHistory(provider))
        }

        // ── credits ──
        if hasCreditsHistory {
            entries.append(.creditsHistory)
        }

        // ── cost（去重：usage 入口若已插入 costHistory(provider) 则跳过）──
        if hasCostHistory, !entries.contains(.costHistory(provider)) {
            entries.append(.costHistory(provider))
        }

        // ── usageHistory ──
        if hasUsageHistory {
            entries.append(.usageHistory(provider))
        }

        // ── storage ──
        if hasStorageBreakdown {
            entries.append(.storageBreakdown(provider))
        }

        // ── zaiHourly ──
        if hasZaiHourly {
            entries.append(.zaiHourly(provider))
        }

        return entries
    }

    /// Overview 行的下钻图表（无则 nil），对齐 makeOverviewRowSubmenu 逻辑：
    ///   openai+hasAPIUsage → .costHistory；zai → nil（详情菜单阶段跳过）；
    ///   tokenUsage != nil → .costHistory；usageHistory 可用 → .usageHistory；
    ///   storage 非空 → .storageBreakdown；否则 nil。
    func popoverOverviewChart(for provider: UsageProvider, model: UsageMenuCardView.Model) -> PopoverChartKind? {
        // openai：API Usage submenu（=costHistory）
        if provider == .openai,
           self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false
        {
            return .costHistory(provider)
        }
        // zai：详情菜单本阶段跳过
        if provider == .zai {
            return nil
        }
        // tokenUsage 不为 nil → costHistory
        if model.tokenUsage != nil,
           self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false
        {
            return .costHistory(provider)
        }
        // usageHistory
        if self.store.supportsPlanUtilizationHistory(for: provider),
           !self.store.shouldHidePlanUtilizationMenuItem(for: provider)
        {
            return .usageHistory(provider)
        }
        // storageBreakdown
        if self.store.storageFootprint(for: provider)?.components.isEmpty == false {
            return .storageBreakdown(provider)
        }
        return nil
    }

    /// 懒构造图表视图；数据缺失返回 nil。width 为图表渲染宽度。
    /// 数据获取与 +HostedSubmenus.swift 对应 append* 方法完全一致。
    @MainActor
    func popoverChartView(for kind: PopoverChartKind, width: CGFloat) -> AnyView? {
        switch kind {
        case .usageBreakdown:
            let breakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
                from: self.store.openAIDashboard?.usageBreakdown ?? [])
            guard !breakdown.isEmpty else { return nil }
            return AnyView(UsageBreakdownChartMenuView(breakdown: breakdown, width: width))

        case .creditsHistory:
            let breakdown = self.store.openAIDashboard?.dailyBreakdown ?? []
            guard !breakdown.isEmpty else { return nil }
            return AnyView(CreditsHistoryChartMenuView(breakdown: breakdown, width: width))

        case let .costHistory(provider):
            guard let tokenSnapshot = self.tokenSnapshotForCostHistorySubmenu(provider: provider) else { return nil }
            guard !tokenSnapshot.daily.isEmpty else { return nil }
            return AnyView(CostHistoryChartMenuView(
                provider: provider,
                daily: tokenSnapshot.daily,
                totalCostUSD: tokenSnapshot.last30DaysCostUSD,
                currencyCode: tokenSnapshot.currencyCode,
                historyDays: tokenSnapshot.historyDays,
                windowLabel: tokenSnapshot.historyLabel,
                width: width))

        case let .usageHistory(provider):
            let histories = self.store.planUtilizationHistory(for: provider)
            let snapshot = self.store.snapshot(for: provider)
            return AnyView(PlanUtilizationHistoryChartMenuView(
                provider: provider,
                histories: histories,
                snapshot: snapshot,
                width: width))

        case let .storageBreakdown(provider):
            guard let footprint = self.store.storageFootprint(for: provider),
                  !footprint.components.isEmpty else { return nil }
            let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
            let maxHeight = min(620, max(360, floor(visibleHeight * 0.72)))
            return AnyView(StorageBreakdownMenuView(footprint: footprint, width: width, maxHeight: maxHeight))

        case let .zaiHourly(provider):
            guard provider == .zai,
                  let snapshot = self.store.snapshot(for: provider),
                  let modelUsage = snapshot.zaiUsage?.modelUsage else { return nil }
            return AnyView(ZaiHourlyUsageChartMenuView(modelUsage: modelUsage, width: width))
        }
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
