import AppKit

struct DockIconWindowDescriptor: Equatable, Sendable {
    let identifier: String?
    let title: String
    let classNames: [String]
    let width: Double
    let height: Double
    let isVisible: Bool
    let isMiniaturized: Bool
    let canBecomeKey: Bool
    let isKnownSettingsWindow: Bool

    var isSettingsWindow: Bool {
        if self.isKnownSettingsWindow {
            return true
        }
        guard let identifier else { return false }
        return identifier.contains("com_apple_SwiftUI_Settings")
    }

    var isSparkleWindow: Bool {
        !self.title.isEmpty && self.classNames.contains { className in
            className.contains("SPU") || className.contains("SUUpdate") || className.contains("Sparkle")
        }
    }

    var isRealWindow: Bool {
        guard self.isVisible, !self.isMiniaturized, self.canBecomeKey else { return false }
        guard !self.isKeepaliveWindow, !self.isStatusBarWindow else { return false }
        return true
    }

    private var isKeepaliveWindow: Bool {
        if self.identifier == "CodexBarLifecycleKeepalive" || self.title == "CodexBarLifecycleKeepalive" {
            return true
        }
        return self.width <= 20 && self.height <= 20
    }

    private var isStatusBarWindow: Bool {
        self.classNames.contains { $0.contains("NSStatusBarWindow") }
    }
}

enum DockIconPolicyDecision {
    static func shouldUseRegularActivationPolicy(windows: [DockIconWindowDescriptor]) -> Bool {
        windows.contains(where: \.isRealWindow)
    }

    static func shouldPromoteForPresentedWindow(_ window: DockIconWindowDescriptor) -> Bool {
        window.isVisible && (window.isSettingsWindow || window.isSparkleWindow)
    }

    /// Windows that became eligible for Dock promotion since the last evaluation.
    static func newlyPresentedWindowIDs(
        current: Set<ObjectIdentifier>,
        previous: Set<ObjectIdentifier>)
        -> Set<ObjectIdentifier>
    {
        current.subtracting(previous)
    }
}

@MainActor
final class DockIconController: NSObject {
    static let shared = DockIconController()

    private var isStarted = false
    private var isManagingRegularPolicy = false
    private var isAwaitingPresentedWindow = false
    private var presentedWindowIDs: Set<ObjectIdentifier> = []
    private weak var settingsWindow: NSWindow?

    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(self.windowStateDidChange(_:)),
            name: NSApplication.didUpdateNotification,
            object: nil)
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didUpdateNotification,
            NSWindow.didMiniaturizeNotification,
        ] {
            center.addObserver(
                self,
                selector: #selector(self.windowStateDidChange(_:)),
                name: name,
                object: nil)
        }
        center.addObserver(
            self,
            selector: #selector(self.windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil)
    }

    func promote() {
        self.isAwaitingPresentedWindow = true
        self.ensureRegularPolicy(activate: true)
    }

    func registerSettingsWindow(_ window: NSWindow) {
        SettingsWindowStageBehavior.applyCollectionBehavior(window)
        guard self.settingsWindow !== window else { return }
        self.settingsWindow = window
        SettingsWindowStageBehavior.present(window)
        self.reevaluatePolicy()
    }

    @objc private func windowStateDidChange(_ notification: Notification) {
        _ = notification
        self.reevaluatePolicy()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        _ = notification
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.reevaluatePolicy()
        }
    }

    private func reevaluatePolicy() {
        let describedWindows = NSApp.windows.map { window in
            (window: window, descriptor: Self.describe(window, isKnownSettingsWindow: window === self.settingsWindow))
        }
        let presentedWindowIDs = Set(describedWindows.compactMap { item in
            DockIconPolicyDecision.shouldPromoteForPresentedWindow(item.descriptor)
                ? ObjectIdentifier(item.window)
                : nil
        })
        // Capture the delta before updating stored state so we only key newly presented
        // dialogs. Fronting every eligible window can re-key Settings over a Sparkle alert.
        let newlyPresentedWindowIDs = DockIconPolicyDecision.newlyPresentedWindowIDs(
            current: presentedWindowIDs,
            previous: self.presentedWindowIDs)
        let hasNewPresentedWindow = !newlyPresentedWindowIDs.isEmpty
        self.presentedWindowIDs = presentedWindowIDs

        if !presentedWindowIDs.isEmpty {
            self.isAwaitingPresentedWindow = false
            self.ensureRegularPolicy(activate: hasNewPresentedWindow)
            if hasNewPresentedWindow {
                for item in describedWindows where newlyPresentedWindowIDs.contains(ObjectIdentifier(item.window)) {
                    if item.descriptor.isSettingsWindow {
                        SettingsWindowStageBehavior.present(item.window)
                    } else {
                        item.window.makeKeyAndOrderFront(nil)
                    }
                }
            }
        }

        guard self.isManagingRegularPolicy, !self.isAwaitingPresentedWindow else { return }
        let windows = describedWindows.map(\.descriptor)
        guard !DockIconPolicyDecision.shouldUseRegularActivationPolicy(windows: windows) else { return }

        if NSApp.setActivationPolicy(.accessory) {
            self.isManagingRegularPolicy = false
        }
    }

    private func ensureRegularPolicy(activate: Bool) {
        if NSApp.activationPolicy() != .regular, NSApp.setActivationPolicy(.regular) {
            self.isManagingRegularPolicy = true
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func describe(_ window: NSWindow, isKnownSettingsWindow: Bool) -> DockIconWindowDescriptor {
        var classNames = [NSStringFromClass(type(of: window))]
        if let windowController = window.windowController {
            classNames.append(NSStringFromClass(type(of: windowController)))
        }
        if let contentViewController = window.contentViewController {
            classNames.append(NSStringFromClass(type(of: contentViewController)))
        }
        if let delegate = window.delegate {
            classNames.append(NSStringFromClass(type(of: delegate)))
        }

        return DockIconWindowDescriptor(
            identifier: window.identifier?.rawValue,
            title: window.title,
            classNames: classNames,
            width: window.frame.width,
            height: window.frame.height,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            canBecomeKey: window.canBecomeKey,
            isKnownSettingsWindow: isKnownSettingsWindow)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
