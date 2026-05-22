import AppKit

extension StatusItemController {
    static let costMenuTitle = "Cost"

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
        var lines: [String] = []
        if let tokenUsage {
            lines.append(tokenUsage.sessionLine)
            lines.append(tokenUsage.monthLine)
            if let energySession = tokenUsage.energySessionLine {
                lines.append(energySession)
            }
            if let co2Session = tokenUsage.co2SessionLine {
                lines.append(co2Session)
            }
            if let energyMonth = tokenUsage.energyMonthLine {
                lines.append(energyMonth)
            }
            if let co2Month = tokenUsage.co2MonthLine {
                lines.append(co2Month)
            }
            if let hint = tokenUsage.hintLine, !hint.isEmpty {
                lines.append(hint)
            }
            if let error = tokenUsage.errorLine, !error.isEmpty {
                lines.append(error)
            }
        }
        return lines.filter { !$0.isEmpty }
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
