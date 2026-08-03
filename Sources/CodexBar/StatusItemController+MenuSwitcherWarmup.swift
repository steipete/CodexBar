import AppKit
import CodexBarCore

/// Pre-builds the merged switcher's sibling tab content shortly after the menu
/// opens (and after each open-menu rebuild), so switching tabs attaches fully
/// laid-out cached rows instead of rendering fresh hosting views mid-click.
/// `NSHostingView` commits SwiftUI content asynchronously; a freshly built card
/// swapped in during a switch paints a frame late, which reads as a flicker.
extension StatusItemController {
    private static let mergedSwitcherWarmupDelaySeconds: TimeInterval = 0.12

    /// Scheduled via a common-modes `Timer`, NOT Swift Concurrency: the menu is
    /// open (tracking mode) for the entire window where warm caches matter, and
    /// main-actor tasks do not run during NSMenu tracking — a `Task.sleep`-based
    /// warmup would only ever fire after the menu closed, i.e. never usefully.
    func scheduleMergedSwitcherSiblingWarmup(for menu: NSMenu) {
        guard self.isMenuRefreshEnabled else { return }
        guard self.shouldMergeIcons, menu === self.mergedMenu else { return }
        self.mergedSwitcherWarmupTimer?.invalidate()
        let menuKey = ObjectIdentifier(menu)
        let timer = Timer(
            timeInterval: Self.mergedSwitcherWarmupDelaySeconds,
            repeats: false)
        { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mergedSwitcherWarmupTimer = nil
                guard let menu = self.openMenus[menuKey] else { return }
                self.warmMergedSwitcherSiblingContent(in: menu)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.mergedSwitcherWarmupTimer = timer
    }

    func cancelMergedSwitcherSiblingWarmup() {
        self.mergedSwitcherWarmupTimer?.invalidate()
        self.mergedSwitcherWarmupTimer = nil
    }

    func warmMergedSwitcherSiblingContent(in menu: NSMenu) {
        guard menu.items.first?.view is ProviderSwitcherView else { return }
        let enabledProviders = self.store.enabledProvidersForDisplay()
        guard enabledProviders.count > 1 else { return }
        let includesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)
        let currentSelection = self.resolvedSwitcherSelection(
            enabledProviders: enabledProviders,
            includesOverview: includesOverview)
        var selections: [ProviderSwitcherSelection] = enabledProviders.map { .provider($0) }
        if includesOverview {
            selections.insert(.overview, at: 0)
        }
        for selection in selections where selection != currentSelection {
            self.warmMergedSwitcherContentIfMissing(
                for: selection,
                in: menu,
                enabledProviders: enabledProviders)
        }
    }

    private func warmMergedSwitcherContentIfMissing(
        for selection: ProviderSwitcherSelection,
        in menu: NSMenu,
        enabledProviders: [UsageProvider])
    {
        let isOverviewSelected = selection == .overview
        let selectedProvider = isOverviewSelected
            ? self.resolvedMenuProvider(enabledProviders: enabledProviders)
            : selection.provider
        let currentProvider = selectedProvider ?? enabledProviders.first ?? .codex
        let codexAccountDisplay = isOverviewSelected ? nil : self.codexAccountMenuDisplay(for: currentProvider)
        let tokenAccountDisplay = isOverviewSelected ? nil : self.tokenAccountMenuDisplay(for: currentProvider)
        let showAllAccounts = (tokenAccountDisplay?.showAll ?? false) || (codexAccountDisplay?.showAll ?? false)
        let descriptor = self.makeMenuDescriptor(
            provider: selectedProvider,
            includeContextualActions: !isOverviewSelected)
        let menuWidth = self.menuCardWidth(
            for: enabledProviders,
            selectedProvider: selectedProvider,
            descriptor: descriptor)
        guard self.reusableMergedSwitcherContent(
            for: selection,
            in: menu,
            menuWidth: menuWidth,
            codexAccountDisplay: codexAccountDisplay,
            tokenAccountDisplay: tokenAccountDisplay) == nil
        else { return }

        // Building sibling content updates the "last rendered display" trackers used by
        // smart-update compatibility checks; restore them so the live tab's state wins.
        let savedCodexDisplay = self.lastCodexAccountMenuDisplay
        let savedTokenDisplay = self.lastTokenAccountMenuDisplay
        let scratch = NSMenu()
        scratch.autoenablesItems = false
        self.addSwitcherScopedMenuContent(
            into: scratch,
            captureMenu: menu,
            context: MenuUpdateContext(
                provider: selectedProvider,
                currentProvider: currentProvider,
                switcherSelection: selection,
                menuWidth: menuWidth,
                codexAccountDisplay: codexAccountDisplay,
                tokenAccountDisplay: tokenAccountDisplay,
                openAIContext: self.openAIWebContext(
                    currentProvider: currentProvider,
                    showAllAccounts: showAllAccounts),
                descriptor: descriptor))
        self.lastCodexAccountMenuDisplay = savedCodexDisplay
        self.lastTokenAccountMenuDisplay = savedTokenDisplay

        let items = scratch.items
        scratch.removeAllItems()
        guard !items.isEmpty else { return }
        // Force SwiftUI layout now so the first attach draws in the same transaction
        // as the menu mutation instead of one frame later.
        for item in items {
            item.view?.layoutSubtreeIfNeeded()
        }
        self.cacheMergedSwitcherContent(
            items,
            in: menu,
            selection: selection,
            context: MergedSwitcherContentCacheContext(
                menuWidth: menuWidth,
                codexAccountDisplay: codexAccountDisplay,
                tokenAccountDisplay: tokenAccountDisplay,
                contentVersion: self.menuSession.contentVersion))
    }
}
