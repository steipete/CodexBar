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
}
