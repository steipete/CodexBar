import AppKit

extension StatusItemController {
    static let costMenuTitle = L("Cost")

    func makeCostMenuCardItem(model: UsageMenuCardView.Model, submenu: NSMenu?) -> NSMenuItem {
        let tooltipLines = Self.costMenuTooltipLines(tokenUsage: model.tokenUsage)
        let visibleDetailLines = Self.costMenuVisibleDetailLines(tokenUsage: model.tokenUsage)
        let item = NSMenuItem(title: Self.costMenuTitle, action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.representedObject = "menuCardCost"
        item.submenu = submenu
        item.toolTip = tooltipLines.joined(separator: "\n")
        if #available(macOS 14.4, *) {
            item.subtitle = visibleDetailLines.joined(separator: "\n")
        } else if !visibleDetailLines.isEmpty {
            item.attributedTitle = Self.costMenuFallbackAttributedTitle(visibleDetailLines: visibleDetailLines)
        }
        return item
    }

    static func costMenuTooltipLines(tokenUsage: UsageMenuCardView.Model.TokenUsageSection?) -> [String] {
        [
            tokenUsage?.sessionLine,
            tokenUsage?.monthLine,
            tokenUsage?.hintLine,
            tokenUsage?.errorLine,
        ]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
    }

    static func costMenuVisibleDetailLines(tokenUsage: UsageMenuCardView.Model.TokenUsageSection?) -> [String] {
        let primaryLines = [
            tokenUsage?.sessionLine,
            tokenUsage?.monthLine,
            tokenUsage?.errorLine,
        ]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
        guard primaryLines.isEmpty else { return primaryLines }
        return [tokenUsage?.hintLine]
            .compactMap(\.self)
            .filter { !$0.isEmpty }
    }

    static func costMenuFallbackAttributedTitle(visibleDetailLines: [String]) -> NSAttributedString {
        let detailText = visibleDetailLines.joined(separator: " | ")
        let title = detailText.isEmpty ? self.costMenuTitle : "\(self.costMenuTitle)  \(detailText)"
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
