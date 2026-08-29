import AppKit
import Foundation
import SwiftUI

enum CodexWorkspacesMenuAvailability {
    static let environmentKey = "CODEXBAR_ENABLE_WORKSPACES_MENU"

    static var isEnabledForCurrentProcess: Bool {
        self.isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        #if DEBUG
        return environment[self.environmentKey] == "1"
        #else
        _ = environment
        return false
        #endif
    }
}

enum CodexWorkspacesWindowIdentity {
    static let menuItem = "codexWorkspaces"
    static let window = "com.steipete.codexbar.workspaces"
    static let frameAutosaveName = "CodexBar.WorkspacesWindow"
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
    fileprivate static let minimumSize = NSSize(width: 980, height: 640)

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(CodexWorkspacesWindowIdentity.window)
        window.title = L("Workspaces")
        window.minSize = Self.minimumSize
        window.contentMinSize = window.contentRect(
            forFrameRect: NSRect(origin: .zero, size: Self.minimumSize)).size
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let contentViewController = NSHostingController(rootView: CodexWorkspacesWindowShell())
        contentViewController.sizingOptions = []
        window.contentViewController = contentViewController
        window.setFrameAutosaveName(CodexWorkspacesWindowIdentity.frameAutosaveName)
        if window.setFrameUsingName(CodexWorkspacesWindowIdentity.frameAutosaveName) {
            window.setFrame(
                Self.constrainedFrame(window.frame, minimumSize: Self.minimumSize),
                display: false)
        } else {
            window.center()
        }
        super.init(window: window)
    }

    static func constrainedFrame(_ frame: NSRect, minimumSize: NSSize) -> NSRect {
        NSRect(
            origin: frame.origin,
            size: NSSize(
                width: max(frame.width, minimumSize.width),
                height: max(frame.height, minimumSize.height)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        self.showWindow(nil)
        guard let window = self.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.setFrame(
            Self.constrainedFrame(window.frame, minimumSize: Self.minimumSize),
            display: false)
    }
}

private struct CodexWorkspacesWindowShell: View {
    var body: some View {
        ContentUnavailableView(
            L("No data yet"),
            systemImage: "folder")
            .frame(
                minWidth: CodexWorkspacesWindowController.minimumSize.width,
                minHeight: CodexWorkspacesWindowController.minimumSize.height)
    }
}

extension StatusItemController {
    @objc
    func openCodexWorkspaces(_ sender: Any?) {
        _ = sender
        CodexWorkspacesPresenter.shared.present()
    }
}
