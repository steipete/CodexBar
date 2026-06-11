import AppKit

extension StatusItemController {
    private static let mergedMenuVerticalClearance: CGFloat = 8

    @objc func showMergedMenu(_ sender: NSStatusBarButton) {
        guard self.shouldMergeIcons else { return }
        let menu = self.prepareMergedMenuForPresentation()

        let popupPoint = Self.trailingAlignedMenuPopupPoint(
            statusButtonBounds: sender.bounds,
            statusButtonIsFlipped: sender.isFlipped,
            menuWidth: self.renderedMenuWidth(for: menu))
        menu.popUp(positioning: nil, at: popupPoint, in: sender)
    }

    func prepareMergedMenuForPresentation() -> NSMenu {
        let menu = self.mergedMenu ?? self.makeMenu()
        self.mergedMenu = menu
        let provider = self.resolvedMenuProvider()
        self.refreshMenuForOpenIfNeeded(menu, provider: provider)
        return menu
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
            x: statusButtonBounds.maxX - ceil(menuWidth),
            y: popupY)
    }
}
