import AppKit
import CodexBarCore
import Observation
import QuartzCore
import SwiftUI

// MARK: - NSMenu construction

extension StatusItemController {
    private static let menuCardBaseWidth: CGFloat = 310
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

    func renderedMenuWidth(for menu: NSMenu) -> CGFloat {
        let measuredWidth = ceil(menu.size.width)
        return max(measuredWidth, Self.menuCardBaseWidth)
    }

    func makeMenu() -> NSMenu {
        guard self.shouldMergeIcons else {
            return self.makeMenu(for: nil)
        }
        return self.makeBaseMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if self.isHostedSubviewMenu(menu) {
            self.hydrateHostedSubviewMenuIfNeeded(menu)
            self.refreshHostedSubviewHeights(in: menu)
            if Self.menuRefreshEnabled, self.isOpenAIWebSubviewMenu(menu) {
                self.store.requestOpenAIDashboardRefreshIfStale(reason: "submenu open")
            }
            if Self.menuRefreshEnabled {
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

        let didRefresh = self.menuNeedsRefresh(menu)
        if didRefresh {
            self.populateMenu(menu, provider: provider)
            self.markMenuFresh(menu)
            // Heights are already set during populateMenu, no need to remeasure
        }
        if Self.menuRefreshEnabled {
            // Intentionally skip open-menu tracking when refresh is disabled (tests).
            // If refresh is re-enabled while this menu stays open, it will not be backfilled until next open.
            self.openMenus[ObjectIdentifier(menu)] = menu
        }
        // Only schedule refresh after menu is registered as open - refreshNow is called async
        if Self.menuRefreshEnabled {
            self.scheduleOpenMenuRefresh(for: menu)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        self.forgetClosedMenu(menu)
    }

    func forgetClosedMenu(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)

        self.openMenus.removeValue(forKey: key)
        self.menuRefreshTasks.removeValue(forKey: key)?.cancel()

        let isPersistentMenu = menu === self.mergedMenu ||
            menu === self.fallbackMenu ||
            self.providerMenus.values.contains { $0 === menu }
        if !isPersistentMenu {
            self.menuProviders.removeValue(forKey: key)
            self.menuVersions.removeValue(forKey: key)
        }
        for menuItem in menu.items {
            (menuItem.view as? MenuCardHighlighting)?.setHighlighted(false)
        }
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            let highlighted = menuItem == item && menuItem.isEnabled
            (menuItem.view as? MenuCardHighlighting)?.setHighlighted(highlighted)
        }
    }

    private func populateMenu(_ menu: NSMenu, provider: UsageProvider?) {
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
        let codexAccountDisplay = isOverviewSelected ? nil : self.codexAccountMenuDisplay(for: currentProvider)
        let tokenAccountDisplay = isOverviewSelected ? nil : self.tokenAccountMenuDisplay(for: currentProvider)
        let showAllTokenAccounts = tokenAccountDisplay?.showAll ?? false
        let openAIContext = self.openAIWebContext(
            currentProvider: currentProvider,
            showAllTokenAccounts: showAllTokenAccounts)
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
        let tokenSwitcherCompatible = tokenAccountDisplay == nil && !hasTokenSwitcher
        let codexSwitcherCompatible = codexAccountDisplay == self.lastCodexAccountMenuDisplay &&
            ((codexAccountDisplay == nil && !hasCodexSwitcher) || (codexAccountDisplay != nil && hasCodexSwitcher))
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
                    codexAccountDisplay: nil,
                    tokenAccountDisplay: nil,
                    openAIContext: openAIContext))
            return
        }

        let canPreserveProviderSwitcher = self.shouldMergeIcons &&
            enabledProviders.count > 1 &&
            switcherProvidersMatch &&
            switcherUsageBarsShowUsedMatch &&
            switcherOverviewAvailabilityMatches &&
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
                    openAIContext: openAIContext))
            return
        }

        #if DEBUG
        if self.openMenus[ObjectIdentifier(menu)] != nil, menu.items.first?.view is ProviderSwitcherView {
            self.menuLogger.debug("populateMenu(open): rebuilding whole menu and replacing provider switcher")
        }
        #endif
        menu.removeAllItems()
        self.addProviderSwitcherIfNeeded(
            to: menu,
            enabledProviders: enabledProviders,
            includesOverview: includesOverview,
            selection: switcherSelection ?? .provider(currentProvider),
            width: menuWidth)
        // Track which providers the switcher was built with for smart update detection
        if self.shouldMergeIcons, enabledProviders.count > 1 {
            self.lastSwitcherProviders = enabledProviders
            self.lastSwitcherUsageBarsShowUsed = self.settings.usageBarsShowUsed
            self.lastMergedSwitcherSelection = switcherSelection
            self.lastSwitcherIncludesOverview = includesOverview
        }
        self.addCodexAccountSwitcherIfNeeded(to: menu, display: codexAccountDisplay, width: menuWidth)
        self.lastCodexAccountMenuDisplay = codexAccountDisplay
        self.addTokenAccountSwitcherIfNeeded(to: menu, display: tokenAccountDisplay, width: menuWidth)
        let menuContext = MenuCardContext(
            currentProvider: currentProvider,
            selectedProvider: selectedProvider,
            menuWidth: menuWidth,
            tokenAccountDisplay: tokenAccountDisplay,
            openAIContext: openAIContext)
        self.addPrimaryMenuContent(
            to: menu,
            context: menuContext,
            switcherSelection: switcherSelection ?? .provider(currentProvider))
        self.addActionableSections(descriptor.sections, to: menu, width: menuWidth)
    }

    private func reusableFixedWidthRows(in menu: NSMenu) -> [NSMenuItem] {
        guard !menu.items.isEmpty else { return [] }

        var reusableRows: [NSMenuItem] = []
        var index = 0
        if menu.items.first?.view is ProviderSwitcherView {
            reusableRows.append(menu.items[0])
            index = 2
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
    }

    /// Smart update: rebuild everything below the provider switcher while keeping the switcher view intact.
    private func updateMenuContentPreservingSwitcher(
        _ menu: NSMenu,
        context: MenuUpdateContext)
    {
        // Batch menu updates to prevent visual flickering during provider switch.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let contentStartIndex = menu.items.first?.view is ProviderSwitcherView ? 2 : 0
        (menu.items.first?.view as? ProviderSwitcherView)?.updateSelection(context.switcherSelection)
        while menu.items.count > contentStartIndex {
            menu.removeItem(at: contentStartIndex)
        }

        self.lastMergedSwitcherSelection = context.switcherSelection
        let enabledProviders = self.store.enabledProvidersForDisplay()
        self.lastSwitcherProviders = enabledProviders
        self.lastSwitcherUsageBarsShowUsed = self.settings.usageBarsShowUsed
        self.lastSwitcherIncludesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)
        self.addCodexAccountSwitcherIfNeeded(to: menu, display: context.codexAccountDisplay, width: context.menuWidth)
        self.lastCodexAccountMenuDisplay = context.codexAccountDisplay
        self.addTokenAccountSwitcherIfNeeded(to: menu, display: context.tokenAccountDisplay, width: context.menuWidth)

        let descriptor = MenuDescriptor.build(
            provider: context.provider,
            store: self.store,
            settings: self.settings,
            account: self.account,
            managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
            updateReady: self.updater.updateStatus.isUpdateReady,
            includeContextualActions: context.switcherSelection != .overview)

        let menuContext = MenuCardContext(
            currentProvider: context.currentProvider,
            selectedProvider: context.provider,
            menuWidth: context.menuWidth,
            tokenAccountDisplay: context.tokenAccountDisplay,
            openAIContext: context.openAIContext)
        self.addPrimaryMenuContent(to: menu, context: menuContext, switcherSelection: context.switcherSelection)
        self.addActionableSections(descriptor.sections, to: menu, width: context.menuWidth)
    }

    private struct OpenAIWebContext {
        let hasUsageBreakdown: Bool
        let hasCreditsHistory: Bool
        let hasCostHistory: Bool
        let canShowBuyCredits: Bool
        let hasOpenAIWebMenuItems: Bool
    }

    private struct MenuCardContext {
        let currentProvider: UsageProvider
        let selectedProvider: UsageProvider?
        let menuWidth: CGFloat
        let tokenAccountDisplay: TokenAccountMenuDisplay?
        let openAIContext: OpenAIWebContext
    }

    private func openAIWebContext(
        currentProvider: UsageProvider,
        showAllTokenAccounts: Bool) -> OpenAIWebContext
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
        let hasOpenAIWebMenuItems = !showAllTokenAccounts &&
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
        guard let display else { return }
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
                return (provider: provider, model: model)
            }
        guard !rows.isEmpty else { return false }

        for (index, row) in rows.enumerated() {
            let identifier = "\(Self.overviewRowIdentifierPrefix)\(row.provider.rawValue)"
            let storageText = self.store.storageFootprintText(for: row.provider)
            let item = self.makeMenuCardItem(
                OverviewMenuCardRowView(model: row.model, storageText: storageText, width: menuWidth),
                id: identifier,
                width: menuWidth,
                onClick: { [weak self, weak menu] in
                    guard let self, let menu else { return }
                    self.selectOverviewProvider(row.provider, menu: menu)
                })
            // Keep menu item action wired for keyboard activation and accessibility action paths.
            item.target = self
            item.action = #selector(self.selectOverviewProvider(_:))
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
        let message = if resolvedProviders.isEmpty {
            "No providers selected for Overview."
        } else {
            "No overview data available."
        }
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.representedObject = "overviewEmptyState"
        menu.addItem(item)
    }

    private func addMenuCards(to menu: NSMenu, context: MenuCardContext) -> Bool {
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
            if cards.isEmpty, let model = self.menuCardModel(for: context.selectedProvider) {
                menu.addItem(self.makeMenuCardItem(
                    UsageMenuCardView(model: model, width: context.menuWidth),
                    id: "menuCard",
                    width: context.menuWidth))
                menu.addItem(.separator())
            } else {
                for (index, model) in cards.enumerated() {
                    menu.addItem(self.makeMenuCardItem(
                        UsageMenuCardView(model: model, width: context.menuWidth),
                        id: "menuCard-\(index)",
                        width: context.menuWidth))
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
            return false
        }

        guard let model = self.menuCardModel(for: context.selectedProvider) else { return false }
        if context.openAIContext.hasOpenAIWebMenuItems {
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
            width: context.menuWidth))
        if self.addStorageMenuCardSection(to: menu, provider: context.currentProvider, width: context.menuWidth) {
            menu.addItem(.separator())
        }
        if context.openAIContext.canShowBuyCredits {
            menu.addItem(self.makeBuyCreditsItem())
        }
        menu.addItem(.separator())
        return false
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
                    if case .refresh = action {
                        menu.addItem(self.makePersistentMenuActionItem(title: title, action: action, width: width))
                        continue
                    }

                    let (selector, represented) = self.selector(for: action)
                    let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
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
                        self.applySubtitle(subtitle, to: item, title: title)
                    } else if case .addCodexAccount = action,
                              let subtitle = self.codexAddAccountSubtitle()
                    {
                        item.isEnabled = false
                        self.applySubtitle(subtitle, to: item, title: title)
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
        width: CGFloat) -> NSMenuItem
    {
        let shortcut = self.shortcut(for: action)
        let row = PersistentMenuActionItemView(
            title: title,
            systemImageName: action.systemImageName,
            shortcutText: shortcut.map { self.shortcutLabel(for: $0) },
            width: width,
            onClick: { [weak self] in
                self?.performPersistentMenuAction(action)
            })

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: shortcut?.key ?? "")
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? NSEvent.ModifierFlags()
        item.isEnabled = true
        item.view = row
        item.toolTip = title
        return item
    }

    private func performPersistentMenuAction(_ action: MenuDescriptor.MenuAction) {
        switch action {
        case .refresh:
            self.refreshNow()
        default:
            break
        }
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
                self.providerSwitcherUpdateToken &+= 1
                let updateToken = self.providerSwitcherUpdateToken
                Task { @MainActor [weak self, weak menu] in
                    await Task.yield()
                    guard let self, let menu else { return }
                    guard self.providerSwitcherUpdateToken == updateToken else { return }
                    self.applyIcon(phase: nil)
                    guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
                    self.populateMenu(menu, provider: provider)
                    self.markMenuFresh(menu)
                }
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
                // Immediately rebuild to show the new selection, then refresh data
                // and rebuild again once fresh data arrives.
                self.populateMenu(menu, provider: display.provider)
                self.markMenuFresh(menu)
                self.applyIcon(phase: nil)
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
            onSelect: { [weak self, weak menu] visibleAccountID in
                guard let self else { return }
                self.handleCodexVisibleAccountSelection(visibleAccountID, menu: menu)
            })
        let item = NSMenuItem()
        item.view = view
        item.isEnabled = false
        return item
    }

    @discardableResult
    private func handleCodexVisibleAccountSelection(_ visibleAccountID: String, menu: NSMenu?) -> Bool {
        guard self.settings.selectCodexVisibleAccount(id: visibleAccountID) else { return false }
        if self.store.prepareCodexAccountScopedRefreshIfNeeded(), let menu {
            self.refreshOpenMenuIfStillVisible(menu, provider: .codex)
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

    private func tokenAccountMenuDisplay(for provider: UsageProvider) -> TokenAccountMenuDisplay? {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return nil }
        let accounts = self.settings.tokenAccounts(for: provider)
        guard accounts.count > 1 else { return nil }
        let activeIndex = self.settings.tokenAccountsData(for: provider)?.clampedActiveIndex() ?? 0
        let canShowAllCopilotAccounts = provider == .copilot &&
            accounts.count <= UsageStore.tokenAccountMenuSnapshotLimit
        let showAll = canShowAllCopilotAccounts || self.settings.showAllTokenAccountsInMenu
        let snapshots = showAll ? (self.store.accountSnapshots[provider] ?? []) : []
        return TokenAccountMenuDisplay(
            provider: provider,
            accounts: accounts,
            snapshots: snapshots,
            activeIndex: activeIndex,
            showAll: showAll,
            showSwitcher: !showAll)
    }

    private func codexAccountMenuDisplay(for provider: UsageProvider) -> CodexAccountMenuDisplay? {
        guard provider == .codex else { return nil }
        let projection = self.settings.codexVisibleAccountProjection
        guard projection.visibleAccounts.count > 1 else { return nil }
        return CodexAccountMenuDisplay(
            accounts: projection.visibleAccounts,
            activeVisibleAccountID: projection.activeVisibleAccountID)
    }

    private func menuNeedsRefresh(_ menu: NSMenu) -> Bool {
        let key = ObjectIdentifier(menu)
        return self.menuVersions[key] != self.menuContentVersion
    }

    private func markMenuFresh(_ menu: NSMenu) {
        let key = ObjectIdentifier(menu)
        self.menuVersions[key] = self.menuContentVersion
    }

    func refreshOpenMenusIfNeeded() {
        guard Self.menuRefreshEnabled else { return }
        guard !self.openMenus.isEmpty else { return }
        var orphanedKeys: [ObjectIdentifier] = []
        for (key, menu) in self.openMenus {
            guard key == ObjectIdentifier(menu) else {
                orphanedKeys.append(key)
                continue
            }

            if self.isHostedSubviewMenu(menu) {
                self.refreshHostedSubviewHeights(in: menu)
                continue
            }

            if self.menuNeedsRefresh(menu) {
                let provider = self.menuProvider(for: menu)
                self.populateMenu(menu, provider: provider)
                self.markMenuFresh(menu)
                // Heights are already set during populateMenu, no need to remeasure
            }
        }

        // Clean up orphaned menu entries from all tracking dictionaries.
        for key in orphanedKeys {
            self.openMenus.removeValue(forKey: key)
            self.menuRefreshTasks.removeValue(forKey: key)?.cancel()
            self.menuProviders.removeValue(forKey: key)
            self.menuVersions.removeValue(forKey: key)
        }
    }

    private func menuProvider(for menu: NSMenu) -> UsageProvider? {
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

    func refreshOpenMenuIfStillVisible(_ menu: NSMenu, provider: UsageProvider?) {
        self.rebuildOpenMenuIfStillVisible(menu, provider: provider)
        Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            #if DEBUG
            if let override = self._test_openMenuRefreshYieldOverride {
                await override()
            } else {
                await Task.yield()
            }
            #else
            await Task.yield()
            #endif
            self.rebuildOpenMenuIfStillVisible(menu, provider: provider)
        }
    }

    private func rebuildOpenMenuIfStillVisible(_ menu: NSMenu, provider: UsageProvider?) {
        guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
        self.populateMenu(menu, provider: provider)
        self.markMenuFresh(menu)
        self.applyIcon(phase: nil)
        #if DEBUG
        self._test_openMenuRebuildObserver?(menu)
        #endif
    }

    private func scheduleOpenMenuRefresh(for menu: NSMenu) {
        // Kick off a user-initiated refresh on open (non-forced) and re-check after a delay.
        // NEVER block menu opening with network requests.
        if !self.store.isRefreshing {
            self.refreshStore(forceTokenUsage: false)
        }
        let key = ObjectIdentifier(menu)
        self.menuRefreshTasks[key]?.cancel()
        self.menuRefreshTasks[key] = Task { @MainActor [weak self, weak menu] in
            guard let self, let menu else { return }
            try? await Task.sleep(for: Self.menuOpenRefreshDelay)
            guard !Task.isCancelled else { return }
            guard Self.menuRefreshEnabled else { return }
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
            self.refreshStore(forceTokenUsage: false)
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

    private func refreshMenuCardHeights(in menu: NSMenu) {
        // Re-measure the menu card height right before display to avoid stale/incorrect sizing when content
        // changes (e.g. dashboard error lines causing wrapping).
        let cardItems = menu.items.filter { item in
            (item.representedObject as? String)?.hasPrefix("menuCard") == true
        }
        for item in cardItems {
            guard let view = item.view else { continue }
            let width = self.renderedMenuWidth(for: menu)
            let height = self.menuCardHeight(for: view, width: width)
            view.frame = NSRect(
                origin: .zero,
                size: NSSize(width: width, height: height))
        }
    }

    func makeMenuCardItem(
        _ view: some View,
        id: String,
        width: CGFloat,
        submenu: NSMenu? = nil,
        submenuIndicatorAlignment: Alignment = .topTrailing,
        submenuIndicatorTopPadding: CGFloat = 8,
        onClick: (() -> Void)? = nil) -> NSMenuItem
    {
        if !Self.menuCardRenderingEnabled {
            let item = NSMenuItem()
            item.isEnabled = true
            item.representedObject = id
            item.submenu = submenu
            if submenu != nil {
                item.target = self
                item.action = #selector(self.menuCardNoOp(_:))
            }
            return item
        }

        let highlightState = MenuCardHighlightState()
        let wrapped = MenuCardSectionContainerView(
            highlightState: highlightState,
            showsSubmenuIndicator: submenu != nil,
            submenuIndicatorAlignment: submenuIndicatorAlignment,
            submenuIndicatorTopPadding: submenuIndicatorTopPadding)
        {
            view
        }
        let hosting = MenuCardItemHostingView(rootView: wrapped, highlightState: highlightState, onClick: onClick)
        // Set frame with target width immediately
        let height = self.menuCardHeight(for: hosting, width: width)
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        let item = NSMenuItem()
        item.view = hosting
        item.isEnabled = true
        item.representedObject = id
        item.submenu = submenu
        if submenu != nil {
            item.target = self
            item.action = #selector(self.menuCardNoOp(_:))
        }
        return item
    }

    private func menuCardHeight(for view: NSView, width: CGFloat) -> CGFloat {
        let basePadding: CGFloat = 6
        let descenderSafety: CGFloat = 1

        // Fast path: use protocol-based measurement when available (avoids layout passes)
        if let measured = view as? MenuCardMeasuring {
            return max(1, ceil(measured.measuredHeight(width: width) + basePadding + descenderSafety))
        }

        // Set frame with target width before measuring.
        view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))

        // Use fittingSize directly - SwiftUI hosting views respect the frame width for wrapping
        let fitted = view.fittingSize

        return max(1, ceil(fitted.height + basePadding + descenderSafety))
    }

    private func addMenuCardSections(
        to menu: NSMenu,
        model: UsageMenuCardView.Model,
        provider: UsageProvider,
        width: CGFloat,
        webItems: OpenAIWebMenuItems)
    {
        let hasUsageBlock = !model.metrics.isEmpty || model.placeholder != nil
        let hasCredits = model.creditsText != nil
        let hasExtraUsage = model.providerCost != nil
        let hasCost = model.tokenUsage != nil
        let hasStorage = self.store.storageFootprintText(for: provider) != nil
        let bottomPadding = CGFloat(hasCredits ? 4 : 6)
        let sectionSpacing = CGFloat(6)
        let usageBottomPadding = bottomPadding
        let creditsBottomPadding = bottomPadding

        let headerView = UsageMenuCardHeaderSectionView(
            model: model,
            showDivider: hasUsageBlock,
            width: width)
        menu.addItem(self.makeMenuCardItem(headerView, id: "menuCardHeader", width: width))

        if hasUsageBlock {
            let usageView = UsageMenuCardUsageSectionView(
                model: model,
                showBottomDivider: false,
                bottomPadding: usageBottomPadding,
                width: width)
            let usageSubmenu = self.makeUsageSubmenu(
                provider: provider,
                snapshot: self.store.snapshot(for: provider),
                webItems: webItems)
            menu.addItem(self.makeMenuCardItem(
                usageView,
                id: "menuCardUsage",
                width: width,
                submenu: usageSubmenu))
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
            let creditsSubmenu = webItems.hasCreditsHistory ? self.makeCreditsHistorySubmenu() : nil
            menu.addItem(self.makeMenuCardItem(
                creditsView,
                id: "menuCardCredits",
                width: width,
                submenu: creditsSubmenu))
            if webItems.canShowBuyCredits {
                menu.addItem(self.makeBuyCreditsItem())
            }
        }
        if hasExtraUsage {
            if hasCredits {
                menu.addItem(.separator())
            }
            let extraUsageView = UsageMenuCardExtraUsageSectionView(
                model: model,
                topPadding: sectionSpacing,
                bottomPadding: bottomPadding,
                width: width)
            menu.addItem(self.makeMenuCardItem(
                extraUsageView,
                id: "menuCardExtraUsage",
                width: width))
        }
        if hasCost {
            if hasCredits || hasExtraUsage {
                menu.addItem(.separator())
            }
            let costView = UsageMenuCardCostSectionView(
                model: model,
                topPadding: sectionSpacing,
                bottomPadding: bottomPadding,
                width: width)
            let costSubmenu = webItems.hasCostHistory ? self.makeCostHistorySubmenu(provider: provider) : nil
            menu.addItem(self.makeMenuCardItem(
                costView,
                id: "menuCardCost",
                width: width,
                submenu: costSubmenu))
        }
    }

    @discardableResult
    private func addStorageMenuCardSection(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        guard let storageText = self.store.storageFootprintText(for: provider) else { return false }
        let storageView = StorageMenuCardSectionView(
            storageText: storageText,
            topPadding: 6,
            bottomPadding: 6,
            width: width)
        let storageSubmenu = self.makeStorageBreakdownSubmenu(provider: provider)
        menu.addItem(self.makeMenuCardItem(
            storageView,
            id: "menuCardStorage",
            width: width,
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
        let item = NSMenuItem(title: "Buy Credits...", action: #selector(self.openCreditsPurchase), keyEquivalent: "")
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
        guard let submenu = self.makeCreditsHistorySubmenu() else { return false }
        let item = NSMenuItem(title: "Credits history", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addUsageBreakdownSubmenu(to menu: NSMenu) -> Bool {
        guard let submenu = self.makeUsageBreakdownSubmenu() else { return false }
        let item = NSMenuItem(title: "Usage breakdown", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    @discardableResult
    private func addCostHistorySubmenu(to menu: NSMenu, provider: UsageProvider) -> Bool {
        guard let submenu = self.makeCostHistorySubmenu(provider: provider) else { return false }
        let item = NSMenuItem(title: "Usage history (30 days)", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        menu.addItem(item)
        return true
    }

    private func makeUsageSubmenu(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        webItems: OpenAIWebMenuItems) -> NSMenu?
    {
        if webItems.hasUsageBreakdown {
            return self.makeUsageBreakdownSubmenu()
        }
        if provider == .zai {
            return self.makeZaiUsageDetailsSubmenu(snapshot: snapshot)
        }
        return nil
    }

    private func makeZaiUsageDetailsSubmenu(snapshot: UsageSnapshot?) -> NSMenu? {
        guard let timeLimit = snapshot?.zaiUsage?.timeLimit else { return nil }
        guard !timeLimit.usageDetails.isEmpty else { return nil }

        let submenu = NSMenu()
        submenu.delegate = self
        let titleItem = NSMenuItem(title: "MCP details", action: nil, keyEquivalent: "")
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

    private func makeUsageBreakdownSubmenu() -> NSMenu? {
        let breakdown = OpenAIDashboardDailyBreakdown.removingSkillUsageServices(
            from: self.store.openAIDashboard?.usageBreakdown ?? [])
        guard !breakdown.isEmpty else { return nil }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.usageBreakdownChartID)
    }

    private func makeCreditsHistorySubmenu() -> NSMenu? {
        guard !(self.store.openAIDashboard?.dailyBreakdown ?? []).isEmpty else { return nil }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.creditsHistoryChartID)
    }

    private func makeCostHistorySubmenu(provider: UsageProvider) -> NSMenu? {
        guard provider == .codex || provider == .claude || provider == .vertexai else { return nil }
        guard self.store.tokenSnapshot(for: provider)?.daily.isEmpty == false else { return nil }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.costHistoryChartID, provider: provider)
    }

    private func makeStorageBreakdownSubmenu(provider: UsageProvider) -> NSMenu? {
        guard self.store.storageFootprint(for: provider)?.components.isEmpty == false else { return nil }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.storageBreakdownID, provider: provider)
    }

    private func isHostedSubviewMenu(_ menu: NSMenu) -> Bool {
        let ids: Set = [
            Self.usageBreakdownChartID,
            Self.creditsHistoryChartID,
            Self.costHistoryChartID,
            Self.usageHistoryChartID,
            Self.storageBreakdownID,
        ]
        return menu.items.contains { item in
            guard let id = item.representedObject as? String else { return false }
            return ids.contains(id)
        }
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

    private func refreshHostedSubviewHeights(in menu: NSMenu) {
        let width = self.renderedMenuWidth(for: menu)

        for item in menu.items {
            guard let view = item.view else { continue }
            view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
            view.layoutSubtreeIfNeeded()
            let height = view.fittingSize.height
            view.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        }
    }

    @objc private func menuCardNoOp(_ sender: NSMenuItem) {
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
