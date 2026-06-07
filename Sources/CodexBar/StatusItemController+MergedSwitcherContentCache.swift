import AppKit

struct CachedMergedSwitcherMenuContent {
    let menuContentVersion: Int
    let menuWidth: CGFloat
    let codexAccountDisplay: CodexAccountMenuDisplay?
    let tokenAccountDisplay: TokenAccountMenuDisplay?
    let localizationSignature: String
    let items: [NSMenuItem]

    func matches(
        menuContentVersion: Int,
        menuWidth: CGFloat,
        codexAccountDisplay: CodexAccountMenuDisplay?,
        tokenAccountDisplay: TokenAccountMenuDisplay?,
        localizationSignature: String)
        -> Bool
    {
        self.menuContentVersion == menuContentVersion &&
            abs(self.menuWidth - menuWidth) <= 0.5 &&
            self.codexAccountDisplay == codexAccountDisplay &&
            self.tokenAccountDisplay == tokenAccountDisplay &&
            self.localizationSignature == localizationSignature
    }
}

extension StatusItemController {
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
        guard contentStartIndex < menu.items.count else { return }
        let items = Array(menu.items[contentStartIndex...])
        guard !items.isEmpty else { return }

        let menuKey = ObjectIdentifier(menu)
        let entry = CachedMergedSwitcherMenuContent(
            menuContentVersion: self.menuVersions[menuKey] ?? self.menuContentVersion,
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
            menuContentVersion: visibleMenuVersion,
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
}
