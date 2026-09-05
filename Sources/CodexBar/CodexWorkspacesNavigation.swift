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

    func present(store: UsageStore, settings: SettingsStore) {
        self.windowControllerForPresentation(store: store, settings: settings).present()
    }

    func windowControllerForPresentation(
        store: UsageStore,
        settings: SettingsStore) -> CodexWorkspacesWindowController
    {
        let controller = self.windowController ?? CodexWorkspacesWindowController(store: store, settings: settings)
        self.windowController = controller
        return controller
    }
}

@MainActor
final class CodexWorkspacesWindowController: NSWindowController {
    private static let defaultSize = NSSize(width: 1380, height: 780)
    private static let minimumContentSize = NSSize(width: 980, height: 640)

    private let model: CodexWorkspacesInspectorModel
    private let configuration: @MainActor () -> CodexWorkspacesInspectorModel.Configuration

    init(
        store: UsageStore,
        settings: SettingsStore,
        model injectedModel: CodexWorkspacesInspectorModel? = nil)
    {
        let configuration: @MainActor () -> CodexWorkspacesInspectorModel.Configuration = {
            Self.inspectorConfiguration(store: store, settings: settings)
        }
        let model = injectedModel ?? CodexWorkspacesInspectorModel(
            configuration: configuration(),
            fetcher: store.costUsageFetcher)
        self.model = model
        self.configuration = configuration

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
            minimumSize: Self.minimumContentSize,
            model: model,
            store: store,
            settings: settings))
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
        self.model.updateConfiguration(self.configuration())
        self.model.load()
        NSApp.activate(ignoringOtherApps: true)
        self.showWindow(nil)
        self.window?.deminiaturize(nil)
        self.window?.makeKeyAndOrderFront(nil)
    }

    fileprivate static func inspectorConfiguration(
        store: UsageStore,
        settings: SettingsStore) -> CodexWorkspacesInspectorModel.Configuration
    {
        // Provider-specific by design: Workspaces inspect only the active Codex local-history scope.
        let scope = store.tokenCostScope(for: .codex)
        return CodexWorkspacesInspectorModel.Configuration(
            codexHomePath: scope.codexHomePath,
            scopeSignature: scope.signature,
            historyDays: settings.costUsageHistoryDays,
            hidePersonalInfo: settings.hidePersonalInfo)
    }
}

private struct CodexWorkspacesWindowShell: View {
    let minimumSize: NSSize
    @State private var model: CodexWorkspacesInspectorModel
    let store: UsageStore
    @Bindable var settings: SettingsStore

    init(
        minimumSize: NSSize,
        model: CodexWorkspacesInspectorModel,
        store: UsageStore,
        settings: SettingsStore)
    {
        self.minimumSize = minimumSize
        self._model = State(initialValue: model)
        self.store = store
        self.settings = settings
    }

    var body: some View {
        CodexWorkspacesInspectorView(model: self.model)
            .frame(minWidth: self.minimumSize.width, minHeight: self.minimumSize.height)
            .onChange(of: self.settings.configRevision) { _, _ in
                self.reloadForCurrentConfigurationIfVisible()
            }
    }

    private func reloadForCurrentConfigurationIfVisible() {
        self.model.updateConfiguration(CodexWorkspacesWindowController.inspectorConfiguration(
            store: self.store,
            settings: self.settings))
        let isVisible = NSApp.windows.contains {
            $0.identifier?.rawValue == CodexWorkspacesWindowIdentity.window && $0.isVisible
        }
        if isVisible {
            self.model.load()
        }
    }
}

extension StatusItemController {
    @objc
    func openCodexWorkspaces(_ sender: Any?) {
        _ = sender
        CodexWorkspacesPresenter.shared.present(store: self.store, settings: self.settings)
    }
}
