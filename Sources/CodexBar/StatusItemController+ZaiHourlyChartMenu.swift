import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    static let zaiHourlyUsageChartID = "zaiHourlyUsageChart"

    @discardableResult
    func addZaiHourlyUsageMenuItemIfNeeded(to menu: NSMenu, provider: UsageProvider, width: CGFloat) -> Bool {
        guard provider == .zai else { return false }
        guard let snapshot = self.store.snapshot(for: provider),
              snapshot.zaiUsage?.modelUsage != nil
        else { return false }
        let submenu = self.makeHostedSubviewPlaceholderMenu(chartID: Self.zaiHourlyUsageChartID, provider: provider)
        let item = self.makeMenuCardItem(
            HStack(spacing: 0) {
                Text(L("Hourly Usage"))
                    .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 14)
                    .padding(.trailing, 28)
                    .padding(.vertical, 8)
            },
            id: "zaiHourlyUsageSubmenu",
            width: width,
            submenu: submenu,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0)
        menu.addItem(item)
        return true
    }
}
