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

    @Test
    func `standard hosting preserves nested SwiftUI button presses`() {
        var rowClicked = false
        let interactiveRegionStore = MenuCardInteractiveRegionStore()
        let content = Button("Copy") {}
            .frame(width: 80, height: 30)
            .menuCardInteractiveControl()
            .frame(width: 320, height: 44, alignment: .trailing)
        let wrapped = MenuCardSectionContainerView(
            highlightState: MenuCardHighlightState(),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0,
            refreshMonitor: nil,
            interactiveRegionStore: interactiveRegionStore)
        {
            content
        }
        let view = MenuCardItemHostingView(
            rootView: wrapped,
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            containsInteractiveControls: true,
            interactiveRegionStore: interactiveRegionStore,
            onClick: { rowClicked = true })
        let window = Self.hostInWindow(view, height: 51)
        defer { window.close() }
        let buttonPoint = NSPoint(x: 280, y: 39)

        #expect(view._test_hitsHostedInteractiveControl(at: buttonPoint))
        #expect(!view._test_hitsHostedInteractiveControl(at: NSPoint(x: 280, y: 8)))
        let events = Self.mouseClick(at: buttonPoint, in: window)
        view.mouseDown(with: events.down)
        view.mouseUp(with: events.up)
        #expect(!rowClicked)
    }

    @Test
    func `gpu hosting preserves nested SwiftUI button target`() {
        let interactiveRegionStore = MenuCardInteractiveRegionStore()
        let content = Button("Copy") {}
            .frame(width: 80, height: 30)
            .menuCardInteractiveControl()
            .frame(width: 320, height: 44, alignment: .trailing)
        let wrapped = MenuCardSectionContainerView(
            highlightState: MenuCardHighlightState(),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0,
            refreshMonitor: nil,
            interactiveRegionStore: interactiveRegionStore)
        {
            content
        }
        let view = GPUSelectionHostingView(
            rootView: wrapped,
            allowsMenuHighlight: true,
            containsInteractiveControls: true,
            interactiveRegionStore: interactiveRegionStore,
            onClick: {})
        let window = Self.hostInWindow(view, height: 51)
        defer { window.close() }
        let buttonPoint = NSPoint(x: 280, y: 39)

        #expect(view._test_hitsHostedInteractiveControl(at: buttonPoint))
        #expect(!view._test_hitsHostedInteractiveControl(at: NSPoint(x: 280, y: 8)))
        #expect(view.hitTest(buttonPoint) !== view)
    }

    @Test
    func `hidden SwiftUI button region keeps row clickable`() {
        var rowClicked = false
        let interactiveRegionStore = MenuCardInteractiveRegionStore()
        let content = Button("Hidden copy") {}
            .frame(width: 80, height: 30)
            .menuCardInteractiveControl(isEnabled: false)
            .frame(width: 320, height: 44, alignment: .trailing)
        let wrapped = MenuCardSectionContainerView(
            highlightState: MenuCardHighlightState(),
            showsSubmenuIndicator: false,
            submenuIndicatorAlignment: .trailing,
            submenuIndicatorTopPadding: 0,
            refreshMonitor: nil,
            interactiveRegionStore: interactiveRegionStore)
        {
            content
        }
        let view = MenuCardItemHostingView(
            rootView: wrapped,
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            containsInteractiveControls: true,
            interactiveRegionStore: interactiveRegionStore,
            onClick: { rowClicked = true })
        let window = Self.hostInWindow(view)
        defer { window.close() }
        let buttonPoint = NSPoint(x: 280, y: 22)

        #expect(!view._test_hitsHostedInteractiveControl(at: buttonPoint))
        let events = Self.mouseClick(at: buttonPoint, in: window)
        view.mouseDown(with: events.down)
        view.mouseUp(with: events.up)
        #expect(rowClicked)
    }

    private static func hostInWindow(_ view: NSView, height: CGFloat = 44) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 320, height: height)
        view.frame = frame
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        let container = NSView(frame: frame)
        container.addSubview(view)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return window
    }

    private static func mouseClick(at point: NSPoint, in window: NSWindow) -> (down: NSEvent, up: NSEvent) {
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1)!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0)!
        return (down, up)
    }
}
