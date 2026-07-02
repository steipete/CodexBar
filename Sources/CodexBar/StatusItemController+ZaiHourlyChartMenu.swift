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
            heightCacheScope: provider.rawValue,
            heightCacheFingerprint: "zaiHourlyUsageSubmenu:\(provider.rawValue)",
            submenu: submenu,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0)
        menu.addItem(item)
        return true
    }

    func makeZaiUsageDetailsSubmenu(snapshot: UsageSnapshot?) -> NSMenu? {
        guard let timeLimit = snapshot?.zaiUsage?.timeLimit else { return nil }
        guard !timeLimit.usageDetails.isEmpty else { return nil }

        let submenu = NSMenu()
        submenu.delegate = self
        let titleItem = NSMenuItem(title: L("MCP details"), action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        submenu.addItem(titleItem)

        if let window = timeLimit.windowLabel {
            let item = NSMenuItem(title: String(format: L("mcp_window"), window), action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        if let resetTime = timeLimit.nextResetTime {
            let reset = self.settings.resetTimeDisplayStyle == .absolute
                ? UsageFormatter.resetDescription(from: resetTime)
                : UsageFormatter.resetCountdownDescription(from: resetTime)
            let item = NSMenuItem(title: String(format: L("mcp_resets"), reset), action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
        }
        submenu.addItem(.separator())

        let sortedDetails = timeLimit.usageDetails.sorted {
            $0.modelCode.localizedCaseInsensitiveCompare($1.modelCode) == .orderedAscending
        }
        for detail in sortedDetails {
            let usage = UsageFormatter.tokenCountString(detail.usage)
            let item = NSMenuItem(
                title: String(format: L("mcp_model_usage"), detail.modelCode, usage),
                action: nil,
                keyEquivalent: "")
            submenu.addItem(item)
        }
        return submenu
    }
}
