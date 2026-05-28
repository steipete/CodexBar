import AppKit

extension StatusItemController {
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        let key = ObjectIdentifier(menu)
        let previous = self.highlightedMenuItems[key]
        guard previous !== item else { return }

        if let previous {
            (previous.view as? MenuCardHighlighting)?.setHighlighted(false)
        }

        if let item, item.isEnabled {
            self.highlightedMenuItems[key] = item
            (item.view as? MenuCardHighlighting)?.setHighlighted(true)
        } else {
            self.highlightedMenuItems.removeValue(forKey: key)
        }
    }
}
