import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuOverviewClickTests {
    @Test
    func `routes runtime click without gesture recognizer`() {
        var clicked = false
        let view = MenuCardItemHostingView(
            rootView: Text("Overview row"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            onClick: { clicked = true })
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        #expect(view._test_simulateRuntimeClick())
        #expect(clicked)
    }

    @Test
    func `routes gpu selection runtime click without gesture recognizer`() {
        var clicked = false
        let wrapped = MenuCardSectionContainerView(
            highlightState: MenuCardHighlightState(),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0,
            refreshMonitor: nil)
        {
            Text("Overview GPU row")
        }
        let view = GPUSelectionHostingView(
            rootView: wrapped,
            allowsMenuHighlight: true,
            onClick: { clicked = true })
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        #expect(view._test_simulateRuntimeClick())
        #expect(clicked)
    }

    @Test
    func `hitTest preserves button targets in standard hosting view`() {
        let view = MenuCardItemHostingView(
            rootView: Text("Overview row"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            onClick: {})
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        let button = NSButton(frame: NSRect(x: 10, y: 10, width: 50, height: 20))
        view.addSubview(button)

        let hit = view.hitTest(NSPoint(x: 15, y: 15))
        #expect(hit !== view)
        #expect(hit === button || hit?.isDescendant(of: button) == true)
    }

    @Test
    func `hitTest preserves button targets in gpu selection hosting view`() {
        let wrapped = MenuCardSectionContainerView(
            highlightState: MenuCardHighlightState(),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0,
            refreshMonitor: nil)
        {
            Text("Overview GPU row")
        }
        let view = GPUSelectionHostingView(
            rootView: wrapped,
            allowsMenuHighlight: true,
            onClick: {})
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        let button = NSButton(frame: NSRect(x: 10, y: 10, width: 50, height: 20))
        view.addSubview(button)

        let hit = view.hitTest(NSPoint(x: 15, y: 15))
        #expect(hit !== view)
        #expect(hit === button || hit?.isDescendant(of: button) == true)
    }
}
