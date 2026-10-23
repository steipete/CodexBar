import AppKit
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct SessionUsageMenuActionTests {
    @Test
    func `native click target covers names amounts and blank row space`() throws {
        _ = NSApplication.shared
        let window = SessionMenuTrackingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = SessionUsageMenuActionView(frame: NSRect(x: 10, y: 20, width: 380, height: 44))
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        window.contentView?.addSubview(view)
        var activations = 0
        view.action = { activations += 1 }
        for point in [NSPoint(x: 15, y: 30), NSPoint(x: 200, y: 8), NSPoint(x: 365, y: 30)] {
            let windowPoint = view.convert(point, to: nil)
            #expect(view.hitTest(windowPoint) === view)
            let up = try Self.event(.leftMouseUp, point: windowPoint, window: window)
            window.trackedEvents = [up]
            try view.mouseDown(with: Self.event(.leftMouseDown, point: windowPoint, window: window))
        }
        #expect(activations == 3)
        #expect(window.trackingModes == [.eventTracking, .eventTracking, .eventTracking])
    }

    @Test
    func `release outside the visible row cancels activation`() throws {
        _ = NSApplication.shared
        let window = SessionMenuTrackingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = SessionUsageMenuActionView(frame: NSRect(x: 0, y: 0, width: 380, height: 44))
        window.contentView = view
        var activations = 0
        view.action = { activations += 1 }
        window.trackedEvents = try [Self.event(.leftMouseUp, point: NSPoint(x: 420, y: 60), window: window)]
        try view.mouseDown(with: Self.event(.leftMouseDown, point: NSPoint(x: 20, y: 20), window: window))
        #expect(activations == 0)
    }

    @Test
    func `first click and accessibility activation do not require SwiftUI button tracking`() {
        let view = SessionUsageMenuActionView(frame: NSRect(x: 0, y: 0, width: 380, height: 44))
        var activations = 0
        view.action = { activations += 1 }
        #expect(view.acceptsFirstMouse(for: nil))
        #expect(view.accessibilityPerformPress())
        #expect(activations == 1)
        view.action = nil
        #expect(!view.accessibilityPerformPress())
    }

    @Test
    func `nested menu closes from its root and presents after tracking ends`() {
        let root = RecordingSessionMenu()
        let child = RecordingSessionMenu()
        let item = NSMenuItem(title: "Synthetic cost history", action: nil, keyEquivalent: "")
        item.submenu = child
        root.addItem(item)
        var presentations = 0
        performAfterClosingSessionMenu(child) { presentations += 1 }
        #expect(root.cancellations == 1)
        #expect(child.cancellations == 0)
        #expect(presentations == 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        #expect(presentations == 1)
    }

    private static func event(_ type: NSEvent.EventType, point: NSPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
    }
}

/// Supplies only this test's release events, without entering a process-global AppKit loop.
@MainActor
private final class SessionMenuTrackingWindow: NSWindow {
    nonisolated(unsafe) var trackedEvents: [NSEvent] = []
    nonisolated(unsafe) var trackingModes: [RunLoop.Mode] = []

    override func trackEvents(
        matching mask: NSEvent.EventTypeMask,
        timeout _: TimeInterval,
        mode: RunLoop.Mode,
        handler: (NSEvent?, UnsafeMutablePointer<ObjCBool>) -> Void)
    {
        self.trackingModes.append(mode)
        #expect(mask.contains(.leftMouseUp))
        #expect(mask.contains(.leftMouseDragged))
        var stop = ObjCBool(false)
        for event in self.trackedEvents {
            handler(event, &stop)
            if stop.boolValue { break }
        }
        self.trackedEvents = []
    }
}

@MainActor
private final class RecordingSessionMenu: NSMenu {
    /// The tested path is main-actor-only; NSMenu's Objective-C override is nonisolated.
    nonisolated(unsafe) var cancellations = 0

    override func cancelTrackingWithoutAnimation() {
        self.cancellations += 1
    }
}
