import AppKit
import CodexBarCore

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
        return identifier == SettingsWindowIdentity.identifier
            || identifier.contains("com_apple_SwiftUI_Settings")
    }

    var isSparkleWindow: Bool {
        !self.title.isEmpty && self.classNames.contains { className in
            className.contains("SPU") || className.contains("SUUpdate") || className.contains("Sparkle")
        }
    }

    var isRealWindow: Bool {
        guard self.isVisible, !self.isMiniaturized, self.canBecomeKey else { return false }
        guard !self.isTinyWindow, !self.isStatusBarWindow else { return false }
        return true
    }

    var isTinyWindow: Bool {
        self.width <= 20 && self.height <= 20
    }

    var isStatusBarWindow: Bool {
        self.classNames.contains { $0.contains("NSStatusBarWindow") }
    }

    @MainActor
    static func describe(_ window: NSWindow, isKnownSettingsWindow: Bool) -> Self {
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

        return Self(
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
}

enum DockIconPolicyDecision {
    static func shouldUseRegularActivationPolicy(windows: [DockIconWindowDescriptor]) -> Bool {
        windows.contains { window in
            window.isRealWindow || (window.isSettingsWindow && window.isMiniaturized)
        }
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

enum DockIconPresentationAttemptDecision: Equatable {
    case inactive
    case awaiting
    case presented
    case timedOut

    static func resolve(
        isAwaiting: Bool,
        hasPresentedWindow: Bool,
        deadlineExpired: Bool)
        -> Self
    {
        guard isAwaiting else { return .inactive }
        if hasPresentedWindow {
            return .presented
        }
        return deadlineExpired ? .timedOut : .awaiting
    }
}

struct DockIconPresentationAttemptID: Equatable, Sendable {
    fileprivate let rawValue: UInt64
}

struct DockIconPresentationAttemptTracker: Equatable {
    private(set) var activeID: DockIconPresentationAttemptID?
    private var nextRawID: UInt64 = 0

    var isAwaiting: Bool {
        self.activeID != nil
    }

    mutating func begin() -> DockIconPresentationAttemptID {
        self.nextRawID &+= 1
        let id = DockIconPresentationAttemptID(rawValue: self.nextRawID)
        self.activeID = id
        return id
    }

    mutating func finish(_ id: DockIconPresentationAttemptID) -> Bool {
        guard self.activeID == id else { return false }
        self.activeID = nil
        return true
    }

    mutating func resolve(
        hasPresentedWindow: Bool,
        deadlineExpiredFor deadlineID: DockIconPresentationAttemptID?)
        -> DockIconPresentationAttemptDecision
    {
        guard let activeID else { return .inactive }
        if let deadlineID, deadlineID != activeID {
            return .awaiting
        }

        let decision = DockIconPresentationAttemptDecision.resolve(
            isAwaiting: true,
            hasPresentedWindow: hasPresentedWindow,
            deadlineExpired: deadlineID != nil)
        if decision == .presented || decision == .timedOut {
            self.activeID = nil
        }
        return decision
    }
}

@MainActor
final class DockIconController: NSObject {
    static let shared = DockIconController()
    private static let settingsPresentationTimeout: Duration = .seconds(2)

    private var isStarted = false
    private var isManagingRegularPolicy = false
    private var presentationAttemptTracker = DockIconPresentationAttemptTracker()
    private var settingsPresentationAttemptID: DockIconPresentationAttemptID?
    private var presentedWindowIDs: Set<ObjectIdentifier> = []
    private weak var settingsWindow: NSWindow?
    private var presentationTimeoutTask: Task<Void, Never>?
    private let logger = CodexBarLog.logger(LogCategories.app)

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

    @discardableResult
    func promote(presentationTimeout: Duration) -> DockIconPresentationAttemptID {
        self.presentationTimeoutTask?.cancel()
        let attemptID = self.presentationAttemptTracker.begin()
        self.ensureRegularPolicy(activate: true)
        self.presentationTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: presentationTimeout)
            } catch {
                return
            }
            self?.reevaluatePolicy(presentationDeadlineExpiredFor: attemptID)
        }
        return attemptID
    }

    func prepareToOpenSettings() {
        self.settingsPresentationAttemptID = self.promote(
            presentationTimeout: Self.settingsPresentationTimeout)
    }

    func registerSettingsWindow(_ window: NSWindow) {
        SettingsWindowStageBehavior.applyCollectionBehavior(window)
        self.settingsWindow = window
    }

    func settingsWindowDidPresent(_ window: NSWindow) {
        guard self.settingsWindow === window else { return }
        self.reevaluatePolicy()
        self.settingsPresentationAttemptID = nil
    }

    func settingsWindowPresentationFailed() {
        guard let settingsPresentationAttemptID else { return }
        self.settingsPresentationAttemptID = nil
        self.finishPresentationAttempt(settingsPresentationAttemptID)
    }

    func finishPresentationAttempt(_ attemptID: DockIconPresentationAttemptID) {
        guard self.presentationAttemptTracker.finish(attemptID) else { return }
        self.presentationTimeoutTask?.cancel()
        self.presentationTimeoutTask = nil
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

    private func reevaluatePolicy(
        presentationDeadlineExpiredFor attemptID: DockIconPresentationAttemptID? = nil)
    {
        let describedWindows = NSApp.windows.map { window in
            (
                window: window,
                descriptor: DockIconWindowDescriptor.describe(
                    window,
                    isKnownSettingsWindow: window === self.settingsWindow))
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

        let presentationDecision = self.presentationAttemptTracker.resolve(
            hasPresentedWindow: !presentedWindowIDs.isEmpty,
            deadlineExpiredFor: attemptID)
        switch presentationDecision {
        case .presented:
            self.presentationTimeoutTask?.cancel()
            self.presentationTimeoutTask = nil
        case .timedOut:
            self.presentationTimeoutTask = nil
            self.logger.error("Timed out waiting for a presented window; restoring accessory activation policy")
        case .inactive, .awaiting:
            break
        }

        if !presentedWindowIDs.isEmpty {
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

        guard self.isManagingRegularPolicy, !self.presentationAttemptTracker.isAwaiting else { return }
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

    deinit {
        self.presentationTimeoutTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
