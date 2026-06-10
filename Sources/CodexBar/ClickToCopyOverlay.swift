import AppKit
import SwiftUI

struct ClickToCopyOverlay: NSViewRepresentable {
    let copyText: String

    func makeNSView(context: Context) -> ClickToCopyView {
        ClickToCopyView(copyText: self.copyText)
    }

    func updateNSView(_ nsView: ClickToCopyView, context: Context) {
        // Guard against no-op writes to avoid AppKit view invalidation on every
        // parent card SwiftUI diff (each MenuCardView body re-eval runs through
        // .overlay { ClickToCopyOverlay(...) }, which calls updateNSView even
        // when copyText is unchanged).
        guard nsView.copyText != self.copyText else { return }
        nsView.copyText = self.copyText
    }
}

final class ClickToCopyView: NSView {
    var copyText: String

    init(copyText: String) {
        self.copyText = copyText
        super.init(frame: .zero)
        self.wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        _ = event
        // Defer the pasteboard write to the next main-loop tick so it does not
        // run synchronously inside the active NSMenu tracking event loop. On
        // macOS 26, NSPasteboard.setString triggers distributed notifications
        // whose synchronous watchers can re-enter menu tracking and freeze the
        // system (visible as a multi-second beachball after the click).
        // Capturing copyText locally is intentional — the NSView may be
        // updated by SwiftUI before the async block runs.
        let text = self.copyText
        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }
}
