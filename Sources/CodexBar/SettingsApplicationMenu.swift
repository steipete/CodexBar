import AppKit

@MainActor
enum SettingsApplicationMenu {
    static let fallbackItemIdentifier = NSUserInterfaceItemIdentifier("com.steipete.codexbar.settings-fallback")

    enum RepairResult: Equatable {
        case unchanged(isFallback: Bool)
        case retryNeeded
        case repaired(previousCount: Int, installedFallback: Bool)
        case missingApplicationMenu
    }

    static func candidateCount(in mainMenu: NSMenu, localizedTitle: String) -> Int {
        guard let applicationMenu = mainMenu.items.first?.submenu else { return 0 }
        return self.candidates(in: applicationMenu, localizedTitle: localizedTitle).count
    }

    static func ensureSingleItem(
        in mainMenu: NSMenu,
        localizedTitle: String,
        target: AnyObject,
        action: Selector,
        allowMissingItemRepair: Bool = false)
        -> RepairResult
    {
        guard let applicationMenu = mainMenu.items.first?.submenu else {
            return .missingApplicationMenu
        }
        let candidates = self.candidates(in: applicationMenu, localizedTitle: localizedTitle)
        if candidates.count == 1,
           let candidate = candidates.first,
           candidate.item.title == localizedTitle,
           candidate.item.action != nil
        {
            return .unchanged(isFallback: candidate.item.identifier == self.fallbackItemIdentifier)
        }
        if candidates.isEmpty, !allowMissingItemRepair {
            return .retryNeeded
        }

        let previousCount = candidates.count
        if candidates.count > 1,
           let nativeCandidate = candidates.first(where: {
               $0.item.identifier != self.fallbackItemIdentifier
                   && $0.item.title == localizedTitle
                   && $0.item.action != nil
           })
        {
            for candidate in candidates.reversed() where candidate.item !== nativeCandidate.item {
                candidate.menu.removeItem(candidate.item)
            }
            return .repaired(previousCount: previousCount, installedFallback: false)
        }

        let preferredIndex = candidates
            .first?
            .index
            ?? applicationMenu.items.firstIndex(where: \.isSeparatorItem).map { $0 + 1 }
            ?? applicationMenu.items.count
        for candidate in candidates.reversed() {
            candidate.menu.removeItem(candidate.item)
        }

        let item = NSMenuItem(title: localizedTitle, action: action, keyEquivalent: ",")
        item.identifier = self.fallbackItemIdentifier
        item.keyEquivalentModifierMask = .command
        item.target = target
        applicationMenu.insertItem(item, at: min(preferredIndex, applicationMenu.items.count))
        return .repaired(previousCount: previousCount, installedFallback: true)
    }

    private static func candidates(in applicationMenu: NSMenu, localizedTitle: String)
        -> [(menu: NSMenu, index: Int, item: NSMenuItem)]
    {
        applicationMenu.items.enumerated().compactMap { index, item in
            guard item.title == localizedTitle || item.keyEquivalent == "," else { return nil }
            return (menu: applicationMenu, index: index, item: item)
        }
    }
}
