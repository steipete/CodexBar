import AppKit
import CodexBarCore

/// CodexBar's preferences live in ``SettingsWindowController``. The SwiftUI `Settings` scene is an empty
/// placeholder that only carries the app-menu command group, and because it is the app's only scene macOS
/// presents it during launch, showing an empty "CodexBar Settings" window (#3053).
enum PlaceholderSettingsWindowDecision {
    /// SwiftUI names the window of a `Settings` scene with this fragment (identifier and frame autosave name).
    static let swiftUISettingsNameFragment = "com_apple_SwiftUI_Settings"

    /// A window CodexBar never wants onscreen: SwiftUI's placeholder Settings window.
    static func shouldClose(identifier: String?, frameAutosaveName: String, isKnownSettingsWindow: Bool) -> Bool {
        guard !isKnownSettingsWindow, identifier != SettingsWindowIdentity.identifier else { return false }
        if let identifier, identifier.contains(self.swiftUISettingsNameFragment) { return true }
        return frameAutosaveName.contains(self.swiftUISettingsNameFragment)
    }
}

/// Closes the empty SwiftUI `Settings` placeholder window whenever macOS presents it, so the AppKit
/// Settings window stays CodexBar's only preferences surface.
@MainActor
final class PlaceholderSettingsWindowGuard {
    typealias WindowsProvider = @MainActor () -> [NSWindow]
    typealias WindowPredicate = @MainActor (NSWindow) -> Bool
    typealias WindowAction = @MainActor (NSWindow) -> Void

    private let windows: WindowsProvider
    private let isKnownSettingsWindow: WindowPredicate
    private let closeWindow: WindowAction
    private let logger = CodexBarLog.logger(LogCategories.app)
    private var isStarted = false

    init(
        windows: @escaping WindowsProvider = { NSApp?.windows ?? [] },
        isKnownSettingsWindow: @escaping WindowPredicate = { _ in false },
        closeWindow: @escaping WindowAction = { $0.close() })
    {
        self.windows = windows
        self.isKnownSettingsWindow = isKnownSettingsWindow
        self.closeWindow = closeWindow
    }

    /// Sweeps once and keeps sweeping as window state changes; SwiftUI presents the placeholder after
    /// `applicationWillFinishLaunching`, and window restoration can bring it back later.
    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true
        let center = NotificationCenter.default
        for name in [
            NSApplication.didFinishLaunchingNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didUpdateNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(self.windowStateDidChange(_:)),
                name: name,
                object: nil)
        }
        self.sweep()
    }

    @discardableResult
    func sweep() -> Int {
        var closedCount = 0
        for window in self.windows() {
            guard PlaceholderSettingsWindowDecision.shouldClose(
                identifier: window.identifier?.rawValue,
                frameAutosaveName: window.frameAutosaveName,
                isKnownSettingsWindow: self.isKnownSettingsWindow(window))
            else { continue }
            self.closeWindow(window)
            closedCount += 1
        }
        if closedCount > 0 {
            self.logger.info(
                "Closed placeholder SwiftUI Settings window",
                metadata: ["count": "\(closedCount)"])
        }
        return closedCount
    }

    @objc private func windowStateDidChange(_: Notification) {
        self.sweep()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
