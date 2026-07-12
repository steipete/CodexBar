import AppKit
import SwiftUI
import Testing
@testable import CodexBar

// Regression coverage for GitHub issue #2090: MenuCardItemHostingView used to deliver `onClick`
// through an NSClickGestureRecognizer, which — like the NSButton dispatch fixed for the provider
// switcher in #867 — can be dropped by NSMenu's tracking run loop when the row is rebuilt under
// the cursor. The fix routes clicks through the view's own hitTest/mouseDown/mouseUp instead, the
// same technique #867 used, so a click never has to round-trip through a gesture recognizer's
// begin→end state machine inside the tracking loop.
@MainActor
struct MenuCardItemHostingViewClickTests {
    @Test
    func `routes runtime click without gesture recognizer`() {
        var clicked = false
        let view = MenuCardItemHostingView(
            rootView: Text("Overview row"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            onClick: { clicked = true })

        #expect(view._test_simulateRuntimeClick())
        #expect(clicked)
    }

    @Test
    func `runtime click still routes correctly after prepareForReuse`() {
        // Mirrors how the overview menu actually drives this view: a background refresh calls
        // prepareForReuse in place on an existing row instead of tearing it down. The original
        // gesture-recognizer path could have a begun-but-not-completed gesture disturbed by the
        // in-place SwiftUI diff; the hitTest/mouseDown/mouseUp path has no such state to disturb.
        var firstClicked = false
        let view = MenuCardItemHostingView(
            rootView: Text("Row A"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            onClick: { firstClicked = true })

        var secondClicked = false
        view.prepareForReuse(
            rootView: Text("Row B"),
            allowsMenuHighlight: true,
            onClick: { secondClicked = true })

        #expect(view._test_simulateRuntimeClick())
        #expect(!firstClicked)
        #expect(secondClicked)
    }

    @Test
    func `mouse up outside bounds cancels the click`() {
        var clicked = false
        let view = MenuCardItemHostingView(
            rootView: Text("Overview row"),
            highlightState: MenuCardHighlightState(),
            allowsMenuHighlight: true,
            onClick: { clicked = true })
        view.setFrameSize(NSSize(width: 200, height: 24))

        guard let mouseDownEvent = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 100, y: 12), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
            let mouseUpEvent = NSEvent.mouseEvent(
                with: .leftMouseUp, location: NSPoint(x: 100, y: 999), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)
        else {
            Issue.record("failed to construct synthetic mouse events")
            return
        }
        view.mouseDown(with: mouseDownEvent)
        view.mouseUp(with: mouseUpEvent)

        #expect(!clicked)
    }
}
