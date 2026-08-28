import AppKit
import CodexBarCore

extension StatusItemController {
    @discardableResult
    func addStorageMenuCardSection(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        guard let storageText = self.store.storageFootprintText(for: provider) else { return false }
        let storageSubmenu = self.makeStorageBreakdownSubmenu(provider: provider, width: width)
        menu.addItem(Self.makeNativeStorageMenuCardItem(storageText: storageText, submenu: storageSubmenu))
        return true
    }

    private static func makeNativeStorageMenuCardItem(storageText: String, submenu: NSMenu?) -> NSMenuItem {
        let menuFont = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: L("Storage"), attributes: [.font: menuFont])
        title.append(NSAttributedString(
            string: "  \(storageText)",
            attributes: [.font: menuFont, .foregroundColor: NSColor.secondaryLabelColor]))
        let item = NSMenuItem(title: L("Storage"), action: nil, keyEquivalent: "")
        item.attributedTitle = title
        item.isEnabled = submenu != nil
        item.representedObject = "menuCardStorage"
        item.submenu = submenu
        return item
    }
}
