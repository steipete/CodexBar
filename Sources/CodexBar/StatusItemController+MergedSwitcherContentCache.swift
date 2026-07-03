import AppKit

struct CachedMergedSwitcherMenuContent {
    let requiredMenuContentVersion: Int
    let menuWidth: CGFloat
    let codexAccountDisplay: CodexAccountMenuDisplay?
    let tokenAccountDisplay: TokenAccountMenuDisplay?
    let localizationSignature: String
    let items: [NSMenuItem]

    func matches(
        requiredMenuContentVersion: Int,
        menuWidth: CGFloat,
        codexAccountDisplay: CodexAccountMenuDisplay?,
        tokenAccountDisplay: TokenAccountMenuDisplay?,
        localizationSignature: String)
        -> Bool
    {
        self.requiredMenuContentVersion >= requiredMenuContentVersion &&
            abs(self.menuWidth - menuWidth) <= 0.5 &&
            self.codexAccountDisplay == codexAccountDisplay &&
            self.tokenAccountDisplay == tokenAccountDisplay &&
            self.localizationSignature == localizationSignature
    }
}

struct MergedSwitcherContentCacheContext {
    let menuWidth: CGFloat
    let codexAccountDisplay: CodexAccountMenuDisplay?
    let tokenAccountDisplay: TokenAccountMenuDisplay?
    let contentVersion: Int?
}

extension StatusItemController {
    func preservingMergedSwitcherContentCachesDuringInvalidation(_ body: () -> Void) {
        let previous = self.preservesMergedSwitcherContentCachesDuringInvalidation
        self.preservesMergedSwitcherContentCachesDuringInvalidation = true
        defer { self.preservesMergedSwitcherContentCachesDuringInvalidation = previous }
        body()
    }

    func clearMergedSwitcherContentCaches() {
        self.mergedSwitcherContentCaches.removeAll(keepingCapacity: true)
    }

    func clearMergedSwitcherContentCache(for menu: NSMenu) {
        self.mergedSwitcherContentCaches.removeValue(forKey: ObjectIdentifier(menu))
    }

    func cacheVisibleMergedSwitcherContent(
        in menu: NSMenu,
        selection: ProviderSwitcherSelection,
        contentStartIndex: Int,
        menuWidth: CGFloat,
        contentVersion: Int? = nil)
    {
        guard self.shouldMergeIcons else { return }
        guard menu.items.first?.view is ProviderSwitcherView else { return }
        guard contentStartIndex < menu.items.count else { return }
        let items = Array(menu.items[contentStartIndex...])
        self.cacheMergedSwitcherContent(
            items,
            in: menu,
            selection: selection,
            context: MergedSwitcherContentCacheContext(
                menuWidth: menuWidth,
                codexAccountDisplay: self.lastCodexAccountMenuDisplay,
                tokenAccountDisplay: self.lastTokenAccountMenuDisplay,
                contentVersion: contentVersion))
    }

    func cacheMergedSwitcherContent(
        _ items: [NSMenuItem],
        in menu: NSMenu,
        selection: ProviderSwitcherSelection,
        context: MergedSwitcherContentCacheContext)
    {
        guard !items.isEmpty else { return }

        let entry = CachedMergedSwitcherMenuContent(
            requiredMenuContentVersion: context.contentVersion ??
                self.menuSession.renderedVersion(for: ObjectIdentifier(menu)) ??
                self.menuSession.latestRequiredRebuildVersion,
            menuWidth: context.menuWidth,
            codexAccountDisplay: context.codexAccountDisplay,
            tokenAccountDisplay: context.tokenAccountDisplay,
            localizationSignature: self.lastMenuLocalizationSignature,
            items: items)
        self.mergedSwitcherContentCaches[ObjectIdentifier(menu), default: [:]][selection] = entry
    }

    /// Returns a reusable cached content block, evicting stale entries without attaching them.
    func reusableMergedSwitcherContent(
        for selection: ProviderSwitcherSelection,
        in menu: NSMenu,
        menuWidth: CGFloat,
        codexAccountDisplay: CodexAccountMenuDisplay?,
        tokenAccountDisplay: TokenAccountMenuDisplay?)
        -> [NSMenuItem]?
    {
        let key = ObjectIdentifier(menu)
        guard let entry = self.mergedSwitcherContentCaches[key]?[selection] else { return nil }
        guard entry.matches(
            requiredMenuContentVersion: self.menuSession.latestRequiredRebuildVersion,
            menuWidth: menuWidth,
            codexAccountDisplay: codexAccountDisplay,
            tokenAccountDisplay: tokenAccountDisplay,
            localizationSignature: self.menuLocalizationSignature())
        else {
            self.mergedSwitcherContentCaches[key]?.removeValue(forKey: selection)
            return nil
        }
        return entry.items
    }

    func addCachedMergedSwitcherContent(
        for selection: ProviderSwitcherSelection,
        to menu: NSMenu,
        menuWidth: CGFloat,
        codexAccountDisplay: CodexAccountMenuDisplay?,
        tokenAccountDisplay: TokenAccountMenuDisplay?)
        -> Bool
    {
        guard let items = self.reusableMergedSwitcherContent(
            for: selection,
            in: menu,
            menuWidth: menuWidth,
            codexAccountDisplay: codexAccountDisplay,
            tokenAccountDisplay: tokenAccountDisplay)
        else { return false }

        self.lastCodexAccountMenuDisplay = codexAccountDisplay
        self.lastTokenAccountMenuDisplay = tokenAccountDisplay
        for item in items {
            menu.addItem(item)
        }
        // Detached Refresh items cannot observe a completed manual refresh. Recompute only
        // after AppKit has restored their menu so provider-scoped busy state is available.
        self.updatePersistentRefreshItemsEnabled()
        return true
    }

    /// Builds MiniMax's richer card while the user is reading the currently selected provider.
    /// The first switch can then use the same detached-item cache as subsequent switch-backs.
    func scheduleMiniMaxMergedMenuPrewarmIfNeeded(_ menu: NSMenu) {
        guard self.shouldMergeIcons,
              self.store.enabledProvidersForDisplay().contains(.minimax),
              self.lastMergedSwitcherSelection != .provider(.minimax)
        else { return }

        // An open NSMenu runs the main thread in event-tracking mode. A MainActor Task
        // continuation can therefore starve until the menu closes, defeating the prewarm.
        // Queue directly into that run-loop mode so the detached content is ready before
        // the user's first switch to MiniMax.
        ProviderSwitcherTrackingRunLoopScheduler.schedule { [weak self, weak menu] in
            guard let self, let menu else { return }
            guard self.openMenus[ObjectIdentifier(menu)] != nil else { return }
            self.prewarmMiniMaxMergedMenuContent(in: menu)
        }
    }

    func prewarmMiniMaxMergedMenuContent(in menu: NSMenu) {
        let enabledProviders = self.store.enabledProvidersForDisplay()
        guard self.shouldMergeIcons, enabledProviders.contains(.minimax) else { return }

        let tokenAccountDisplay = self.tokenAccountMenuDisplay(for: .minimax)
        let codexAccountDisplay: CodexAccountMenuDisplay? = nil
        let descriptor = self.makeMenuDescriptor(provider: .minimax, includeContextualActions: true)
        let menuWidth = self.menuCardWidth(
            for: enabledProviders,
            selectedProvider: .minimax,
            descriptor: descriptor)
        if self.reusableMergedSwitcherContent(
            for: .provider(.minimax),
            in: menu,
            menuWidth: menuWidth,
            codexAccountDisplay: codexAccountDisplay,
            tokenAccountDisplay: tokenAccountDisplay) != nil
        {
            return
        }

        let previousCodexDisplay = self.lastCodexAccountMenuDisplay
        let previousTokenDisplay = self.lastTokenAccountMenuDisplay
        defer {
            self.lastCodexAccountMenuDisplay = previousCodexDisplay
            self.lastTokenAccountMenuDisplay = previousTokenDisplay
        }

        let scratch = NSMenu()
        scratch.autoenablesItems = false
        self.addSwitcherScopedMenuContent(
            into: scratch,
            captureMenu: menu,
            context: MenuUpdateContext(
                provider: .minimax,
                currentProvider: .minimax,
                switcherSelection: .provider(.minimax),
                menuWidth: menuWidth,
                codexAccountDisplay: codexAccountDisplay,
                tokenAccountDisplay: tokenAccountDisplay,
                openAIContext: self.openAIWebContext(
                    currentProvider: .minimax,
                    showAllAccounts: tokenAccountDisplay?.showAll ?? false),
                descriptor: descriptor))
        let items = scratch.items
        scratch.removeAllItems()
        self.cacheMergedSwitcherContent(
            items,
            in: menu,
            selection: .provider(.minimax),
            context: MergedSwitcherContentCacheContext(
                menuWidth: menuWidth,
                codexAccountDisplay: codexAccountDisplay,
                tokenAccountDisplay: tokenAccountDisplay,
                contentVersion: self.menuSession.contentVersion))
    }

    func prewarmMiniMaxMergedMenuContentIfNeeded(in menu: NSMenu) {
        guard self.lastMergedSwitcherSelection != .provider(.minimax) else { return }
        self.prewarmMiniMaxMergedMenuContent(in: menu)
    }
}
