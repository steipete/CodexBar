import AppKit
import Foundation
import SwiftUI

enum CodexWorkspacesWindowIdentity {
    static let menuItem = "codexWorkspaces"
    static let window = "com.steipete.codexbar.workspaces"
}

@MainActor
final class CodexWorkspacesPresenter {
    static let shared = CodexWorkspacesPresenter()

    private var windowController: CodexWorkspacesWindowController?

    func present() {
        self.windowControllerForPresentation().present()
    }

    func windowControllerForPresentation() -> CodexWorkspacesWindowController {
        let controller = self.windowController ?? CodexWorkspacesWindowController()
        self.windowController = controller
        return controller
    }
}

@MainActor
final class CodexWorkspacesWindowController: NSWindowController {
    private static let defaultSize = NSSize(width: 1380, height: 780)
    private static let minimumContentSize = NSSize(width: 980, height: 640)

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(CodexWorkspacesWindowIdentity.window)
        window.title = L("Workspaces")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let hostingController = NSHostingController(rootView: CodexWorkspacesWindowShell(
            minimumSize: Self.minimumContentSize))
        // Share the content minimum without adopting the empty state's intrinsic window size.
        hostingController.sizingOptions = .minSize
        window.contentViewController = hostingController
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(Self.defaultSize)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        self.showWindow(nil)
        self.window?.makeKeyAndOrderFront(nil)
    }
}

private struct CodexWorkspacesWindowShell: View {
    let minimumSize: NSSize

    var body: some View {
        ContentUnavailableView(
            L("No data yet"),
            systemImage: "folder")
            .frame(minWidth: self.minimumSize.width, minHeight: self.minimumSize.height)
    }
}

extension StatusItemController {
    @objc
    func openCodexWorkspaces(_ sender: Any?) {
        _ = sender
        CodexWorkspacesPresenter.shared.present()
    }
}
