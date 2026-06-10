import AppKit
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct ClickToCopyOverlayTests {
    @Test
    func `view stores the latest copyText`() {
        let view = ClickToCopyView(copyText: "original")
        #expect(view.copyText == "original")
        view.copyText = "updated"
        #expect(view.copyText == "updated")
    }

    @Test
    func `mouseDown writes copyText to general pasteboard asynchronously`() async throws {
        let pb = NSPasteboard.general
        // Sentinel value so we can detect whether the write actually happened.
        let sentinel = "click-to-copy-test-\(UUID().uuidString)"
        pb.clearContents()
        pb.setString("sentinel-not-replaced", forType: .string)

        let view = ClickToCopyView(copyText: sentinel)
        // NSEvent.mouseEvent requires a non-nil context for a real event; pass
        // a synthetic event constructed from CGEvent so the override runs.
        let cgEvent = try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: .zero,
            mouseButton: .left))
        let nsEvent = try #require(NSEvent(cgEvent: cgEvent))
        view.mouseDown(with: nsEvent)

        // The fix defers the pasteboard write off the current run-loop tick.
        // Yield to the main loop so the async block has a chance to run.
        try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
        #expect(pb.string(forType: .string) == sentinel)
    }

    @Test
    func `accepts first mouse so error text overlay is clickable on first focus`() {
        let view = ClickToCopyView(copyText: "x")
        #expect(view.acceptsFirstMouse(for: nil) == true)
    }
}
