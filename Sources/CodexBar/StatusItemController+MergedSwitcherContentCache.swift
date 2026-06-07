import AppKit

struct CachedMergedSwitcherMenuContent {
    let menuContentVersion: Int
    let menuWidth: CGFloat
    let codexAccountDisplay: CodexAccountMenuDisplay?
    let tokenAccountDisplay: TokenAccountMenuDisplay?
    let localizationSignature: String
    let items: [NSMenuItem]

    func matches(
        minimumMenuContentVersion: Int,
        menuWidth: CGFloat,
        codexAccountDisplay: CodexAccountMenuDisplay?,
        tokenAccountDisplay: TokenAccountMenuDisplay?,
        localizationSignature: String)
        -> Bool
    {
        self.menuContentVersion >= minimumMenuContentVersion &&
            abs(self.menuWidth - menuWidth) <= 0.5 &&
            self.codexAccountDisplay == codexAccountDisplay &&
            self.tokenAccountDisplay == tokenAccountDisplay &&
            self.localizationSignature == localizationSignature
    }
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
        menuWidth: CGFloat)
    {
        guard self.shouldMergeIcons else { return }
        guard menu.items.first?.view is ProviderSwitcherView else { return }
        guard contentStartIndex < menu.items.count else { return }
        let items = Array(menu.items[contentStartIndex...])
        guard !items.isEmpty else { return }

        let menuKey = ObjectIdentifier(menu)
        let entry = CachedMergedSwitcherMenuContent(
            menuContentVersion: self.menuContentVersion,
            menuWidth: menuWidth,
            codexAccountDisplay: self.lastCodexAccountMenuDisplay,
            tokenAccountDisplay: self.lastTokenAccountMenuDisplay,
            localizationSignature: self.lastMenuLocalizationSignature,
            items: items)
        self.mergedSwitcherContentCaches[menuKey, default: [:]][selection] = entry
    }

    func cachedMergedSwitcherContent(
        for selection: ProviderSwitcherSelection,
        in menu: NSMenu,
        menuWidth: CGFloat,
        codexAccountDisplay: CodexAccountMenuDisplay?,
        tokenAccountDisplay: TokenAccountMenuDisplay?)
        -> [NSMenuItem]?
    {
        let menuKey = ObjectIdentifier(menu)
        guard let entry = self.mergedSwitcherContentCaches[menuKey]?[selection] else { return nil }
        let visibleMenuVersion = self.menuVersions[menuKey] ?? self.menuContentVersion
        guard visibleMenuVersion >= self.latestRequiredMenuRebuildVersion else {
            self.mergedSwitcherContentCaches[menuKey]?.removeValue(forKey: selection)
            return nil
        }
        guard entry.matches(
            minimumMenuContentVersion: self.latestRequiredMenuRebuildVersion,
            menuWidth: menuWidth,
            codexAccountDisplay: codexAccountDisplay,
            tokenAccountDisplay: tokenAccountDisplay,
            localizationSignature: self.menuLocalizationSignature())
        else {
            self.mergedSwitcherContentCaches[menuKey]?.removeValue(forKey: selection)
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
        guard let cachedItems = self.cachedMergedSwitcherContent(
            for: selection,
            in: menu,
            menuWidth: menuWidth,
            codexAccountDisplay: codexAccountDisplay,
            tokenAccountDisplay: tokenAccountDisplay)
        else { return false }

        self.lastCodexAccountMenuDisplay = codexAccountDisplay
        self.lastTokenAccountMenuDisplay = tokenAccountDisplay
        for item in cachedItems {
            menu.addItem(item)
        }
        return true
    }
}
