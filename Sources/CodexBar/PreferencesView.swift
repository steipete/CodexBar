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

    static let windowWidth: CGFloat = 880
    static let windowHeight: CGFloat = 620
    static let windowMinWidth: CGFloat = 800
    static let windowMinHeight: CGFloat = 540
    static let sidebarWidth: CGFloat = 260
    static let detailMaxWidth: CGFloat = 780

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
                    .blur(radius: 20)
                self.sidebarWashColor

                SettingsSidebarView(settings: self.settings, store: self.store, selection: self.$selection.pane)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
            .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.22), lineWidth: 0.75))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        self.colorScheme == .dark ? Color.white.opacity(0.27) : Color.white.opacity(0.72),
                        lineWidth: 0.85))
            .frame(width: SettingsPane.sidebarWidth)
            .padding(.leading, 12)
            .padding(.top, 0)
            .padding(.bottom, 12)
            .padding(.trailing, 4)

            self.detailView
                .frame(
                    maxWidth: SettingsPane.detailMaxWidth,
                    maxHeight: .infinity,
                    alignment: .topLeading)
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

    private var sidebarWashColor: Color {
        self.colorScheme == .dark
            ? Color.black.opacity(0.60)
            : Color.white.opacity(0.60)
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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.windowDidUpdate(_:)),
                name: NSWindow.didUpdateNotification,
                object: window)
        }
        self.configureWindowStyle()
        self.refreshWindowAppearance()
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        self.configureWindowStyle()
    }

    func refreshWindowAppearance(for colorScheme: ColorScheme, windowTitle: String? = nil) {
        let colorSchemeChanged = self.colorScheme != colorScheme
        let windowTitleChanged = self.windowTitle != windowTitle
        guard colorSchemeChanged || windowTitleChanged else { return }
        self.colorScheme = colorScheme
        self.windowTitle = windowTitle

        guard let window else { return }
        self.configureWindowStyle()
        if windowTitleChanged, let windowTitle {
            window.title = windowTitle
        }
        if colorSchemeChanged {
            SettingsWindowAppearance.refresh(window, scheduleReset: self.scheduleReset)
        }
    }

    private func refreshWindowAppearance() {
        guard let window else { return }
        self.configureWindowStyle()
        if let windowTitle {
            window.title = windowTitle
        }
        SettingsWindowAppearance.refresh(window, scheduleReset: self.scheduleReset)
    }

    override func layout() {
        super.layout()
        self.configureWindowStyle()
    }

    private func configureWindowStyle() {
        guard let window else { return }
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if window.titleVisibility != .visible {
            window.titleVisibility = .visible
        }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
        if window.toolbar != nil {
            window.toolbar = nil
        }
        if window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.remove(.fullSizeContentView)
        }
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
