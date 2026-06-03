import AppKit

extension StatusItemController {
    private static let mergedMenuVerticalClearance: CGFloat = 8

    @objc func showMergedMenu(_ sender: NSStatusBarButton) {
        guard self.shouldMergeIcons else { return }
        let menu = self.mergedMenu ?? self.makeMenu()
        self.mergedMenu = menu
        let provider = self.resolvedMenuProvider()
        self.refreshMenuForOpenIfNeeded(menu, provider: provider)
        self.markMenuFresh(menu)

        let popupPoint = Self.trailingAlignedMenuPopupPoint(
            statusButtonBounds: sender.bounds,
            statusButtonIsFlipped: sender.isFlipped,
            menuWidth: self.renderedMenuWidth(for: menu))
        menu.popUp(positioning: nil, at: popupPoint, in: sender)
    }

    static func trailingAlignedMenuPopupPoint(
        statusButtonBounds: NSRect,
        statusButtonIsFlipped: Bool,
        menuWidth: CGFloat)
        -> NSPoint
    {
        let popupY = if statusButtonIsFlipped {
            statusButtonBounds.maxY + self.mergedMenuVerticalClearance
        } else {
            statusButtonBounds.minY - self.mergedMenuVerticalClearance
        }
        return NSPoint(
            x: statusButtonBounds.maxX - ceil(menuWidth / 2),
            y: popupY)
    }
}
