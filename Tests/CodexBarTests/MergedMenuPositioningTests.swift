import AppKit
import Testing
@testable import CodexBar

@MainActor
struct MergedMenuPositioningTests {
    @Test
    func `popup point anchors menu trailing edge to status item trailing edge`() {
        let menuWidth: CGFloat = 620
        let compact = NSRect(x: 0, y: 0, width: 44, height: 22)
        let expanded = NSRect(x: -92, y: 0, width: 136, height: 22)

        let compactPoint = StatusItemController.trailingAlignedMenuPopupPoint(
            statusButtonBounds: compact,
            statusButtonIsFlipped: true,
            menuWidth: menuWidth)
        let expandedPoint = StatusItemController.trailingAlignedMenuPopupPoint(
            statusButtonBounds: expanded,
            statusButtonIsFlipped: true,
            menuWidth: menuWidth)

        #expect(compactPoint.x == expandedPoint.x)
        #expect(compactPoint.x + ceil(menuWidth) == compact.maxX)
        #expect(expandedPoint.x + ceil(menuWidth) == expanded.maxX)
        #expect(compactPoint.y == compact.maxY + 8)
        #expect(expandedPoint.y == expanded.maxY + 8)
    }

    @Test
    func `popup point clears status item in non-flipped coordinates`() {
        let point = StatusItemController.trailingAlignedMenuPopupPoint(
            statusButtonBounds: NSRect(x: 0, y: 0, width: 44, height: 22),
            statusButtonIsFlipped: false,
            menuWidth: 620)

        #expect(point.y == -8)
    }
}
