import AppKit
import CodexBarCore
import SwiftUI

enum OpenAILiveUsageWindowIdentity {
    static let menuItem = "openAILiveUsage"
    static let window = "com.steipete.codexbar.openai-live-usage"
}

@MainActor
final class OpenAILiveUsagePresenter {
    static let shared = OpenAILiveUsagePresenter()
    private var windowController: OpenAILiveUsageWindowController?

    func present(settings: SettingsStore, openSettings: @escaping @MainActor () -> Void) {
        let controller = self.windowController ?? OpenAILiveUsageWindowController(
            settings: settings, openSettings: openSettings)
        self.windowController = controller
        controller.present()
    }
}

@MainActor
final class OpenAILiveUsageWindowController: NSWindowController, NSWindowDelegate {
    private let model: OpenAILiveUsageModel

    init(settings: SettingsStore, openSettings: @escaping @MainActor () -> Void) {
        let model = OpenAILiveUsageModel(environment: {
            ProviderRegistry.makeEnvironment(
                base: ProcessInfo.processInfo.environment,
                provider: .openai,
                settings: settings,
                tokenOverride: nil)
        }, limitScope: {
            settings.modelRateLimitScope(for: .openai)
        }, manualLimits: { scope in
            settings.providerConfig(for: .openai)?.modelRateLimits(for: scope) ?? []
        })
        self.model = model
        let size = NSSize(width: 880, height: 640)
        let minimumSize = NSSize(width: 680, height: 500)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.identifier = NSUserInterfaceItemIdentifier(OpenAILiveUsageWindowIdentity.window)
        window.title = L("OpenAI Live Usage")
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let hosting = NSHostingController(rootView: OpenAILiveUsageView(
            model: model, openSettings: openSettings).codexBarLocalized())
        hosting.sizingOptions = .minSize
        window.contentViewController = hosting
        window.contentMinSize = minimumSize
        window.setContentSize(size)
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        self.model.start()
        NSApp.activate()
        self.showWindow(nil)
        self.window?.deminiaturize(nil)
        self.window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_: Notification) {
        self.model.stop()
    }
}

extension StatusItemController {
    @objc
    func openOpenAILiveUsage(_: Any?) {
        OpenAILiveUsagePresenter.shared.present(settings: self.settings) { [weak self] in
            self?.settingsOpenHandler?(.provider(UsageProvider.openai.instanceID))
        }
    }
}
