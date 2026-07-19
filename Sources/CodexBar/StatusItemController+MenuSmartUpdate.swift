import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    /// Smart update: rebuild everything below the provider switcher while keeping the switcher view intact.
    struct MenuUpdateContext {
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
    func updateMenuContentPreservingSwitcher(
        _ menu: NSMenu,
        context: MenuUpdateContext)
    {
        self.performMenuMutationWithoutAnimation {
            let contentStartIndex = self.providerSwitcherContentStartIndex(in: menu)
            if let switcherView = menu.items.first?.view as? ProviderSwitcherView {
                switcherView.updateSelection(context.switcherSelection)
                switcherView.updateQuotaIndicators()
            }
            let outgoingSelection = self.lastMergedMenuContentSelection
            let isSelectionSwitch = outgoingSelection != nil && outgoingSelection != context.switcherSelection
            let enabledProviders = self.store.enabledProvidersForDisplay()

            if isSelectionSwitch,
               let outgoingSelection,
               let cachedItems = self.reusableMergedSwitcherContent(
                   for: context.switcherSelection,
                   in: menu,
                   menuWidth: context.menuWidth,
                   codexAccountDisplay: context.codexAccountDisplay,
                   tokenAccountDisplay: context.tokenAccountDisplay)
            {
                // Park the outgoing payloads for an equally instant switch-back. Compatible
                // menu-item shells stay attached, avoiding the empty intermediate layout that
                // AppKit can visibly render when the whole content block is removed first.
                let outgoingCodexAccountDisplay = self.lastCodexAccountMenuDisplay
                let outgoingTokenAccountDisplay = self.lastTokenAccountMenuDisplay
                self.rememberMergedSwitcherState(enabledProviders, context.switcherSelection)
                let displacedItems = self.replaceMenuContentKeepingRowsVisible(
                    menu,
                    fromIndex: contentStartIndex,
                    with: cachedItems)
                // Cached items may have changed refresh state while detached from a menu.
                self.updatePersistentRefreshItemsEnabled()
                self.refreshMenuCardHeights(in: menu)
                self.cacheMergedSwitcherContent(
                    displacedItems,
                    in: menu,
                    selection: outgoingSelection,
                    context: MergedSwitcherContentCacheContext(
                        menuWidth: context.menuWidth,
                        codexAccountDisplay: outgoingCodexAccountDisplay,
                        tokenAccountDisplay: outgoingTokenAccountDisplay,
                        contentVersion: nil))
                self.lastCodexAccountMenuDisplay = context.codexAccountDisplay
                self.lastTokenAccountMenuDisplay = context.tokenAccountDisplay
                self.cacheVisibleMergedSwitcherContent(
                    in: menu,
                    selection: context.switcherSelection,
                    contentStartIndex: contentStartIndex,
                    menuWidth: context.menuWidth,
                    contentVersion: self.menuSession.contentVersion)
                return
            }

            // Rebuild path (data tick, or switch whose incoming tab must be built): recycle
            // the outgoing hosting views and reconcile in place when the row skeleton is
            // unchanged, so an open tracked menu sees content mutations instead of item
            // churn. The fresh content is built into a detached scratch menu while its
            // interaction closures capture the live menu they will serve.
            let shapes = self.menuContentShapes(in: menu, fromIndex: contentStartIndex)
            self.harvestRecyclableMenuCardViews(
                in: menu,
                fromIndex: contentStartIndex,
                displacedSelection: outgoingSelection,
                preserveHighlightedItem: true)
            defer { self.clearMenuCardViewRecyclePool() }
            self.rememberMergedSwitcherState(enabledProviders, context.switcherSelection)
            let scratch = NSMenu()
            scratch.autoenablesItems = false
            self.addSwitcherScopedMenuContent(into: scratch, captureMenu: menu, context: context)
            self.reconcileMenuContent(menu, fromIndex: contentStartIndex, shapes: shapes, with: scratch)
            self.refreshMenuCardHeights(in: menu)
            self.cacheVisibleMergedSwitcherContent(
                in: menu,
                selection: context.switcherSelection,
                contentStartIndex: contentStartIndex,
                menuWidth: context.menuWidth,
                contentVersion: self.menuSession.contentVersion)
        }
    }

    /// Adds everything below the provider switcher (account switchers, card content, and
    /// actionable sections) to `target`, which may be a detached scratch menu; interaction
    /// closures always capture `captureMenu`, the live menu the rows will serve.
    private func addSwitcherScopedMenuContent(
        into target: NSMenu,
        captureMenu: NSMenu,
        context: MenuUpdateContext)
    {
        self.addCodexAccountSwitcherIfNeeded(
            to: target,
            display: context.codexAccountDisplay,
            width: context.menuWidth,
            captureMenu: captureMenu)
        self.lastCodexAccountMenuDisplay = context.codexAccountDisplay
        self.addTokenAccountSwitcherIfNeeded(
            to: target,
            display: context.tokenAccountDisplay,
            width: context.menuWidth,
            captureMenu: captureMenu)
        self.lastTokenAccountMenuDisplay = context.tokenAccountDisplay

        let menuContext = MenuCardContext(
            currentProvider: context.currentProvider,
            selectedProvider: context.provider,
            menuWidth: context.menuWidth,
            codexAccountDisplay: context.codexAccountDisplay,
            tokenAccountDisplay: context.tokenAccountDisplay,
            openAIContext: context.openAIContext)
        self.addPrimaryMenuContent(
            to: target,
            context: menuContext,
            switcherSelection: context.switcherSelection,
            captureMenu: captureMenu)
        self.addActionableSections(
            context.descriptor.sections,
            to: target,
            width: context.menuWidth,
            captureMenu: captureMenu)
    }
}
