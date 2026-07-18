import AppKit
import CodexBarCore
import SwiftUI

private struct CostMenuCardRowView: View {
    let title: String
    let detailLines: [String]
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(self.title)
                .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
                .lineLimit(1)
            ForEach(self.detailLines.indices, id: \.self) { index in
                Text(self.detailLines[index])
                    .font(.system(size: NSFont.smallSystemFontSize))
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, 28)
        .padding(.vertical, 6)
        .frame(width: self.width, alignment: .leading)
    }
}

extension StatusItemController {
    static var costMenuTitle: String {
        L("Cost")
    }

    static func costMenuTitleForProvider(_: UsageProvider) -> String {
        self.costMenuTitle
    }

    func makeCostMenuCardItem(
        model: UsageMenuCardView.Model,
        submenu: NSMenu?,
        width: CGFloat) -> NSMenuItem
    {
        let title = Self.costMenuTitleForProvider(model.provider)
        let tooltipLines = Self.costMenuTooltipLines(provider: model.provider, tokenUsage: model.tokenUsage)
        let visibleDetailLines = Self.costMenuVisibleDetailLines(
            provider: model.provider,
            tokenUsage: model.tokenUsage,
            hasSubmenu: submenu != nil)
        guard visibleDetailLines.isEmpty == false, self.menuCardRenderingEnabledForController else {
            return Self.makeNativeCostMenuCardItem(
                title: title,
                visibleDetailLines: visibleDetailLines,
                tooltipLines: tooltipLines,
                submenu: submenu)
        }

        let item = self.makeMenuCardItem(
            CostMenuCardRowView(
                title: title,
                detailLines: visibleDetailLines,
                width: width),
            id: "menuCardCost",
            width: width,
            heightCacheScope: model.provider.rawValue,
            heightCacheFingerprint: "costMenuRow:\(visibleDetailLines.count)",
            submenu: submenu,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0)
        item.title = title
        item.toolTip = tooltipLines.joined(separator: "\n")
        return item
    }

    private static func makeNativeCostMenuCardItem(
        title: String,
        visibleDetailLines: [String],
        tooltipLines: [String],
        submenu: NSMenu?) -> NSMenuItem
    {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.representedObject = "menuCardCost"
        item.submenu = submenu
        // Submenu cost rows already show these details; keep tooltips only for inline rows
        // where they reveal truncated text and avoid flashes during in-place menu refreshes.
        if submenu == nil {
            item.toolTip = tooltipLines.joined(separator: "\n")
        }
        if #available(macOS 14.4, *) {
            item.subtitle = visibleDetailLines.joined(separator: "\n")
        } else if !visibleDetailLines.isEmpty {
            item.attributedTitle = Self.costMenuFallbackAttributedTitle(
                title: title,
                visibleDetailLines: visibleDetailLines)
        }
        return item
    }

    static func costMenuTooltipLines(
        provider _: UsageProvider,
        tokenUsage: UsageMenuCardView.Model.TokenUsageSection?) -> [String]
    {
        let lines = [
            tokenUsage?.sessionLine,
            tokenUsage?.monthLine,
            tokenUsage?.meteredLine,
        ]
            .compactMap(\.self)
            + (tokenUsage?.comparisonLines ?? [])
            + [tokenUsage?.hintLine, tokenUsage?.errorLine].compactMap(\.self)
        return lines.filter { !$0.isEmpty }
    }

    static func costMenuVisibleDetailLines(
        provider: UsageProvider,
        tokenUsage: UsageMenuCardView.Model.TokenUsageSection?,
        hasSubmenu: Bool) -> [String]
    {
        guard !hasSubmenu else { return [] }
        let primaryLines = ([
            tokenUsage?.sessionLine,
            tokenUsage?.monthLine,
            tokenUsage?.meteredLine,
        ]
            .compactMap(\.self)
            + (tokenUsage?.comparisonLines ?? [])
            + [provider == .codex ? tokenUsage?.hintLine : nil].compactMap(\.self)
            + [tokenUsage?.errorLine].compactMap(\.self))
            .filter { !$0.isEmpty }
        guard primaryLines.isEmpty else { return primaryLines }
        return [tokenUsage?.hintLine]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
    }

    static func costMenuFallbackAttributedTitle(
        title: String,
        visibleDetailLines: [String]) -> NSAttributedString
    {
        let detailText = visibleDetailLines.joined(separator: " | ")
        let title = detailText.isEmpty ? title : "\(title)  \(detailText)"
        let attributedTitle = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: NSFont.systemFontSize)])
        guard !detailText.isEmpty else { return attributedTitle }

        let detailRange = (title as NSString).range(of: detailText)
        attributedTitle.addAttributes(
            [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ],
            range: detailRange)
        return attributedTitle
    }
}
