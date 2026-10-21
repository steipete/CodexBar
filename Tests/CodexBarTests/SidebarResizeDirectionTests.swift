import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct SidebarResizeDirectionTests {
    @Test(arguments: [(LayoutDirection.leftToRight, 280.0), (.rightToLeft, 240.0)])
    func `sidebar drag follows the side of the localized layout`(direction: LayoutDirection, expected: Double) throws {
        let view = SidebarResizeHandleView()
        var width = 260.0
        view.layoutDirection = direction
        view.getWidth = { width }
        view.setWidth = { width = $0 }
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 0),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        let drag = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 120, y: 0),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1))
        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        #expect(width == expected)
    }
}
