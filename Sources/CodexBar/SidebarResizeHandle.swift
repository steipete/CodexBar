import AppKit
import SwiftUI

/// Input-only drag strip that resizes the settings sidebar. It draws nothing — the
/// visible hairline stays the `Divider()` in `PreferencesView` — and rides as an
/// overlay on the detail pane's leading edge, which sits exactly on the
/// sidebar/content boundary. Overlaying the detail side (instead of the sidebar's
/// trailing edge) keeps the strip clear of the sidebar list's scroller, and staying
/// out of the `HStack` keeps it from disturbing SwiftUI's width negotiation.
///
/// AppKit mouse tracking is deliberate: a SwiftUI `DragGesture` re-enters layout per
/// event and jitters, while `mouseDown`/`mouseDragged` on an `NSView` report window
/// coordinates that stay stable even as the strip itself moves mid-drag.
///
/// The hover cursor comes from `resetCursorRects()`, not from calling `NSCursor.set()`
/// on hover: SwiftUI re-renders the settings panes continuously, and each render resets
/// the cursor, so an imperatively-set cursor survives only until the next frame (the
/// familiar "resize cursor flashes then reverts" bug). A cursor *rect* is declarative —
/// AppKit re-asks the view whenever it invalidates — so it holds. Measured on a probe
/// harness hosting this view: imperative-only was 0% resize on hover and 40% during a
/// drag; with cursor rects it is 100% in both.
struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var width: Double
    let minWidth: Double
    let maxWidth: Double

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        let view = SidebarResizeHandleView()
        self.configure(view)
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {
        self.configure(nsView)
    }

    private func configure(_ view: SidebarResizeHandleView) {
        view.getWidth = { self.width }
        view.setWidth = { newWidth in
            self.width = min(max(newWidth, self.minWidth), self.maxWidth)
        }
    }
}

final class SidebarResizeHandleView: NSView {
    /// Width of the grabbable strip; matches the slop AppKit gives thin split-view dividers.
    static let grabWidth: CGFloat = 12

    var getWidth: (() -> Double)?
    var setWidth: ((Double) -> Void)?

    private var dragStartX: CGFloat = 0
    private var dragStartWidth: Double = 0
    private var trackingArea: NSTrackingArea?

    /// Clicks here must resize, never drag the window (the strip reaches up into the
    /// transparent-titlebar region).
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// Cursor rects are the load-bearing mechanism: AppKit re-asks the view for them
    /// every time they're invalidated, so the resize cursor survives SwiftUI's constant
    /// re-rendering. A one-shot `NSCursor.set()` does not — it wins only until the next
    /// render, which is what makes hand-rolled dividers flicker back to an arrow.
    override func resetCursorRects() {
        super.resetCursorRects()
        self.addCursorRect(self.bounds, cursor: .resizeLeftRight)
    }

    override func layout() {
        super.layout()
        // The strip moves with the sidebar, so its cursor rect must be recomputed.
        self.window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            self.removeTrackingArea(trackingArea)
        }
        // Explicit rect, not `.inVisibleRect`: the hosting view doesn't clip, so
        // `visibleRect` spans the whole window and the callbacks never fire.
        // `.cursorUpdate` backs up the cursor rect for the moments AppKit skips it.
        let area = NSTrackingArea(
            rect: self.bounds,
            options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(area)
        self.trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        self.dragStartX = event.locationInWindow.x
        self.dragStartWidth = self.getWidth?() ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        let deltaX = event.locationInWindow.x - self.dragStartX
        // Sidebar sits left of the strip: dragging right (positive delta) grows it.
        self.setWidth?(self.dragStartWidth + Double(deltaX))
        // Keep the resize cursor while the pointer strays outside the moving strip.
        NSCursor.resizeLeftRight.set()
    }
}
