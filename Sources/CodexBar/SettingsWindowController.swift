import AppKit
import CodexBarCore
import SwiftUI

enum SettingsWindowIdentity {
    static let identifier = "com.steipete.codexbar.settings"
    static let frameAutosaveName = "CodexBar.SettingsWindow"
}

@MainActor
final class SettingsWindowController: NSWindowController {
    enum Outcome: Equatable {
        case created
        case reused
        case failed
    }

    typealias WindowFactory = @MainActor () -> NSWindow?
    typealias WindowAction = @MainActor (NSWindow) -> Void

    private let selection: PreferencesSelection
    private let makeWindow: WindowFactory
    private let prepareToPresent: @MainActor () -> Void
    private let registerWindow: WindowAction
    private let presentWindow: WindowAction
    private let didPresentWindow: WindowAction
    private let presentationFailed: @MainActor () -> Void
    private let logger = CodexBarLog.logger(LogCategories.app)
    private var retainedWindow: NSWindow?

    init(
        selection: PreferencesSelection,
        makeWindow: @escaping WindowFactory,
        prepareToPresent: @escaping @MainActor () -> Void = {
            DockIconController.shared.prepareToOpenSettings()
        },
        registerWindow: @escaping WindowAction = { window in
            DockIconController.shared.registerSettingsWindow(window)
        },
        presentWindow: @escaping WindowAction = { window in
            SettingsWindowStageBehavior.present(window)
        },
        didPresentWindow: @escaping WindowAction = { window in
            DockIconController.shared.settingsWindowDidPresent(window)
        },
        presentationFailed: @escaping @MainActor () -> Void = {
            DockIconController.shared.settingsWindowPresentationFailed()
        })
    {
        self.selection = selection
        self.makeWindow = makeWindow
        self.prepareToPresent = prepareToPresent
        self.registerWindow = registerWindow
        self.presentWindow = presentWindow
        self.didPresentWindow = didPresentWindow
        self.presentationFailed = presentationFailed
        super.init(window: nil)
    }

    convenience init(
        settings: SettingsStore,
        store: UsageStore,
        cloudSyncState: CloudSyncState,
        updater: UpdaterProviding,
        selection: PreferencesSelection,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator,
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator,
        runProviderLoginFlow: @escaping @MainActor (UsageProvider) async -> Void)
    {
        self.init(selection: selection) {
            let rootView = PreferencesView(
                settings: settings,
                store: store,
                cloudSyncState: cloudSyncState,
                updater: updater,
                selection: selection,
                managedCodexAccountCoordinator: managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator: codexAccountPromotionCoordinator,
                runProviderLoginFlow: runProviderLoginFlow)
            let hostingController = NSHostingController(rootView: rootView)
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: SettingsPane.windowWidth,
                    height: SettingsPane.windowHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            window.contentViewController = hostingController
            window.title = selection.pane.title
            window.titlebarAppearsTransparent = true
            window.titleVisibility = SettingsWindowAppearance.titleVisibility
            window.titlebarSeparatorStyle = .none
            window.isReleasedWhenClosed = false
            SettingsWindowSizing.enforceMinimumSize(window)
            if !window.setFrameUsingName(SettingsWindowIdentity.frameAutosaveName) {
                window.center()
            }
            window.setFrameAutosaveName(SettingsWindowIdentity.frameAutosaveName)
            return window
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func open(pane: SettingsPane?) -> Outcome {
        if let pane {
            self.selection.pane = pane
        }

        self.prepareToPresent()
        let outcome: Outcome
        let window: NSWindow
        if let retainedWindow {
            window = retainedWindow
            outcome = .reused
        } else if let createdWindow = self.makeWindow() {
            createdWindow.identifier = NSUserInterfaceItemIdentifier(SettingsWindowIdentity.identifier)
            SettingsWindowStageBehavior.applyCollectionBehavior(createdWindow)
            self.retainedWindow = createdWindow
            self.window = createdWindow
            window = createdWindow
            outcome = .created
        } else {
            self.presentationFailed()
            self.logger.error("Failed to create Settings window")
            return .failed
        }

        self.registerWindow(window)
        self.presentWindow(window)
        self.didPresentWindow(window)
        self.logger.info(
            "Settings window presented",
            metadata: [
                "outcome": outcome == .created ? "created" : "reused",
                "pane": self.selection.pane.persistenceToken,
            ])
        return outcome
    }
}
