import AppKit

extension StatusItemController {
    func addUsageHistoryClusterIfNeeded(to menu: NSMenu, context: MenuCardContext) {
        if self.addUsageHistoryMenuItemIfNeeded(
            to: menu,
            provider: context.currentProvider,
            width: context.menuWidth)
        {
            self.moveCostAndStorageRowsUnderUsageHistory(in: menu)
            menu.addItem(.separator())
        }
    }

    func moveCostAndStorageRowsUnderUsageHistory(in menu: NSMenu) {
        guard let usageHistoryItem = menu.items.first(where: {
            ($0.representedObject as? String) == "usageHistorySubmenu"
        }) else { return }

        let movableItems = menu.items.prefix { ($0.representedObject as? String) != "sharedCodexCostScope" }
        let rowIDs = ["menuCardCost", "menuCardStorage"]
        let rowsToMove = rowIDs.compactMap { rowID in
            movableItems.first { ($0.representedObject as? String) == rowID }
        }
        guard !rowsToMove.isEmpty else { return }

        for item in rowsToMove {
            menu.removeItem(item)
        }

        guard let usageHistoryIndex = menu.items.firstIndex(where: { $0 === usageHistoryItem }) else { return }
        for (offset, item) in rowsToMove.enumerated() {
            menu.insertItem(item, at: min(usageHistoryIndex + 1 + offset, menu.items.count))
        }
        for index in menu.items.indices.dropFirst().reversed()
            where menu.items[index - 1].isSeparatorItem && menu.items[index].isSeparatorItem
        {
            menu.removeItem(at: index)
        }
    }
}
