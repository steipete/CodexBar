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
        NavigationSplitView {
            SettingsSidebarView(settings: self.settings, store: self.store, selection: self.$selection.pane)
                .navigationSplitViewColumnWidth(SettingsPane.sidebarWidth)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            self.detailView
                .navigationTitle(self.selection.pane.title)
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
            SettingsWindowAppearanceBridge(colorScheme: self.colorScheme)
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
enum SettingsWindowAppearance {
    typealias ResetAction = @MainActor @Sendable () -> Void
    typealias ResetScheduler = @MainActor @Sendable (@escaping ResetAction) -> Void

    static func refresh(
        _ window: NSWindow,
        application: NSApplication = NSApp,
        scheduleReset: ResetScheduler = Self.scheduleReset)
    {
        window.appearanceSource = application
        // Pulse the exact effective appearance so the native toolbar redraws without
        // dropping inherited accessibility attributes, then restore KVO inheritance.
        window.appearance = application.effectiveAppearance
        scheduleReset { [weak window] in
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

    func makeNSView(context: Context) -> SettingsWindowAppearanceView {
        SettingsWindowAppearanceView()
    }

    func updateNSView(_ nsView: SettingsWindowAppearanceView, context: Context) {
        nsView.refreshWindowAppearance(for: self.colorScheme)
    }
}

@MainActor
final class SettingsWindowAppearanceView: NSView {
    private let scheduleReset: SettingsWindowAppearance.ResetScheduler
    private var colorScheme: ColorScheme?

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

    func refreshWindowAppearance(for colorScheme: ColorScheme) {
        guard self.colorScheme != colorScheme else { return }
        self.colorScheme = colorScheme
        self.refreshWindowAppearance()
    }

    private func refreshWindowAppearance() {
        guard let window else { return }
        SettingsWindowAppearance.refresh(window, scheduleReset: self.scheduleReset)
    }
}
