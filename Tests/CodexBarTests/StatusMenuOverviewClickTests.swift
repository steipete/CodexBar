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
        let view = Self.makeRow(
            Text("Overview row"),
            onClick: { clicked = true })
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        #expect(view._test_simulateRuntimeClick())
        #expect(clicked)
    }

    @Test
    func `routes gpu selection runtime click without gesture recognizer`() {
        var clicked = false
        let view = Self.makeRow(
            Text("Overview GPU row"),
            usesGPUSelection: true,
            onClick: { clicked = true })
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        #expect(view._test_simulateRuntimeClick())
        #expect(clicked)
    }

    @Test
    func `gpu tracking activates only for mouseUp inside row`() {
        let view = Self.makeRow(
            Text("Overview GPU row"),
            usesGPUSelection: true,
            onClick: {})
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        let events = Self.mouseClick(at: NSPoint(x: 160, y: 22))

        #expect(view._test_primaryPressDecision(for: events.down) == nil)
        #expect(view._test_primaryPressDecision(for: events.up) == true)
    }

    @Test
    func `gpu tracking cancels when release leaves row`() {
        let view = Self.makeRow(
            Text("Overview GPU row"),
            showsSubmenuIndicator: true,
            usesGPUSelection: true,
            onClick: {})
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        let outsideUp = Self.mouseClick(at: NSPoint(x: 340, y: 22)).up

        #expect(view._test_primaryPressDecision(for: outsideUp) == false)
    }

    @Test
    func `gpu tracking yields an outside drag to native submenu tracking`() {
        let view = Self.makeRow(
            Text("Overview GPU row"),
            showsSubmenuIndicator: true,
            usesGPUSelection: true,
            onClick: {})
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)

        let insideDrag = Self.mouseDrag(at: NSPoint(x: 160, y: 22))
        let outsideDrag = Self.mouseDrag(at: NSPoint(x: 340, y: 22))
        #expect(!view._test_primaryPressShouldYieldToMenu(for: insideDrag))
        #expect(view._test_primaryPressShouldYieldToMenu(for: outsideDrag))
    }

    @Test
    func `hitTest preserves button targets in standard hosting view`() {
        let view = Self.makeRow(
            Text("Overview row"),
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
        let view = Self.makeRow(
            Text("Overview GPU row"),
            usesGPUSelection: true,
            onClick: {})
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        let button = NSButton(frame: NSRect(x: 10, y: 10, width: 50, height: 20))
        view.addSubview(button)

        let hit = view.hitTest(NSPoint(x: 15, y: 15))
        #expect(hit !== view)
        #expect(hit === button || hit?.isDescendant(of: button) == true)
    }

    @Test
    func `gpu hosting preserves nested SwiftUI button target`() {
        let content = Button("Copy") {}
            .frame(width: 80, height: 30)
            .menuCardInteractiveControl()
            .frame(width: 320, height: 44, alignment: .trailing)
        let view = Self.makeRow(
            content,
            containsInteractiveControls: true,
            usesGPUSelection: true,
            onClick: {})
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 51)
        Self.settleWindowlessLayout(view)
        let buttonPoint = NSPoint(x: 280, y: 39)

        #expect(view._test_hitsHostedInteractiveControl(at: buttonPoint))
        #expect(!view._test_hitsHostedInteractiveControl(at: NSPoint(x: 280, y: 8)))
        #expect(view.hitTest(buttonPoint) !== view)
        #expect(!view._test_simulateRuntimeClick(at: buttonPoint))
    }

    @Test
    func `standard hosting forwards nested SwiftUI control events without invoking row`() {
        var rowClicked = false
        let content = Button("Copy") {}
            .frame(width: 80, height: 30)
            .menuCardInteractiveControl()
            .frame(width: 320, height: 44, alignment: .trailing)
        let view = Self.makeRow(
            content,
            containsInteractiveControls: true,
            onClick: { rowClicked = true })
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 51)
        Self.settleWindowlessLayout(view)
        let buttonPoint = NSPoint(x: 280, y: 39)

        #expect(view._test_hitsHostedInteractiveControl(at: buttonPoint))
        #expect(!view._test_hitsHostedInteractiveControl(at: NSPoint(x: 280, y: 8)))
        let events = Self.mouseClick(at: buttonPoint)
        view.mouseDown(with: events.down)
        view.mouseUp(with: events.up)
        let forwarded = view._test_forwardedHostedControlEvents
        #expect(forwarded.mouseDown)
        #expect(forwarded.mouseUp)
        #expect(!rowClicked)
    }

    @Test
    func `hidden SwiftUI button region keeps row clickable`() {
        var rowClicked = false
        let content = Button("Hidden copy") {}
            .frame(width: 80, height: 30)
            .menuCardInteractiveControl(isEnabled: false)
            .frame(width: 320, height: 44, alignment: .trailing)
        let view = Self.makeRow(
            content,
            containsInteractiveControls: true,
            onClick: { rowClicked = true })
        view.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        Self.settleWindowlessLayout(view)
        let buttonPoint = NSPoint(x: 280, y: 22)

        #expect(!view._test_hitsHostedInteractiveControl(at: buttonPoint))
        #expect(view._test_simulateRuntimeClick(at: buttonPoint))
        #expect(rowClicked)
    }

    private static func makeRow(
        _ content: some View,
        showsSubmenuIndicator: Bool = false,
        containsInteractiveControls: Bool = false,
        usesGPUSelection: Bool = false,
        onClick: (() -> Void)? = nil) -> MenuRowContainerView
    {
        MenuRowContainerView(
            payload: MenuCardRowPayload(
                content: AnyView(content),
                showsSubmenuIndicator: showsSubmenuIndicator,
                submenuIndicatorAlignment: .trailing,
                submenuIndicatorTopPadding: 0,
                allowsMenuHighlight: true,
                containsInteractiveControls: containsInteractiveControls,
                usesGPUSelection: usesGPUSelection,
                onClick: onClick),
            refreshMonitor: nil)
    }

    private static func settleWindowlessLayout(_ view: NSView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        view.layoutSubtreeIfNeeded()
    }

    private static func mouseClick(at point: NSPoint) -> (down: NSEvent, up: NSEvent) {
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1)!
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0)!
        return (down, up)
    }

    private static func mouseDrag(at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1)!
    }
}
