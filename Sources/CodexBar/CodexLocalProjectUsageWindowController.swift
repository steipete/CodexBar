import AppKit
import SwiftUI

@MainActor
final class CodexLocalProjectUsageWindowController: NSWindowController {
    static let selectedTabKey = "codexLocalProjectUsageWindowSelectedTab"
    static let frameAutosaveName = "CodexLocalProjectUsageWindow"
    static let preferredWidthMigrationKey = "codexLocalProjectUsageWindowPreferredWidthV2"

    private let store: UsageStore

    init(
        store: UsageStore,
        settings: SettingsStore,
        selection: CodexLocalProjectUsageInspectorSelection)
    {
        self.store = store
        let content = CodexLocalProjectUsageWindowView(store: store, settings: settings, selection: selection)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CodexLocalProjectUsageWindowLayout.idealSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = L("codex_workspaces_window_title")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.minSize = CodexLocalProjectUsageWindowLayout.minimumSize
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(Self.frameAutosaveName)
        Self.applyPreferredWidthIfNeeded(to: window)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showAndRefresh() {
        self.showWindow(nil)
        guard let window = self.window else { return }
        window.centerIfNeeded()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.store.scheduleCodexLocalProjectUsageRefreshIfNeeded()
    }

    func showSessions() {
        UserDefaults.standard.set(CodexLocalProjectUsageWindowTab.sessions.rawValue, forKey: Self.selectedTabKey)
        self.showAndRefresh()
    }

    private static func applyPreferredWidthIfNeeded(to window: NSWindow) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.preferredWidthMigrationKey) else { return }
        defaults.set(true, forKey: Self.preferredWidthMigrationKey)

        let currentSize = window.contentLayoutRect.size
        guard currentSize.width < CodexLocalProjectUsageWindowLayout.idealSize.width else { return }
        window.setContentSize(NSSize(
            width: CodexLocalProjectUsageWindowLayout.idealSize.width,
            height: max(currentSize.height, CodexLocalProjectUsageWindowLayout.idealSize.height)))
    }
}

extension NSWindow {
    fileprivate func centerIfNeeded() {
        guard self.frame.origin == .zero else { return }
        self.center()
    }
}
