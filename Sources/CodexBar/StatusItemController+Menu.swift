import AppKit
import CodexBarCore
import Observation
import QuartzCore
import SwiftUI

// MARK: - NSMenu construction

extension StatusItemController {
    static let menuCardBaseWidth: CGFloat = 310
    private static let maxOverviewProviders = SettingsStore.mergedOverviewProviderLimit
    private static let overviewRowIdentifierPrefix = "overviewRow-"
    private static let defaultMenuOpenRefreshDelay: Duration = .seconds(1.2)
    #if DEBUG
    private static var menuOpenRefreshDelayForTesting: Duration = .seconds(1.2)
    static func setMenuOpenRefreshDelayForTesting(_ delay: Duration) {
        self.menuOpenRefreshDelayForTesting = delay
    }

    static func resetMenuOpenRefreshDelayForTesting() {
        self.menuOpenRefreshDelayForTesting = self.defaultMenuOpenRefreshDelay
    }
    #endif

    private static var menuOpenRefreshDelay: Duration {
        #if DEBUG
        menuOpenRefreshDelayForTesting
        #else
        defaultMenuOpenRefreshDelay
        #endif
    }

    static let usageBreakdownChartID = "usageBreakdownChart"
    static let creditsHistoryChartID = "creditsHistoryChart"
    static let costHistoryChartID = "costHistoryChart"
    static let usageHistoryChartID = "usageHistoryChart"
    static let storageBreakdownID = "storageBreakdown"

    private func shortcut(for action: MenuDescriptor.MenuAction) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        switch action {
        case .refresh:
            ("r", [.command])
        case .settings:
            (",", [.command])
        case .quit:
            ("q", [.command])
        default:
            nil
        }
    }

    private func menuCardWidth(
        for providers: [UsageProvider],
        sections: [MenuDescriptor.Section]) -> CGFloat
    {
        _ = providers
        let baselineWidth = Self.menuCardBaseWidth
        return max(baselineWidth, self.measuredStandardMenuWidth(for: sections, baseWidth: baselineWidth))
    }

    private func measuredStandardMenuWidth(for sections: [MenuDescriptor.Section], baseWidth: CGFloat) -> CGFloat {
        let measuringMenu = NSMenu()
        measuringMenu.autoenablesItems = false
        self.addActionableSections(sections, to: measuringMenu, width: baseWidth)
        return ceil(measuringMenu.size.width)
    }

    func makeMenu() -> NSMenu {
        guard self.shouldMergeIcons else {
            return self.makeMenu(for: nil)
        }
        return self.makeBaseMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        let menuOpenStartedAt = CACurrentMediaTime()
        defer {
            self.logMenuOperationDurationIfSlow(
                "menuWillOpen",
                startedAt: menuOpenStartedAt,
                menu: menu,
                provider: self.menuProvider(for: menu))
        }

        self.cancelDeferredMenuInteractionRefreshTask()
        self.cancelClosedMenuRebuild(menu)

        if self.isHostedSubviewMenu(menu) {
            self.hydrateHostedSubviewMenuIfNeeded(menu)
            self.refreshHostedSubviewHeights(in: menu)
            if self.isMenuRefreshEnabled, self.isOpenAIWebSubviewMenu(menu) {
                self.deferOpenAIDashboardRefreshUntilMenuCloses(reason: "submenu open")
            }
            if self.isMenuRefreshEnabled {
                // Intentionally skip open-menu tracking when refresh is disabled (tests).
                // If refresh is re-enabled while this menu stays open, it will not be backfilled until next open.
                self.openMenus[ObjectIdentifier(menu)] = menu
            }
            // Removed redundant async refresh - single pass is sufficient after initial layout
            return
        }

        var provider: UsageProvider?
        if self.shouldMergeIcons {
            let resolvedProvider = self.resolvedMenuProvider()
            self.lastMenuProvider = resolvedProvider ?? .codex
            provider = resolvedProvider
        } else {
            if let menuProvider = self.menuProviders[ObjectIdentifier(menu)] {
                self.lastMenuProvider = menuProvider
                provider = menuProvider
            } else if menu === self.fallbackMenu {
                self.lastMenuProvider = self.store.enabledProvidersForDisplay().first ?? .codex
                provider = nil
            } else {
                let resolved = self.store.enabledProvidersForDisplay().first ?? .codex
                self.lastMenuProvider = resolved
                provider = resolved
            }
        }

        if self.isMenuRefreshEnabled, (provider ?? self.lastMenuProvider) == .codex {
            self.deferOpenAIDashboardRefreshUntilMenuCloses(reason: "parent menu open")
        }

        self.refreshMenuForOpenIfNeeded(menu, provider: provider)
        if self.isMenuRefreshEnabled {
            // Intentionally skip open-menu tracking when refresh is disabled (tests).
            // If refresh is re-enabled while this menu stays open, it will not be backfilled until next open.
            self.openMenus[ObjectIdentifier(menu)] = menu
            self.installProviderSwitcherShortcutMonitorIfNeeded(for: menu)
            // Only schedule refresh after menu is registered as open - refreshNow is called async
            self.scheduleOpenMenuRefresh(for: menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        let wasHostedSubviewMenu = self.isHostedSubviewMenu(menu)
        self.forgetClosedMenu(menu)
        if wasHostedSubviewMenu {
            self.refreshOpenMenusAfterHostedSubviewClose()
        }
    }

    func forgetClosedMenu(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)

        if key == self.providerSwitcherShortcutMenuID {
            self.removeProviderSwitcherShortcutMonitor()
        }

        self.cancelClosedMenuRebuild(menu)
        self.openMenus.removeValue(forKey: key)
        self.menuRefreshTasks.removeValue(forKey: key)?.cancel()
        self.openMenuRebuildTasks.removeValue(forKey: key)?.cancel()
        self.openMenuRebuildTokens.removeValue(forKey: key)
        self.openMenuRebuildsClosingHostedSubviewMenus.remove(key)
        if let highlightedView = self.highlightedMenuItems.removeValue(forKey: key)?.view {
            (highlightedView as? MenuCardHighlighting)?.setHighlighted(false)
        }

        let isPersistentMenu = menu === self.mergedMenu ||
            menu === self.fallbackMenu ||
            self.providerMenus.values.contains { $0 === menu }
        if !isPersistentMenu {
            self.clearTransientMenuTrackingState(key)
        } else if self.menuNeedsRefresh(menu) {
            self.handleClosedPersistentMenuNeedingRefresh(menu)
        }
        self.parentMenuRebuildsDeferredDuringTracking.remove(key)
        self.scheduleDeferredMenuInteractionRefreshIfNeeded()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let key = ObjectIdentifier(menu)
        let previous = self.highlightedMenuItems[key]
        guard previous !== item else { return }

        if let previous {
            (previous.view as? MenuCardHighlighting)?.setHighlighted(false)
        }

        if let item, item.isEnabled {
            self.highlightedMenuItems[key] = item
            (item.view as? MenuCardHighlighting)?.setHighlighted(true)
        } else {
            self.highlightedMenuItems.removeValue(forKey: key)
        }
    }

    func populateMenu(_ menu: NSMenu, provider: UsageProvider?) {
        let populateStartedAt = CACurrentMediaTime()
        defer {
            self.logMenuOperationDurationIfSlow(
                "populateMenu",
                startedAt: populateStartedAt,
                menu: menu,
                provider: provider)
        }

        let enabledProviders = self.store.enabledProvidersForDisplay()
        let includesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)
        let switcherSelection = self.shouldMergeIcons && enabledProviders.count > 1
            ? self.resolvedSwitcherSelection(
                enabledProviders: enabledProviders,
                includesOverview: includesOverview)
            : nil
        let isOverviewSelected = switcherSelection == .overview
        let selectedProvider = if isOverviewSelected {
            self.resolvedMenuProvider(enabledProviders: enabledProviders)
        } else {
            switcherSelection?.provider ?? provider
        }
        let currentProvider = selectedProvider ?? enabledProviders.first ?? .codex
        let rawCodexAccountDisplay = isOverviewSelected ? nil : self.codexAccountMenuDisplay(for: currentProvider)
        let codexAccountDisplay = isOverviewSelected
            ? nil
            : self.stableCodexAccountMenuDisplay(
                rawCodexAccountDisplay,
                menu: menu,
                provider: currentProvider)
        let tokenAccountDisplay = isOverviewSelected ? nil : self.tokenAccountMenuDisplay(for: currentProvider)
        let showAllAccounts = (tokenAccountDisplay?.showAll ?? false) || (codexAccountDisplay?.showAll ?? false)
        let openAIContext = self.openAIWebContext(
            currentProvider: currentProvider,
            showAllAccounts: showAllAccounts)
        let descriptor = MenuDescriptor.build(
            provider: selectedProvider,
            store: self.store,
            settings: self.settings,
            account: self.account,
            managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
            updateReady: self.updater.updateStatus.isUpdateReady,
            includeContextualActions: !isOverviewSelected)
        let menuWidth = self.menuCardWidth(for: enabledProviders, sections: descriptor.sections)

        let hasTokenSwitcher = menu.items.contains { $0.view is TokenAccountSwitcherView }
        let hasCodexSwitcher = menu.items.contains { $0.view is CodexAccountSwitcherView }
        let switcherProvidersMatch = enabledProviders == self.lastSwitcherProviders
        let switcherUsageBarsShowUsedMatch = self.settings.usageBarsShowUsed == self.lastSwitcherUsageBarsShowUsed
        let switcherSelectionMatches = switcherSelection == self.lastMergedSwitcherSelection
        let switcherOverviewAvailabilityMatches = includesOverview == self.lastSwitcherIncludesOverview
        let menuLocalizationMatches = self.menuLocalizationSignature() == self.lastMenuLocalizationSignature
        let tokenSwitcherCompatible = tokenAccountDisplay == self.lastTokenAccountMenuDisplay &&
            ((tokenAccountDisplay?.showSwitcher == true && hasTokenSwitcher) ||
                (tokenAccountDisplay?.showSwitcher != true && !hasTokenSwitcher))
        let codexSwitcherCompatible = codexAccountDisplay == self.lastCodexAccountMenuDisplay &&
            ((codexAccountDisplay?.showSwitcher == true && hasCodexSwitcher) ||
                (codexAccountDisplay?.showSwitcher != true && !hasCodexSwitcher))
        let reusableRowWidthsMatch = self.reusableFixedWidthRows(in: menu).allSatisfy { item in
            guard let view = item.view else { return false }
            return abs(view.frame.width - menuWidth) <= 0.5
        }
        let providerSwitcherWidthMatches = (menu.items.first?.view as? ProviderSwitcherView).map { view in
            abs(view.frame.width - menuWidth) <= 0.5
        } ?? false
        let canSmartUpdate = self.shouldMergeIcons &&
            enabledProviders.count > 1 &&
            !isOverviewSelected &&
            switcherProvidersMatch &&
            switcherUsageBarsShowUsedMatch &&
            switcherSelectionMatches &&
            switcherOverviewAvailabilityMatches &&
            menuLocalizationMatches &&
            tokenSwitcherCompatible &&
            codexSwitcherCompatible &&
            reusableRowWidthsMatch &&
            !menu.items.isEmpty &&
            menu.items.first?.view is ProviderSwitcherView

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil {
            self.menuLogger.debug(
                "populateMenu(open): provider=\(String(describing: provider)) " +
                    "display=\(enabledProviders.map(\.rawValue)) " +
                    "available=\(self.store.enabledProviders().map(\.rawValue)) " +
                    "selection=\(String(describing: switcherSelection)) " +
                    "last=\(String(describing: self.lastMergedSwitcherSelection)) " +
                    "smart=\(canSmartUpdate)")
        }
        #endif

        if canSmartUpdate {
            self.updateMenuContentPreservingSwitcher(
                menu,
                context: MenuUpdateContext(
                    provider: selectedProvider,
                    currentProvider: currentProvider,
                    switcherSelection: switcherSelection ?? .provider(currentProvider),
                    menuWidth: menuWidth,
                    codexAccountDisplay: codexAccountDisplay,
                    tokenAccountDisplay: tokenAccountDisplay,
                    openAIContext: openAIContext,
                    descriptor: descriptor))
            return
        }

        let canPreserveProviderSwitcher = self.shouldMergeIcons &&
            enabledProviders.count > 1 &&
            switcherProvidersMatch &&
            switcherUsageBarsShowUsedMatch &&
            switcherOverviewAvailabilityMatches &&
            menuLocalizationMatches &&
            providerSwitcherWidthMatches &&
            !menu.items.isEmpty &&
            menu.items.first?.view is ProviderSwitcherView

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil {
            self.menuLogger.debug(
                "populateMenu(open): preserveSwitcher=\(canPreserveProviderSwitcher) " +
                    "widthMatch=\(providerSwitcherWidthMatches)")
        }
        #endif

        if canPreserveProviderSwitcher {
            self.updateMenuContentPreservingSwitcher(
                menu,
                context: MenuUpdateContext(
                    provider: selectedProvider,
                    currentProvider: currentProvider,
                    switcherSelection: switcherSelection ?? .provider(currentProvider),
                    menuWidth: menuWidth,
                    codexAccountDisplay: codexAccountDisplay,
                    tokenAccountDisplay: tokenAccountDisplay,
                    openAIContext: openAIContext,
                    descriptor: descriptor))
            return
        }

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil, menu.items.first?.view is ProviderSwitcherView {
            self.menuLogger.debug("populateMenu(open): rebuilding whole menu and replacing provider switcher")
        }
        #endif
        self.rebuildMenuContent(
            menu,
            context: MenuRebuildContext(
                enabledProviders: enabledProviders,
                includesOverview: includesOverview,
                switcherSelection: switcherSelection,
                currentProvider: currentProvider,
                selectedProvider: selectedProvider,
                menuWidth: menuWidth,
                codexAccountDisplay: codexAccountDisplay,
                tokenAccountDisplay: tokenAccountDisplay,
                openAIContext: openAIContext,
                descriptor: descriptor))
    }

    private func reusableFixedWidthRows(in menu: NSMenu) -> [NSMenuItem] {
        guard !menu.items.isEmpty else { return [] }

        var reusableRows: [NSMenuItem] = []
        var index = self.providerSwitcherContentStartIndex(in: menu)
        if index > 0 {
            reusableRows.append(menu.items[0])
        }
        if menu.items.count > index,
           menu.items[index].view is CodexAccountSwitcherView
        {
            reusableRows.append(menu.items[index])
            index += 2
        }
        if menu.items.count > index,
           menu.items[index].view is TokenAccountSwitcherView
        {
            reusableRows.append(menu.items[index])
        }
        return reusableRows
    }

    /// Smart update: rebuild everything below the provider switcher while keeping the switcher view intact.
    private struct MenuUpdateContext {
        let provider: UsageProvider?
        let currentProvider: UsageProvider
        let switcherSelection: ProviderSwitcherSelection
        let menuWidth: CGFloat
        let codexAccountDisplay: CodexAccountMenuDisplay?
        let tokenAccountDisplay: TokenAccountMenuDisplay?
        let openAIContext: OpenAIWebContext
        let descriptor: MenuDescriptor
    }

    /// Smart update: rebuild everything below the provider switcher while keeping the switcher view intact.
    private func updateMenuContentPreservingSwitcher(
        _ menu: NSMenu,
        context: MenuUpdateContext)
    {
        self.performMenuMutationWithoutAnimation {
            let contentStartIndex = self.providerSwitcherContentStartIndex(in: menu)
            if let switcherView = menu.items.first?.view as? ProviderSwitcherView {
                switcherView.updateSelection(context.switcherSelection)
                switcherView.updateQuotaIndicators()
            }
            while menu.items.count > contentStartIndex {
                menu.removeItem(at: contentStartIndex)
            }

            let enabledProviders = self.store.enabledProvidersForDisplay()
            self.rememberMergedSwitcherState(enabledProviders, context.switcherSelection)
            self.addCodexAccountSwitcherIfNeeded(
                to: menu,
                display: context.codexAccountDisplay,
                width: context.menuWidth)
            self.lastCodexAccountMenuDisplay = context.codexAccountDisplay
            self.addTokenAccountSwitcherIfNeeded(
                to: menu,
                display: context.tokenAccountDisplay,
                width: context.menuWidth)
            self.lastTokenAccountMenuDisplay = context.tokenAccountDisplay

            let menuContext = MenuCardContext(
                currentProvider: context.currentProvider,
                selectedProvider: context.provider,
                menuWidth: context.menuWidth,
                codexAccountDisplay: context.codexAccountDisplay,
                tokenAccountDisplay: context.tokenAccountDisplay,
                openAIContext: context.openAIContext)
            self.addPrimaryMenuContent(to: menu, context: menuContext, switcherSelection: context.switcherSelection)
            self.addActionableSections(context.descriptor.sections, to: menu, width: context.menuWidth)
        }
    }

    private func rebuildMenuContent(
        _ menu: NSMenu,
        context: MenuRebuildContext)
    {
        self.performMenuMutationWithoutAnimation {
            menu.removeAllItems()
            self.addProviderSwitcherIfNeeded(
                to: menu,
                enabledProviders: context.enabledProviders,
                includesOverview: context.includesOverview,
                selection: context.switcherSelection ?? .provider(context.currentProvider),
                width: context.menuWidth)
            // Track which providers the switcher was built with for smart update detection
            if self.shouldMergeIcons, context.enabledProviders.count > 1 {
                self.rememberMergedSwitcherState(
                    context.enabledProviders,
                    context.switcherSelection,
                    context.includesOverview)
            }
            self.addCodexAccountSwitcherIfNeeded(
                to: menu,
                display: context.codexAccountDisplay,
                width: context.menuWidth)
            self.lastCodexAccountMenuDisplay = context.codexAccountDisplay
            self.addTokenAccountSwitcherIfNeeded(
                to: menu,
                display: context.tokenAccountDisplay,
                width: context.menuWidth)
            self.lastTokenAccountMenuDisplay = context.tokenAccountDisplay
            let menuContext = MenuCardContext(
                currentProvider: context.currentProvider,
                selectedProvider: context.selectedProvider,
                menuWidth: context.menuWidth,
                codexAccountDisplay: context.codexAccountDisplay,
                tokenAccountDisplay: context.tokenAccountDisplay,
                openAIContext: context.openAIContext)
            self.addPrimaryMenuContent(
                to: menu,
                context: menuContext,
                switcherSelection: context.switcherSelection ?? .provider(context.currentProvider))
            self.addActionableSections(context.descriptor.sections, to: menu, width: context.menuWidth)
        }
    }

    private func openAIWebContext(
        currentProvider: UsageProvider,
        showAllAccounts: Bool) -> OpenAIWebContext
    {
        let codexProjection = self.store.codexConsumerProjectionIfNeeded(
            for: currentProvider,
            surface: .liveCard)
        let hasCreditsHistory = codexProjection?.hasCreditsHistory == true
        let hasUsageBreakdown = codexProjection?.hasUsageBreakdown == true
        let hasCostHistory = self.settings.isCostUsageEffectivelyEnabled(for: currentProvider) &&
            (self.store.tokenSnapshot(for: currentProvider)?.daily.isEmpty == false)
        let canShowBuyCredits = self.settings.showOptionalCreditsAndExtraUsage &&
            codexProjection?.canShowBuyCredits == true
        let hasOpenAIWebMenuItems = !showAllAccounts &&
            (hasCreditsHistory || hasUsageBreakdown || hasCostHistory)
        return OpenAIWebContext(
            hasUsageBreakdown: hasUsageBreakdown,
            hasCreditsHistory: hasCreditsHistory,
            hasCostHistory: hasCostHistory,
            canShowBuyCredits: canShowBuyCredits,
            hasOpenAIWebMenuItems: hasOpenAIWebMenuItems)
    }

    private func addProviderSwitcherIfNeeded(
        to menu: NSMenu,
        enabledProviders: [UsageProvider],
        includesOverview: Bool,
        selection: ProviderSwitcherSelection,
        width: CGFloat)
    {
        guard self.shouldMergeIcons, enabledProviders.count > 1 else { return }
        let switcherItem = self.makeProviderSwitcherItem(
            providers: enabledProviders,
            includesOverview: includesOverview,
            selected: selection,
            menu: menu,
            width: width)
        menu.addItem(switcherItem)
        menu.addItem(.separator())
    }

    private func addTokenAccountSwitcherIfNeeded(to menu: NSMenu, display: TokenAccountMenuDisplay?, width: CGFloat) {
        guard let display, display.showSwitcher else { return }
        let switcherItem = self.makeTokenAccountSwitcherItem(display: display, menu: menu, width: width)
        menu.addItem(switcherItem)
        menu.addItem(.separator())
    }

    private func addCodexAccountSwitcherIfNeeded(to menu: NSMenu, display: CodexAccountMenuDisplay?, width: CGFloat) {
        guard let display, display.showSwitcher else { return }
        let switcherItem = self.makeCodexAccountSwitcherItem(display: display, menu: menu, width: width)
        menu.addItem(switcherItem)
        menu.addItem(.separator())
    }

    @discardableResult
    private func addOverviewRows(
        to menu: NSMenu,
        enabledProviders: [UsageProvider],
        menuWidth: CGFloat) -> Bool
    {
        let overviewProviders = self.settings.reconcileMergedOverviewSelectedProviders(
            activeProviders: enabledProviders)
        let rows: [(provider: UsageProvider, model: UsageMenuCardView.Model)] = overviewProviders
            .compactMap { provider in
                guard let model = self.menuCardModel(for: provider) else { return nil }
                guard !model.isOverviewErrorOnly else { return nil }
                return (provider: provider, model: model)
            }
        guard !rows.isEmpty else { return false }

        for (index, row) in rows.enumerated() {
            let identifier = "\(Self.overviewRowIdentifierPrefix)\(row.provider.rawValue)"
            let storageText = self.store.storageFootprintText(for: row.provider)
            let submenu = self.makeOverviewRowSubmenu(
                provider: row.provider,
                model: row.model,
                width: menuWidth)
            let item = self.makeMenuCardItem(
                OverviewMenuCardRowView(model: row.model, storageText: storageText, width: menuWidth),
                id: identifier,
                width: menuWidth,
                heightCacheScope: row.provider.rawValue,
                heightCacheFingerprint: row.model.heightFingerprint(
                    section: "overview",
                    additional: [UsageMenuCardView.Model.heightFingerprintField("storage", storageText)]),
                submenu: submenu,
                onClick: { [weak self, weak menu] in
                    guard let self, let menu else { return }
                    self.selectOverviewProvider(row.provider, menu: menu)
                })
            if submenu == nil {
                // Keep plain rows wired for keyboard activation and accessibility action paths.
                item.target = self
                item.action = #selector(self.selectOverviewProvider(_:))
            }
            menu.addItem(item)
            if index < rows.count - 1 {
                menu.addItem(.separator())
            }
        }
        return true
    }

    private func addOverviewEmptyState(to menu: NSMenu, enabledProviders: [UsageProvider]) {
        let resolvedProviders = self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: Self.maxOverviewProviders)
        let message = resolvedProviders.isEmpty
            ? L("No providers selected for Overview.")
            : L("No overview data available.")
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.representedObject = "overviewEmptyState"
        menu.addItem(item)
    }

    private func addMenuCards(to menu: NSMenu, context: MenuCardContext) -> Bool {
        if let codexAccountDisplay = context.codexAccountDisplay, codexAccountDisplay.showAll {
            self.addStackedCodexMenuCards(codexAccountDisplay, to: menu, context: context)
            return false
        }

        if let tokenAccountDisplay = context.tokenAccountDisplay, tokenAccountDisplay.showAll {
            let accountSnapshots = tokenAccountDisplay.snapshots
            let cards = accountSnapshots.isEmpty
                ? []
                : accountSnapshots.compactMap { accountSnapshot in
                    self.menuCardModel(
                        for: context.currentProvider,
                        snapshotOverride: accountSnapshot.snapshot,
                        errorOverride: accountSnapshot.error)
                }
            self.addStackedMenuCards(cards, to: menu, context: context)
            return false
        }

        if context.currentProvider == .kilo, self.store.kiloScopeSnapshots.count > 1 {
            let cards = self.store.kiloScopeSnapshots.compactMap { scope in
                self.menuCardModel(
                    for: .kilo,
                    snapshotOverride: scope.snapshot,
                    errorOverride: scope.errorMessage,
                    forceOverrideCard: scope.snapshot == nil)
            }
            self.addStackedMenuCards(cards, to: menu, context: context)
            return false
        }

        guard let model = self.menuCardModel(for: context.selectedProvider) else { return false }
        if context.openAIContext.hasOpenAIWebMenuItems || self
            .hasOpenAIAPIUsageSubmenu(provider: context.currentProvider)
        {
            let webItems = OpenAIWebMenuItems(
                hasUsageBreakdown: context.openAIContext.hasUsageBreakdown,
                hasCreditsHistory: context.openAIContext.hasCreditsHistory,
                hasCostHistory: context.openAIContext.hasCostHistory,
                canShowBuyCredits: context.openAIContext.canShowBuyCredits)
            self.addMenuCardSections(
                to: menu,
                model: model,
                provider: context.currentProvider,
                width: context.menuWidth,
                webItems: webItems)
            return true
        }

        menu.addItem(self.makeMenuCardItem(
            UsageMenuCardView(model: model, width: context.menuWidth),
            id: "menuCard",
            width: context.menuWidth,
            heightCacheScope: context.currentProvider.rawValue,
            heightCacheFingerprint: model.heightFingerprint(section: "card")))
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
        if context.openAIContext.canShowBuyCredits {
            menu.addItem(self.makeBuyCreditsItem())
        }
        menu.addItem(.separator())
        return false
    }

    private func addStackedMenuCards(
        _ cards: [UsageMenuCardView.Model],
        to menu: NSMenu,
        context: MenuCardContext)
    {
        if cards.isEmpty, let model = self.menuCardModel(for: context.selectedProvider) {
            menu.addItem(self.makeMenuCardItem(
                UsageMenuCardView(model: model, width: context.menuWidth),
                id: "menuCard",
                width: context.menuWidth,
                heightCacheScope: context.currentProvider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(section: "card")))
            menu.addItem(.separator())
        } else {
            for (index, model) in cards.enumerated() {
                menu.addItem(self.makeMenuCardItem(
                    UsageMenuCardView(model: model, width: context.menuWidth),
                    id: "menuCard-\(index)",
                    width: context.menuWidth,
                    heightCacheScope: "\(context.currentProvider.rawValue)-\(index)",
                    heightCacheFingerprint: model.heightFingerprint(section: "card")))
                if index < cards.count - 1 {
                    menu.addItem(.separator())
                }
            }
            if !cards.isEmpty {
                menu.addItem(.separator())
            }
        }
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
    }

    private func addOpenAIWebItemsIfNeeded(
        to menu: NSMenu,
        currentProvider: UsageProvider,
        context: OpenAIWebContext,
        addedOpenAIWebItems: Bool)
    {
        guard context.hasOpenAIWebMenuItems else { return }
        if !addedOpenAIWebItems {
            // Only show these when we actually have additional data.
            if context.hasUsageBreakdown {
                _ = self.addUsageBreakdownSubmenu(to: menu)
            }
            if context.hasCreditsHistory {
                _ = self.addCreditsHistorySubmenu(to: menu)
            }
            if context.hasCostHistory {
                _ = self.addCostHistorySubmenu(to: menu, provider: currentProvider)
            }
        }
        menu.addItem(.separator())
    }

    private func addPrimaryMenuContent(
        to menu: NSMenu,
        context: MenuCardContext,
        switcherSelection: ProviderSwitcherSelection)
    {
        self.store.refreshStorageFootprintsForOverview()
        if switcherSelection == .overview {
            let enabledProviders = self.store.enabledProvidersForDisplay()
            if self.addOverviewRows(
                to: menu,
                enabledProviders: enabledProviders,
                menuWidth: context.menuWidth)
            {
                menu.addItem(.separator())
            } else {
                self.addOverviewEmptyState(to: menu, enabledProviders: enabledProviders)
                menu.addItem(.separator())
            }
        } else {
            let addedOpenAIWebItems = self.addMenuCards(to: menu, context: context)
            self.addOpenAIWebItemsIfNeeded(
                to: menu,
                currentProvider: context.currentProvider,
                context: context.openAIContext,
                addedOpenAIWebItems: addedOpenAIWebItems)
            if self.addUsageHistoryMenuItemIfNeeded(
                to: menu,
                provider: context.currentProvider,
                width: context.menuWidth)
            {
                menu.addItem(.separator())
            }
            if self.addZaiHourlyUsageMenuItemIfNeeded(
                to: menu,
                provider: context.currentProvider,
                width: context.menuWidth)
            {
                menu.addItem(.separator())
            }
        }
    }

    private func addActionableSections(_ sections: [MenuDescriptor.Section], to menu: NSMenu, width: CGFloat) {
        let actionableSections = sections.filter { section in
            section.entries.contains { entry in
                if case .action = entry { return true }
                if case .submenu = entry { return true }
                return false
            }
        }
        for (index, section) in actionableSections.enumerated() {
            for entry in section.entries {
                switch entry {
                case let .text(text, style):
                    if style == .secondary {
                        menu.addItem(self.makeWrappedSecondaryTextItem(text: text, width: width))
                        continue
                    }
                    let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    if style == .headline {
                        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
                        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
                    } else if style == .secondary {
                        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
                        item.attributedTitle = NSAttributedString(
                            string: text,
                            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                    }
                    menu.addItem(item)
                case let .action(title, action):
                    let localizedTitle = L(title)
                    if self.usesPersistentMenuActionItem(for: action) {
                        menu.addItem(self.makePersistentMenuActionItem(
                            title: localizedTitle,
                            action: action,
                            menu: menu,
                            width: width))
                        continue
                    }

                    let (selector, represented) = self.selector(for: action)
                    let item = NSMenuItem(title: localizedTitle, action: selector, keyEquivalent: "")
                    item.target = self
                    item.representedObject = represented
                    if let shortcut = self.shortcut(for: action) {
                        item.keyEquivalent = shortcut.key
                        item.keyEquivalentModifierMask = shortcut.modifiers
                    }
                    if let iconName = action.systemImageName,
                       let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
                    {
                        image.isTemplate = true
                        image.size = NSSize(width: 16, height: 16)
                        item.image = image
                    }
                    if case let .switchAccount(targetProvider) = action,
                       let subtitle = self.switchAccountSubtitle(for: targetProvider)
                    {
                        item.isEnabled = false
                        self.applySubtitle(subtitle, to: item, title: localizedTitle)
                    } else if case .addCodexAccount = action,
                              let subtitle = self.codexAddAccountSubtitle()
                    {
                        item.isEnabled = false
                        self.applySubtitle(subtitle, to: item, title: localizedTitle)
                    }
                    menu.addItem(item)
                case let .submenu(title, systemImageName, submenuItems):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    if let systemImageName,
                       let image = NSImage(systemSymbolName: systemImageName, accessibilityDescription: nil)
                    {
                        image.isTemplate = true
                        image.size = NSSize(width: 16, height: 16)
                        item.image = image
                    }
                    let submenu = NSMenu(title: title)
                    submenu.autoenablesItems = false
                    for submenuItem in submenuItems {
                        let child = NSMenuItem(title: submenuItem.title, action: nil, keyEquivalent: "")
                        child.state = submenuItem.isChecked ? .on : .off
                        child.isEnabled = submenuItem.isEnabled
                        if let action = submenuItem.action {
                            let (selector, represented) = self.selector(for: action)
                            child.action = selector
                            child.target = self
                            child.representedObject = represented
                        }
                        submenu.addItem(child)
                    }
                    item.submenu = submenu
                    menu.addItem(item)
                case .divider:
                    menu.addItem(.separator())
                }
            }
            if index < actionableSections.count - 1 {
                menu.addItem(.separator())
            }
        }
    }

    private func makePersistentMenuActionItem(
        title: String,
        action: MenuDescriptor.MenuAction,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let shortcut = self.shortcut(for: action)
        let row = PersistentMenuActionItemView(
            title: title,
            systemImageName: self.persistentMenuActionSystemImageName(for: action),
            shortcutText: shortcut.map { self.shortcutLabel(for: $0) },
            width: width,
            onClick: { [weak self, weak menu] in
                self?.performPersistentMenuAction(action, in: menu)
            })

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: shortcut?.key ?? "")
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? NSEvent.ModifierFlags()
        item.isEnabled = true
        item.view = row
        item.toolTip = title
        if action != .refresh {
            let (selector, represented) = self.selector(for: action)
            item.action = selector
            item.target = self
            item.representedObject = represented
        }
        return item
    }

    private func shortcutLabel(for shortcut: (key: String, modifiers: NSEvent.ModifierFlags)) -> String {
        var label = ""
        if shortcut.modifiers.contains(.control) {
            label += "^"
        }
        if shortcut.modifiers.contains(.option) {
            label += "⌥"
        }
        if shortcut.modifiers.contains(.shift) {
            label += "⇧"
        }
        if shortcut.modifiers.contains(.command) {
            label += "⌘"
        }
        label += shortcut.key.uppercased()
        return label
    }

    private func makeWrappedSecondaryTextItem(text: String, width: CGFloat) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let view = self.makeWrappedSecondaryTextView(text: text)
        let height = self.menuTextItemHeight(for: view, width: width)
        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        item.view = view
        item.isEnabled = false
        item.toolTip = text
        return item
    }

    private func makeWrappedSecondaryTextView(text: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(wrappingLabelWithString: text)
        textField.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        textField.textColor = NSColor.secondaryLabelColor
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(textField)
        // macos-smell:disable MACOS005
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            textField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            textField.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
        ])

        return container
    }

    private func menuTextItemHeight(for view: NSView, width: CGFloat) -> CGFloat {
        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
        view.layoutSubtreeIfNeeded()
        return max(1, ceil(view.fittingSize.height))
    }

    func makeMenu(for provider: UsageProvider?) -> NSMenu {
        let menu = self.makeBaseMenu()
        if let provider {
            self.menuProviders[ObjectIdentifier(menu)] = provider
        }
        return menu
    }

    private func makeBaseMenu() -> NSMenu {
        let menu = StatusItemMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.persistentActionDelegate = self
        return menu
    }

    private func makeProviderSwitcherItem(
        providers: [UsageProvider],
        includesOverview: Bool,
        selected: ProviderSwitcherSelection,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = ProviderSwitcherView(
            providers: providers,
            selected: selected,
            includesOverview: includesOverview,
            width: width,
            showsIcons: self.settings.switcherShowsIcons,
            iconProvider: { [weak self] provider in
                self?.switcherIcon(for: provider) ?? NSImage()
            },
            weeklyRemainingProvider: { [weak self] provider in
                self?.switcherWeeklyRemaining(for: provider)
            },
            onSelect: { [weak self, weak menu] selection in
                guard let self, let menu else { return }
                let provider: UsageProvider?
                switch selection {
                case .overview:
                    self.settings.mergedMenuLastSelectedWasOverview = true
                    provider = self.resolvedMenuProvider()
                case let .provider(selectedProvider):
                    self.settings.mergedMenuLastSelectedWasOverview = false
                    self.selectedMenuProvider = selectedProvider
                    provider = selectedProvider
                }
                switch selection {
                case .overview:
                    self.lastMenuProvider = provider ?? .codex
                case let .provider(provider):
                    self.lastMenuProvider = provider
                }
                self.lastMergedSwitcherSelection = selection
                self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: provider)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    private func makeTokenAccountSwitcherItem(
        display: TokenAccountMenuDisplay,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = TokenAccountSwitcherView(
            accounts: display.accounts,
            selectedIndex: display.activeIndex,
            width: width,
            onSelect: { [weak self, weak menu] index -> Task<Void, Never>? in
                guard let self, let menu else { return nil }
                self.settings.setActiveTokenAccountIndex(index, for: display.provider)
                self.applyIcon(phase: nil)
                self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: display.provider)
                return Task { @MainActor [weak self, weak menu] in
                    guard let self else { return }
                    await ProviderInteractionContext.$current.withValue(.userInitiated) {
                        await self.store.refreshProvider(display.provider)
                    }
                    guard let menu else { return }
                    self.refreshOpenMenuIfStillVisible(menu, provider: display.provider)
                }
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    private func makeCodexAccountSwitcherItem(
        display: CodexAccountMenuDisplay,
        menu: NSMenu,
        width: CGFloat) -> NSMenuItem
    {
        let view = CodexAccountSwitcherView(
            accounts: display.accounts,
            selectedAccountID: display.activeVisibleAccountID,
            width: width,
            onSelect: { [weak self, weak menu] account in
                guard let self else { return }
                self.handleCodexVisibleAccountSelection(account, menu: menu)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func handleCodexVisibleAccountSelection(_ account: CodexVisibleAccount, menu: NSMenu?) -> Bool {
        let visibleAccountID = account.id
        self.settings.selectDisplayedCodexVisibleAccount(account)
        if self.store.prepareCodexAccountScopedRefreshIfNeeded(), let menu {
            self.deferSwitcherMenuRebuildIfStillVisible(menu, provider: .codex)
        }
        Task { @MainActor in
            await ProviderInteractionContext.$current.withValue(.userInitiated) {
                await self.store.refreshCodexAccountScopedState(
                    allowDisabled: true,
                    phaseDidChange: { [weak self, weak menu] _ in
                        guard let self, let menu else { return }
                        guard self.settings.codexVisibleAccountProjection.activeVisibleAccountID == visibleAccountID
                        else {
                            return
                        }
                        self.refreshOpenMenuIfStillVisible(menu, provider: .codex)
                    })
            }
        }
        return true
    }

    private func resolvedMenuProvider(enabledProviders: [UsageProvider]? = nil) -> UsageProvider? {
        let enabled = enabledProviders ?? self.store.enabledProvidersForDisplay()
        if enabled.isEmpty { return .codex }
        if let selected = self.selectedMenuProvider, enabled.contains(selected) {
            return selected
        }
        // Prefer an available provider so the default menu content matches the status icon.
        // Falls back to first display provider when all lack credentials.
        return enabled.first(where: { self.store.isProviderAvailable($0) }) ?? enabled.first
    }

    private func includesOverviewTab(enabledProviders: [UsageProvider]) -> Bool {
        !self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: Self.maxOverviewProviders).isEmpty
    }

    private func resolvedSwitcherSelection(
        enabledProviders: [UsageProvider],
        includesOverview: Bool) -> ProviderSwitcherSelection
    {
        if includesOverview, self.settings.mergedMenuLastSelectedWasOverview {
            return .overview
        }
        return .provider(self.resolvedMenuProvider(enabledProviders: enabledProviders) ?? .codex)
    }

    func menuProvider(for menu: NSMenu) -> UsageProvider? {
        if self.shouldMergeIcons {
            return self.resolvedMenuProvider()
        }
        if let provider = self.menuProviders[ObjectIdentifier(menu)] {
            return provider
        }
        if menu === self.fallbackMenu {
            return nil
        }
        return self.store.enabledProvidersForDisplay().first ?? .codex
    }

    private func scheduleOpenMenuRefresh(for menu: NSMenu) {
        // Queue refresh work only when visible menu data is missing or stale. Here "stale" means the last
        // provider fetch failed and needs a retry; periodic freshness is handled by the refresh timer.
        // AppKit menu tracking is modal, so starting provider refreshes while it is active can make the menu
        // feel frozen and can block keyboard focus from returning.
        if self.menuNeedsDelayedRefreshRetry(for: menu) {
            self.deferMenuInteractionRefreshIfNeeded()
        }
        let key = ObjectIdentifier(menu)
        self.menuRefreshTasks[key]?.cancel()
        self.menuRefreshTasks[key] = Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            try? await Task.sleep(for: Self.menuOpenRefreshDelay)
            guard !Task.isCancelled else { return }
            guard self.isMenuRefreshEnabled else { return }
            #if DEBUG
            self.onDelayedMenuRefreshAttemptForTesting?()
            #endif
            guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
            guard !self.store.isRefreshing else { return }
            let retryProviders = self.delayedRefreshRetryProviders(for: menu)
            let retryStaleProviderCount = retryProviders.count { self.store.isStale(provider: $0) }
            let retryMissingSnapshotCount = retryProviders.count { self.store.snapshot(for: $0) == nil }
            let willRetryRefresh = retryStaleProviderCount > 0 || retryMissingSnapshotCount > 0
            guard willRetryRefresh else { return }
            self.deferMenuInteractionRefreshIfNeeded()
        }
    }

    private func menuNeedsDelayedRefreshRetry(for menu: NSMenu) -> Bool {
        let providersToCheck = self.delayedRefreshRetryProviders(for: menu)
        guard !providersToCheck.isEmpty else { return false }
        return providersToCheck.contains { provider in
            self.store.isStale(provider: provider) || self.store.snapshot(for: provider) == nil
        }
    }

    private func delayedRefreshRetryProviders(for menu: NSMenu) -> [UsageProvider] {
        let enabledProviders = self.store.enabledProvidersForDisplay()
        guard !enabledProviders.isEmpty else { return [] }
        let includesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)

        if self.shouldMergeIcons,
           enabledProviders.count > 1,
           self.resolvedSwitcherSelection(
               enabledProviders: enabledProviders,
               includesOverview: includesOverview) == .overview
        {
            return self.settings.resolvedMergedOverviewProviders(
                activeProviders: enabledProviders,
                maxVisibleProviders: Self.maxOverviewProviders)
        }

        if let provider = self.menuProvider(for: menu)
            ?? self.resolvedMenuProvider(enabledProviders: enabledProviders)
        {
            return [provider]
        }
        return enabledProviders
    }

    private func addMenuCardSections(
        to menu: NSMenu,
        model: UsageMenuCardView.Model,
        provider: UsageProvider,
        width: CGFloat,
        webItems: OpenAIWebMenuItems)
    {
        let hasUsageBlock = model.hasUsageContent
        let hasCredits = model.creditsText != nil
        let hasExtraUsage = model.providerCost != nil
        let hasCost = model.tokenUsage != nil
        let hasStorage = self.store.storageFootprintText(for: provider) != nil
        let bottomPadding = CGFloat(hasCredits ? 4 : 6)
        let sectionSpacing = CGFloat(6)
        let usageBottomPadding = bottomPadding
        let creditsBottomPadding = bottomPadding

        if hasUsageBlock {
            let usageView = UsageMenuCardHeaderAndUsageSectionView(
                model: model,
                bottomPadding: usageBottomPadding,
                width: width)
            let usageSubmenu = self.makeUsageSubmenu(
                provider: provider,
                snapshot: self.store.snapshot(for: provider),
                webItems: webItems,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                usageView,
                id: "menuCardUsage",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(section: "usage"),
                submenu: usageSubmenu))
        } else {
            let headerView = UsageMenuCardHeaderSectionView(
                model: model,
                showDivider: false,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                headerView,
                id: "menuCardHeader",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(section: "header")))
        }

        if hasStorage || hasCredits || hasExtraUsage || hasCost {
            menu.addItem(.separator())
        }

        if self.addStorageMenuCardSection(to: menu, provider: provider, width: width),
           hasCredits || hasExtraUsage || hasCost
        {
            menu.addItem(.separator())
        }

        if hasCredits {
            if hasExtraUsage || hasCost {
                menu.addItem(.separator())
            }
            let creditsView = UsageMenuCardCreditsSectionView(
                model: model,
                showBottomDivider: false,
                topPadding: sectionSpacing,
                bottomPadding: creditsBottomPadding,
                width: width)
            let creditsSubmenu = webItems.hasCreditsHistory ? self.makeCreditsHistorySubmenu(width: width) : nil
            menu.addItem(self.makeMenuCardItem(
                creditsView,
                id: "menuCardCredits",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(section: "credits"),
                submenu: creditsSubmenu))
            if webItems.canShowBuyCredits {
                menu.addItem(self.makeBuyCreditsItem())
            }
        }
        if hasExtraUsage {
            if hasCredits {
                menu.addItem(.separator())
            }
            let extraUsageSubmenu = self.makeOpenAIAPIUsageSubmenu(provider: provider, width: width)
            let extraUsageView = UsageMenuCardExtraUsageSectionView(
                model: model,
                topPadding: sectionSpacing,
                bottomPadding: bottomPadding,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                extraUsageView,
                id: "menuCardExtraUsage",
                width: width,
                heightCacheScope: provider.rawValue,
                heightCacheFingerprint: model.heightFingerprint(section: "extraUsage"),
                submenu: extraUsageSubmenu))
        }
        if hasCost {
            if hasCredits || hasExtraUsage {
                menu.addItem(.separator())
            }
            let costSubmenu = webItems.hasCostHistory ? self
                .makeCostHistorySubmenu(provider: provider, width: width) : nil
            menu.addItem(self.makeCostMenuCardItem(model: model, submenu: costSubmenu))
        }
    }

    @discardableResult
    func addStorageMenuCardSection(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        guard let storageText = self.store.storageFootprintText(for: provider) else { return false }
        let storageView = StorageMenuCardSectionView(
            storageText: storageText,
            topPadding: 6,
            bottomPadding: 6,
            width: width)
        let storageSubmenu = self.makeStorageBreakdownSubmenu(provider: provider, width: width)
        menu.addItem(self.makeMenuCardItem(
            storageView,
            id: "menuCardStorage",
            width: width,
            heightCacheScope: provider.rawValue,
            heightCacheFingerprint: UsageMenuCardView.Model.heightFingerprintField("storage", storageText),
            submenu: storageSubmenu))
        return true
    }

    private func switcherIcon(for provider: UsageProvider) -> NSImage {
        if let brand = ProviderBrandIcon.image(for: provider) {
            return brand
        }

        // Fallback to the dynamic icon renderer if resources are missing (e.g. dev bundle mismatch).
        let snapshot = self.store.snapshot(for: provider)
        let showUsed = self.settings.usageBarsShowUsed
        let style = self.store.style(for: provider)
        let resolved = snapshot.map {
            IconRemainingResolver.resolvedPercents(
                snapshot: $0,
                style: style,
                showUsed: showUsed)
        }
        let primary = resolved?.primary
        var weekly = resolved?.secondary
        if showUsed,
           provider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining <= 0
        {
            // Preserve Warp "no bonus/exhausted bonus" layout even in show-used mode.
            weekly = 0
        }
        if showUsed,
           provider == .warp,
           let remaining = snapshot?.secondary?.remainingPercent,
           remaining > 0,
           weekly == 0
        {
            // In show-used mode, `0` means "unused", not "missing". Keep the weekly lane present.
            weekly = 0.0001
        }
        let creditsProjection = self.store.codexConsumerProjectionIfNeeded(
            for: provider,
            surface: .menuBar,
            snapshotOverride: snapshot,
            now: snapshot?.updatedAt ?? Date())
        let credits = creditsProjection?.menuBarFallback == .creditsBalance
            ? self.store.codexMenuBarCreditsRemaining(
                snapshotOverride: snapshot,
                now: snapshot?.updatedAt ?? Date())
            : nil
        let stale = self.store.isStale(provider: provider)
        let indicator = self.store.statusIndicator(for: provider)
        let image = IconRenderer.makeIcon(
            primaryRemaining: primary,
            weeklyRemaining: weekly,
            creditsRemaining: credits,
            stale: stale,
            style: style,
            blink: 0,
            wiggle: 0,
            tilt: 0,
            statusIndicator: indicator)
        image.isTemplate = true
        return image
    }

    private func makeBuyCreditsItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: L("Buy Credits..."),
            action: #selector(self.openCreditsPurchase),
            keyEquivalent: "")
        item.target = self
        if let image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: nil) {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        return item
    }

    @discardableResult
    private func addCreditsHistorySubmenu(to menu: NSMenu) -> Bool {
        guard let submenu = self.makeCreditsHistorySubmenu(width: self.renderedMenuWidth(for: menu))
        else { return false }
        let item = NSMenuItem(title: L("Credits history"), action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addUsageBreakdownSubmenu(to menu: NSMenu) -> Bool {
        guard let submenu = self.makeUsageBreakdownSubmenu(width: self.renderedMenuWidth(for: menu))
        else { return false }
        let item = NSMenuItem(title: L("Usage breakdown"), action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addCostHistorySubmenu(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard let submenu = self.makeCostHistorySubmenu(provider: provider, width: self.renderedMenuWidth(for: menu))
        else { return false }
        let days = self.store.settings.costUsageHistoryDays
        let title = days == 1 ? L("Usage history (today)") : String(format: L("Usage history (%d days)"), days)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    private func makeUsageSubmenu(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        webItems: OpenAIWebMenuItems,
        width: CGFloat? = nil) -> NSMenu?
    {
        if webItems.hasUsageBreakdown {
            return self.makeUsageBreakdownSubmenu(width: width)
        }
        if provider == .openai {
            return self.makeOpenAIAPIUsageSubmenu(provider: provider, width: width)
        }
        if provider == .zai {
            return self.makeZaiUsageDetailsSubmenu(snapshot: snapshot)
        }
        return nil
    }

    func makeZaiUsageDetailsSubmenu(snapshot: UsageSnapshot?) -> NSMenu? {
        guard let timeLimit = snapshot?.zaiUsage?.timeLimit else { return nil }
        guard !timeLimit.usageDetails.isEmpty else { return nil }

        let submenu = NSMenu()
        submenu.delegate = self
        let titleItem = NSMenuItem(title: L("MCP details"), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        submenu.addItem(titleItem)

        if let window = timeLimit.windowLabel {
            let item = NSMenuItem(title: String(format: L("mcp_window"), window), action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        if let resetTime = timeLimit.nextResetTime {
            let reset = self.settings.resetTimeDisplayStyle == .absolute
                ? UsageFormatter.resetDescription(from: resetTime)
                : UsageFormatter.resetCountdownDescription(from: resetTime)
            let item = NSMenuItem(title: String(format: L("mcp_resets"), reset), action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        submenu.addItem(.separator())

        let sortedDetails = timeLimit.usageDetails.sorted {
            $0.modelCode.localizedCaseInsensitiveCompare($1.modelCode) == .orderedAscending
        }
        for detail in sortedDetails {
            let usage = UsageFormatter.tokenCountString(detail.usage)
            let item = NSMenuItem(
                title: String(format: L("mcp_model_usage"), detail.modelCode, usage),
                action: nil,
                keyEquivalent: "")
            submenu.addItem(item)
        }
        return submenu
    }

    private func makeUsageBreakdownSubmenu(width: CGFloat? = nil) -> NSMenu? {
        let breakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
            from: self.store.openAIDashboard?.usageBreakdown ?? [])
        guard !breakdown.isEmpty else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(chartID: Self.usageBreakdownChartID, width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.usageBreakdownChartID)
    }

    private func makeCreditsHistorySubmenu(width: CGFloat? = nil) -> NSMenu? {
        guard !(self.store.openAIDashboard?.dailyBreakdown ?? []).isEmpty else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(chartID: Self.creditsHistoryChartID, width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.creditsHistoryChartID)
    }

    func makeCostHistorySubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else { return nil }
        guard self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.costHistoryChartID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.costHistoryChartID, provider: provider)
    }

    func tokenSnapshotForCostHistorySubmenu(provider: UsageProvider) -> CostUsageTokenSnapshot? {
        let projected = self.store.tokenSnapshot(
            fromProviderSnapshot: self.store.snapshot(for: provider),
            provider: provider)
        if UsageStore.tokenCostRequiresProviderSnapshot(provider) {
            return projected
        }
        return projected ?? self.store.tokenSnapshot(for: provider)
    }

    func makeOpenAIAPIUsageSubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.hasOpenAIAPIUsageSubmenu(provider: provider) else { return nil }
        return self.makeCostHistorySubmenu(provider: provider, width: width)
    }

    private func hasOpenAIAPIUsageSubmenu(provider: UsageProvider) -> Bool {
        provider == .openai && self.tokenSnapshotForCostHistorySubmenu(provider: provider)?.daily.isEmpty == false
    }

    func makeStorageBreakdownSubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.store.storageFootprint(for: provider)?.components.isEmpty == false else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.storageBreakdownID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.storageBreakdownID, provider: provider)
    }

    private func isOpenAIWebSubviewMenu(_ menu: NSMenu) -> Bool {
        let ids: Set = [
            Self.usageBreakdownChartID,
            Self.creditsHistoryChartID,
        ]
        return menu.items.contains { item in
            guard let id = item.representedObject as? String else { return false }
            return ids.contains(id)
        }
    }

    func refreshHostedSubviewHeights(in menu: NSMenu) {
        let width = self.renderedMenuWidth(for: menu)

        for item in menu.items {
            guard let view = item.view else { continue }
            view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
            view.layoutSubtreeIfNeeded()
            let height = view.fittingSize.height
            view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        }
    }

    @objc func menuCardNoOp(_ sender: NSMenuItem) {
        _ = sender
    }

    @objc private func selectOverviewProvider(_ sender: NSMenuItem) {
        guard let represented = sender.representedObject as? String,
              represented.hasPrefix(Self.overviewRowIdentifierPrefix)
        else {
            return
        }
        let rawProvider = String(represented.dropFirst(Self.overviewRowIdentifierPrefix.count))
        guard let provider = UsageProvider(rawValue: rawProvider),
              let menu = sender.menu
        else {
            return
        }

        self.selectOverviewProvider(provider, menu: menu)
    }

    private func selectOverviewProvider(_ provider: UsageProvider, menu: NSMenu) {
        if !self.settings.mergedMenuLastSelectedWasOverview, self.selectedMenuProvider == provider { return }
        self.settings.mergedMenuLastSelectedWasOverview = false
        self.lastMergedSwitcherSelection = nil
        self.selectedMenuProvider = provider
        self.lastMenuProvider = provider
        self.populateMenu(menu, provider: provider)
        self.markMenuFresh(menu)
        self.applyIcon(phase: nil)
    }
}
