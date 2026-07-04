import AppKit
import CodexBarCore
import SwiftUI

/// Sidebar destinations of the settings window: fixed app panes plus one entry per provider.
enum SettingsPane: Hashable {
    case general
    case display
    case advanced
    case about
    case debug
    case provider(UsageProvider)

    static let windowWidth: CGFloat = 920
    static let windowHeight: CGFloat = 640
    static let windowMinWidth: CGFloat = 780
    static let windowMinHeight: CGFloat = 520
    static let sidebarWidth: CGFloat = 224

    var title: String {
        switch self {
        case .general: L("tab_general")
        case .display: L("tab_display")
        case .advanced: L("tab_advanced")
        case .about: L("tab_about")
        case .debug: L("tab_debug")
        case let .provider(provider):
            ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        }
    }
}

@MainActor
struct PreferencesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    let updater: UpdaterProviding
    @Bindable var selection: PreferencesSelection
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    let runProviderLoginFlow: @MainActor (UsageProvider) async -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(
        settings: SettingsStore,
        store: UsageStore,
        updater: UpdaterProviding,
        selection: PreferencesSelection,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator = ManagedCodexAccountCoordinator(),
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator? = nil,
        runProviderLoginFlow: @escaping @MainActor (UsageProvider) async -> Void = { _ in })
    {
        self.settings = settings
        self.store = store
        self.updater = updater
        self.selection = selection
        self.managedCodexAccountCoordinator = managedCodexAccountCoordinator
        self.codexAccountPromotionCoordinator = codexAccountPromotionCoordinator
            ?? CodexAccountPromotionCoordinator(
                settingsStore: settings,
                usageStore: store,
                managedAccountCoordinator: managedCodexAccountCoordinator)
        self.runProviderLoginFlow = runProviderLoginFlow
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                SettingsSidebarMaterial()
                SettingsSidebarView(settings: self.settings, store: self.store, selection: self.$selection.pane)
            }
            .frame(width: SettingsPane.sidebarWidth)
            .frame(maxHeight: .infinity)
            .clipped()

            Divider()

            self.detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(
            minWidth: SettingsPane.windowMinWidth,
            idealWidth: SettingsPane.windowWidth,
            maxWidth: .infinity,
            minHeight: SettingsPane.windowMinHeight,
            idealHeight: SettingsPane.windowHeight,
            maxHeight: .infinity)
        .id(self.settings.appLanguage)
        .background {
            SettingsWindowAppearanceBridge(colorScheme: self.colorScheme, windowTitle: self.selection.pane.title)
                .allowsHitTesting(false)
        }
        .onAppear {
            self.ensureValidSelection()
        }
        .onChange(of: self.settings.debugMenuEnabled) { _, _ in
            self.ensureValidSelection()
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch self.selection.pane {
        case .general:
            GeneralPane(settings: self.settings)
        case .display:
            DisplayPane(settings: self.settings, store: self.store)
        case .advanced:
            AdvancedPane(settings: self.settings, store: self.store)
        case .about:
            AboutPane(updater: self.updater)
        case .debug:
            DebugPane(settings: self.settings, store: self.store)
        case let .provider(provider):
            ProvidersPane(
                provider: provider,
                settings: self.settings,
                store: self.store,
                managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
                runProviderLoginFlow: self.runProviderLoginFlow)
                .id(provider)
        }
    }

    private func ensureValidSelection() {
        if !self.settings.debugMenuEnabled, self.selection.pane == .debug {
            self.selection.pane = .general
        }
    }
}

@MainActor
enum SettingsWindowSizing {
    static func enforceMinimumSize(_ window: NSWindow) {
        let toolbarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let minimumSize = NSSize(
            width: SettingsPane.windowMinWidth,
            height: SettingsPane.windowMinHeight + toolbarHeight)
        window.minSize = minimumSize

        if window.frame.width < minimumSize.width || window.frame.height < minimumSize.height {
            var frame = window.frame
            let repairedSize = NSSize(
                width: max(frame.width, minimumSize.width),
                height: max(frame.height, minimumSize.height))
            frame.origin.y += frame.height - repairedSize.height
            frame.size = repairedSize
            window.setFrame(frame, display: true)
        }
    }
}

@MainActor
enum SettingsWindowAppearance {
    typealias ResetAction = @MainActor @Sendable () -> Void
    typealias ResetScheduler = @MainActor @Sendable (@escaping ResetAction) -> Void

    static func refresh(
        _ window: NSWindow,
        application: NSApplication = NSApp,
        scheduleReset: ResetScheduler = Self.scheduleReset)
    {
        SettingsWindowSizing.enforceMinimumSize(window)
        window.appearanceSource = application
        // Pulse the exact effective appearance so the native toolbar redraws without
        // dropping inherited accessibility attributes, then restore KVO inheritance.
        window.appearance = application.effectiveAppearance
        scheduleReset { [weak window] in
            if let window {
                SettingsWindowSizing.enforceMinimumSize(window)
            }
            window?.appearance = nil
            window?.viewsNeedDisplay = true
        }
    }

    static func scheduleReset(_ action: @escaping ResetAction) {
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }
}

@MainActor
struct SettingsWindowAppearanceBridge: NSViewRepresentable {
    let colorScheme: ColorScheme
    let windowTitle: String

    func makeNSView(context: Context) -> SettingsWindowAppearanceView {
        SettingsWindowAppearanceView()
    }

    func updateNSView(_ nsView: SettingsWindowAppearanceView, context: Context) {
        nsView.refreshWindowAppearance(for: self.colorScheme, windowTitle: self.windowTitle)
    }
}

@MainActor
final class SettingsWindowAppearanceView: NSView {
    private let scheduleReset: SettingsWindowAppearance.ResetScheduler
    private var colorScheme: ColorScheme?
    private var windowTitle: String?

    init(scheduleReset: @escaping SettingsWindowAppearance.ResetScheduler = SettingsWindowAppearance.scheduleReset) {
        self.scheduleReset = scheduleReset
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        self.refreshWindowAppearance()
    }

    func refreshWindowAppearance(for colorScheme: ColorScheme, windowTitle: String? = nil) {
        guard self.colorScheme != colorScheme || self.windowTitle != windowTitle else { return }
        self.colorScheme = colorScheme
        self.windowTitle = windowTitle
        self.refreshWindowAppearance()
    }

    private func refreshWindowAppearance() {
        guard let window else { return }
        if let windowTitle {
            window.title = windowTitle
        }
        SettingsWindowAppearance.refresh(window, scheduleReset: self.scheduleReset)
    }
}

@MainActor
private struct SettingsSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        self.configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        self.configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
    }
}
