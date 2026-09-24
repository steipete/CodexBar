import AppKit
import SwiftUI

private final class RecentWindowsMenuHostingView<Content: View>: NSHostingView<Content> {
    override var allowsVibrancy: Bool {
        true
    }
}

extension StatusItemController {
    static let recentWindowsSubmenuID = "recentWindowsSubmenu"

    /// Adds a "Recent windows" row whose quota windows open as a submenu on hover, keeping the card compact.
    @discardableResult
    func addRecentWindowsMenuItemIfNeeded(
        to menu: NSMenu,
        dashboard: InlineUsageDashboardModel?,
        width: CGFloat) -> Bool
    {
        guard let windows = dashboard?.quotaWindows, !windows.isEmpty else { return false }
        let item = NSMenuItem(title: L("Recent windows"), action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.representedObject = Self.recentWindowsSubmenuID
        item.submenu = self.makeRecentWindowsSubmenu(windows: windows, width: width)
        menu.addItem(item)
        return true
    }

    func makeRecentWindowsSubmenu(
        windows: [InlineUsageDashboardModel.QuotaWindow],
        width: CGFloat) -> NSMenu
    {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.minimumWidth = width

        let contentItem = NSMenuItem()
        contentItem.isEnabled = true
        if self.menuCardRenderingEnabledForController {
            let hosting = RecentWindowsMenuHostingView(rootView: InlineUsageQuotaWindowsView(windows: windows)
                .padding(.horizontal, UsageMenuCardLayout.horizontalPadding)
                .padding(.vertical, 8)
                .frame(width: width, alignment: .leading))
            hosting.frame = NSRect(
                origin: .zero,
                size: NSSize(width: width, height: self.hostedSubviewFittingHeight(for: hosting, width: width)))
            contentItem.view = hosting
        }
        submenu.addItem(contentItem)
        return submenu
    }
}
