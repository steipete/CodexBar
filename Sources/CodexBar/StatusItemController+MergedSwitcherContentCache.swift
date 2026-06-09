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
        guard !items.isEmpty else { return }

        let entry = CachedMergedSwitcherMenuContent(
            requiredMenuContentVersion: contentVersion ??
                self.menuVersions[ObjectIdentifier(menu)] ??
                self.latestRequiredMenuRebuildVersion,
            menuWidth: menuWidth,
            codexAccountDisplay: self.lastCodexAccountMenuDisplay,
            tokenAccountDisplay: self.lastTokenAccountMenuDisplay,
            localizationSignature: self.lastMenuLocalizationSignature,
            items: items)
        self.mergedSwitcherContentCaches[ObjectIdentifier(menu), default: [:]][selection] = entry
    }

    func addCachedMergedSwitcherContent(
        for selection: ProviderSwitcherSelection,
        to menu: NSMenu,
        menuWidth: CGFloat,
        codexAccountDisplay: CodexAccountMenuDisplay?,
        tokenAccountDisplay: TokenAccountMenuDisplay?)
        -> Bool
    {
        let key = ObjectIdentifier(menu)
        guard let entry = self.mergedSwitcherContentCaches[key]?[selection] else { return false }
        guard entry.matches(
            requiredMenuContentVersion: self.latestRequiredMenuRebuildVersion,
            menuWidth: menuWidth,
            codexAccountDisplay: codexAccountDisplay,
            tokenAccountDisplay: tokenAccountDisplay,
            localizationSignature: self.menuLocalizationSignature())
        else {
            self.mergedSwitcherContentCaches[key]?.removeValue(forKey: selection)
            return false
        }

        self.lastCodexAccountMenuDisplay = codexAccountDisplay
        self.lastTokenAccountMenuDisplay = tokenAccountDisplay
        for item in entry.items {
            menu.addItem(item)
        }
        return true
    }
}
