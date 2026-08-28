import AppKit
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
    func `pasteboard copy waits for deferred scheduler`() {
        var pendingAction: (() -> Void)?
        var copiedText: String?
        var completed = false

        MenuPasteboardCopy.perform(
            "copy me",
            scheduler: { pendingAction = $0 },
            writer: { copiedText = $0 },
            completion: { completed = true })

        #expect(copiedText == nil)
        #expect(!completed)
        pendingAction?()
        #expect(copiedText == "copy me")
        #expect(completed)
    }

    @Test
    func `mouseDown forwards the latest copyText`() {
        var copiedText: String?
        let view = ClickToCopyView(copyText: "original") { copiedText = $0 }
        view.copyText = "updated"

        view.mouseDown(with: NSEvent())

        #expect(copiedText == "updated")
    }

    @Test
    func `accepts first mouse so error text overlay is clickable on first focus`() {
        let view = ClickToCopyView(copyText: "x")
        #expect(view.acceptsFirstMouse(for: nil) == true)
    }
}
