import AppKit
import SwiftUI

@MainActor
enum MenuPasteboardCopy {
    typealias DeferredAction = @MainActor @Sendable () -> Void
    typealias Scheduler = @MainActor @Sendable (@escaping DeferredAction) -> Void
    typealias Writer = @MainActor @Sendable (String) -> Void

    static func perform(
        _ text: String,
        scheduler: Scheduler = Self.schedule,
        writer: @escaping Writer = Self.write,
        completion: @escaping DeferredAction = {})
    {
        scheduler {
            writer(text)
            completion()
        }
    }

    private static func schedule(_ action: @escaping DeferredAction) {
        DispatchQueue.main.async(execute: action)
    }

    private static func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

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
    private let copyAction: (String) -> Void

    init(
        copyText: String,
        copyAction: @escaping (String) -> Void = { MenuPasteboardCopy.perform($0) })
    {
        self.copyText = copyText
        self.copyAction = copyAction
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
        self.copyAction(self.copyText)
    }
}
