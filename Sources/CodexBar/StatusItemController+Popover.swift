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
    /// dev 辅助：环境变量 CODEXBAR_FORCE_POPOVER=0/1 可覆盖设置值，
    /// 用于同机双实例并排对比新旧菜单（两实例共享 UserDefaults 域，只能靠 env 区分）。
    var usePopoverMenu: Bool {
        if let forced = ProcessInfo.processInfo.environment["CODEXBAR_FORCE_POPOVER"] {
            return forced == "1"
        }
        return self.settings.usePopoverMenu
    }

    /// 合并模式下安装 popover：清掉 statusItem.menu，懒创建 PopoverMenuController 并接线快捷键回调，
    /// 再把状态项按钮点击（含右键）路由到 handleStatusItemClick。仅在 usePopoverMenu 开启时调用。
    func attachMergedPopover() {
        self.statusItem.menu = nil
        if self.popoverMenuController == nil {
            let vm = self.menuViewModel
            self.popoverMenuController = self.makePopoverController(
                viewModel: vm,
                makeOverviewRows: { [weak self] in self?.popoverOverviewRows() ?? [] },
                makeOverviewChart: { [weak self] row in
                    self?.popoverOverviewChart(for: row.provider, model: row.model)
                })
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

    /// NSMenu 路径兜底：从 popover 模式切回时清掉合并与 per-provider statusItem 按钮上的残留 target/action。
    /// 在两个 attachMenus 的 NSMenu 分支开头调用。
    func clearPopoverButtonActions() {
        self.statusItem.button?.target = nil
        self.statusItem.button?.action = nil
        for item in self.statusItems.values {
            item.button?.target = nil
            item.button?.action = nil
        }
    }

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
                item.menu = nil // 清掉残留 NSMenu
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

    // MARK: - Popover controller 工厂（合并模式和 per-provider 复用）

    /// 构造一个 PopoverMenuController，注入所有 make* 闭包。
    /// vm 参数化：不同 controller 的闭包各自捕获自己的 vm，selection 语义自动正确。
    /// - makeOverviewRows：合并模式传 { self.popoverOverviewRows() }；per-provider 传 { [] }。
    /// - makeOverviewChart：合并模式传真实实现；per-provider 传 { _ in nil }
    ///   （PopoverRootView 要求 non-optional 闭包，单 provider 无 overview chart）。
    private func makePopoverController(
        viewModel vm: MenuViewModel,
        makeOverviewRows: @escaping () -> [PopoverOverviewRow],
        makeOverviewChart: @escaping (PopoverOverviewRow) -> PopoverChartKind?)
        -> PopoverMenuController<PopoverRootView>
    {
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
                    let provider = self.popoverActionProvider(for: vm)
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
                onAction: { [weak self] action in
                    guard let self else { return }
                    // dashboard/statusPage/changelog 等动作不携带 provider payload，
                    // 其 selector 经 lastMenuProvider 解析目标——与 NSMenu menuWillOpen
                    // 写入该字段的语义对齐，分发前先写入当前面板的 provider 上下文。
                    self.lastMenuProvider = self.popoverActionProvider(for: vm)
                    self.performMenuAction(action)
                },
                actionSubtitle: { [weak self] action in
                    guard let self else { return nil }
                    switch action {
                    case let .switchAccount(provider): return self.switchAccountSubtitle(for: provider)
                    case .addCodexAccount: return self.codexAddAccountSubtitle()
                    default: return nil
                    }
                },
                onBuyCredits: { [weak self] in
                    guard let self else { return }
                    self.lastMenuProvider = self.popoverActionProvider(for: vm)
                    self.openCreditsPurchase()
                    // 全关（含合并与全部 per-provider popover）：此闭包被两种模式复用
                    self.closeAllProviderPopovers()
                },
                switcherIcon: { [weak self] provider in
                    (self?.settings.switcherShowsIcons == true)
                        ? self?.popoverSwitcherIcon(for: provider)
                        : nil
                },
                switcherIndicator: { [weak self] provider in
                    guard let self else { return nil }
                    guard let remainingPercent = self.switcherWeeklyRemaining(for: provider) else { return nil }
                    let fraction = max(0, min(1, remainingPercent / 100))
                    let brandColor = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
                    let nsColor = NSColor(
                        deviceRed: brandColor.red,
                        green: brandColor.green,
                        blue: brandColor.blue,
                        alpha: 1)
                    return (fraction: fraction, color: nsColor)
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

    // MARK: - popover 动作分发

    /// Resolve the provider context used by popover actions.
    /// Provider tabs target themselves; Overview preserves the saved provider before falling back.
    func popoverActionProvider(for vm: MenuViewModel) -> UsageProvider {
        if case let .provider(provider) = vm.selection { return provider }
        let enabled = vm.providers
        if let selected = self.selectedMenuProvider, enabled.contains(selected) {
            return selected
        }
        return enabled.first(where: { self.store.isProviderAvailable($0) })
            ?? enabled.first
            ?? .codex
    }

    /// 统一构造一个临时 NSMenuItem 传递 representedObject，再对无参/带参 selector 分别分发。
    /// quit 不关闭 popover（应用即将退出）；其余动作执行后关闭。
    func performMenuAction(_ action: MenuDescriptor.MenuAction) {
        self.performLegacyMenuAction(action)
        if action != .quit {
            // 与 NSMenu 选中动作后菜单关闭对齐：合并与全部 per-provider popover 一并关闭，
            // 避免 split 模式下动作执行后面板滞留。
            self.closeAllProviderPopovers()
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
            plan.sectioned = self.buildSectionedCard(model: model, provider: provider)
            // 拆段模式下顶层 showBuyCredits 由 sectioned.showBuyCredits 接管，避免重复渲染
            if plan.sectioned != nil {
                plan.showBuyCredits = false
            } else {
                plan.showBuyCredits = self.popoverCanShowBuyCredits(for: provider)
            }
        } else {
            plan.emptyText = "Loading…"
        }
        plan.storageText = self.store.storageFootprintText(for: provider)
        return plan
    }

    /// 构造拆段渲染计划（对齐 NSMenu addMenuCardSections 的判定与各段 chevron 条件）。
    /// 仅当 openAIWebContext.hasOpenAIWebMenuItems 或 hasOpenAIAPIUsageSubmenu 为 true 时返回非 nil。
    private func buildSectionedCard(
        model: UsageMenuCardView.Model,
        provider: UsageProvider)
        -> PopoverCardPlan.SectionedCard?
    {
        // ── 与 NSMenu addMenuCards:677-693 一致的拆段触发判定 ──
        // openAIWebContext 中 showAllAccounts=false（单卡路径无 stacked）
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .liveCard)
        let hasUsageBreakdown = codexProjection?.hasUsageBreakdown == true
        let hasCreditsHistory = codexProjection?.hasCreditsHistory == true
        let hasCostHistory = self.settings.isCostUsageEffectivelyEnabled(for: provider) &&
            (self.store.tokenSnapshot(for: provider)?.daily.isEmpty == false)
        let hasOpenAIWebMenuItems = hasCreditsHistory || hasUsageBreakdown || hasCostHistory
        // hasOpenAIAPIUsageSubmenu：provider == .openai && costHistory daily 非空（见 Menu.swift:1573-1575）
        let hasOpenAIAPIUsageSubmenu = provider == .openai &&
            self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false

        guard hasOpenAIWebMenuItems || hasOpenAIAPIUsageSubmenu else { return nil }

        // ── 段存在性 ──
        let hasUsageBlock = model.hasUsageContent
        let hasCredits = model.creditsText != nil
        let hasExtraUsage = model.providerCost != nil
        let hasCost = model.tokenUsage != nil
        let storageText = self.store.storageFootprintText(for: provider)
        let hasStorage = storageText != nil
        let canShowBuyCredits = self.settings.showOptionalCreditsAndExtraUsage &&
            codexProjection?.canShowBuyCredits == true

        // ── usageChart：对齐 makeUsageSubmenu（Menu.swift:1471-1487）──
        let usageChart: PopoverChartKind?
        if hasUsageBreakdown {
            usageChart = .usageBreakdown
        } else if provider == .openai {
            // openai → API Usage submenu（= costHistory）
            usageChart = hasOpenAIAPIUsageSubmenu ? .costHistory(provider) : nil
        } else if provider == .zai {
            let snapshot = self.store.snapshot(for: provider)
            usageChart = PopoverChartKind.isZaiDetailsAvailable(snapshot: snapshot)
                ? .zaiDetails(provider)
                : nil
        } else {
            usageChart = nil
        }

        // ── storageChart ──
        let storageChart: PopoverChartKind? =
            self.store.storageFootprint(for: provider)?.components.isEmpty == false
                ? .storageBreakdown(provider)
                : nil

        // ── creditsChart ──
        let creditsChart: PopoverChartKind? = hasCreditsHistory ? .creditsHistory : nil

        // ── extraUsageChart（Extra Usage 段用 OpenAI API usage submenu）──
        let extraUsageChart: PopoverChartKind? =
            provider == .openai && hasOpenAIAPIUsageSubmenu ? .costHistory(provider) : nil

        // ── costChart ──
        let costChart: PopoverChartKind? = hasCostHistory ? .costHistory(provider) : nil

        return PopoverCardPlan.SectionedCard(
            model: model,
            hasUsageBlock: hasUsageBlock,
            hasCredits: hasCredits,
            hasExtraUsage: hasExtraUsage,
            hasCost: hasCost,
            hasStorage: hasStorage,
            storageText: storageText,
            usageChart: usageChart,
            storageChart: storageChart,
            creditsChart: creditsChart,
            showBuyCredits: canShowBuyCredits,
            extraUsageChart: extraUsageChart,
            costChart: costChart)
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

    /// 该 provider 卡片下方应显示的图表下钻入口。
    /// 对齐原版 NSMenu：单 provider 卡片下方独立入口行**只有** usageHistory 与 zaiHourly。
    /// 其余图表（usageBreakdown/creditsHistory/costHistory/storageBreakdown/zaiDetails）
    /// 经由拆段模式的段 chevron 进入，不作为独立入口行重复显示。
    /// 整卡模式（非拆段 provider）同样只显示这两个入口，对齐原版整卡 provider 语义。
    func popoverChartEntries(for provider: UsageProvider) -> [PopoverChartKind] {
        var entries: [PopoverChartKind] = []

        // ── usageHistory（Subscription Utilization）──
        let hasUsageHistory = self.store.supportsPlanUtilizationHistory(for: provider) &&
            !self.store.shouldHidePlanUtilizationMenuItem(for: provider)
        if hasUsageHistory {
            entries.append(.usageHistory(provider))
        }

        // ── zaiHourly（Hourly Usage，仅 zai）──
        let hasZaiHourly = provider == .zai &&
            self.store.snapshot(for: provider)?.zaiUsage?.modelUsage != nil
        if hasZaiHourly {
            entries.append(.zaiHourly(provider))
        }

        return entries
    }

    /// Overview 行的下钻图表（无则 nil），对齐 makeOverviewRowSubmenu 逻辑：
    ///   openai+hasAPIUsage → .costHistory；zai+hasZaiDetails → .zaiDetails；
    ///   tokenUsage != nil → .costHistory；usageHistory 可用 → .usageHistory；
    ///   storage 非空 → .storageBreakdown；否则 nil。
    func popoverOverviewChart(for provider: UsageProvider, model: UsageMenuCardView.Model) -> PopoverChartKind? {
        // openai：API Usage submenu（=costHistory）
        if provider == .openai,
           self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false
        {
            return .costHistory(provider)
        }
        // zai：有 usageDetails 时展示 MCP 明细；否则回退后续逻辑
        if provider == .zai {
            let snapshot = self.store.snapshot(for: provider)
            if PopoverChartKind.isZaiDetailsAvailable(snapshot: snapshot) {
                return .zaiDetails(provider)
            }
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

        case let .zaiDetails(provider):
            guard provider == .zai,
                  let snapshot = self.store.snapshot(for: provider),
                  let timeLimit = snapshot.zaiUsage?.timeLimit,
                  !timeLimit.usageDetails.isEmpty else { return nil }
            return AnyView(ZaiMCPDetailsView(
                timeLimit: timeLimit,
                resetTimeDisplayStyle: self.settings.resetTimeDisplayStyle,
                width: width))
        }
    }

    // MARK: - 面板可见性（子任务 A，MP-23）

    /// popover-aware 版本：popover 路径下通过 MenuViewModel.isVisible 判断；
    /// NSMenu 路径下沿用旧 openMenus 字典。
    /// 两处 guard !self.isMergedMenuOpen（updateIcons 686、refreshMenusForLoginStateChange 787）自动获益。
    var isMergedMenuOpen: Bool {
        if self.usePopoverMenu {
            if self.menuViewModel.isVisible { return true }
            return self.providerMenuViewModels.values.contains { $0.isVisible }
        }
        guard let mergedMenu else { return false }
        return self.openMenus[ObjectIdentifier(mergedMenu)] != nil
    }

    // MARK: - 打开时刷新调度（子任务 B，MP-03/29）

    /// popover 打开时的刷新调度：storage footprints + stale/missing provider 的后台刷新。
    /// NSMenu 因模态须 defer 到关闭后；popover 非模态可在打开期间直接刷新（SwiftUI 自动更新 UI）。
    func schedulePopoverOpenRefresh(providers: [UsageProvider]) {
        if self.settings.providerStorageFootprintsEnabled {
            self.store.refreshStorageFootprintsForOverview()
        }
        let stale = providers.filter { self.store.isStale(provider: $0) || self.store.snapshot(for: $0) == nil }
        guard !stale.isEmpty, !self.store.isRefreshing else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.2)) // 与 NSMenu menuOpenRefreshDelay 一致，避免打开瞬间抢资源
            guard let self else { return }
            guard self.isMergedMenuOpen else { return } // 已关则不刷（沿用 NSMenu"还开着才刷"语义）
            guard !self.store.isRefreshing else { return }
            for provider in stale
                where self.store.isStale(provider: provider) || self.store.snapshot(for: provider) == nil
            {
                await self.store.refreshProvider(provider)
            }
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
