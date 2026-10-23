import AppKit
import SwiftUI

/// Transparent native hit target for actions inside a custom NSMenu item.
struct SessionUsageMenuAction: NSViewRepresentable {
    let label: String
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> SessionUsageMenuActionView {
        let view = SessionUsageMenuActionView()
        self.updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SessionUsageMenuActionView, context _: Context) {
        view.action = self.action
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(self.label)
        view.toolTip = self.label
    }
}

final class SessionUsageMenuActionView: NSView {
    var action: (@MainActor () -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let action = self.action else { return false }
        action()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window = self.window,
              self.bounds.contains(self.locationInView(for: event, window: window)), let action = self.action
        else { return }

        // NSMenu can consume mouseUp before SwiftUI buttons receive it. Own the release tracking,
        // as native menu-card rows do, and keep drag-out cancellation instead of firing on press.
        var activate = false
        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking)
        { [weak self] tracked, stop in
            guard let self, let tracked else {
                stop.pointee = true
                return
            }
            let inside = self.window === window
                && self.visibleRect.contains(self.locationInView(for: tracked, window: window))
            if tracked.type == .leftMouseDragged, !inside {
                window.postEvent(tracked, atStart: true)
                stop.pointee = true
            } else if tracked.type == .leftMouseUp {
                activate = inside
                stop.pointee = true
            }
        }
        if activate { action() }
    }

    private func locationInView(for event: NSEvent, window: NSWindow) -> NSPoint {
        let point = if let source = event.window, source !== window {
            window.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow))
        } else {
            event.locationInWindow
        }
        return self.convert(point, from: nil)
    }
}

@MainActor
func performAfterClosingSessionMenu(_ menu: NSMenu?, action: @escaping @MainActor () -> Void) {
    var root = menu
    while let parent = root?.supermenu {
        root = parent
    }
    root?.cancelTrackingWithoutAnimation()
    // Present only once AppKit has left all nested menu tracking loops.
    RunLoop.main.perform(inModes: [.default]) {
        MainActor.assumeIsolated { action() }
    }
}
