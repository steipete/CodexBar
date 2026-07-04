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
    static let sidebarMinWidth: CGFloat = 224

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
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

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
        NavigationSplitView(columnVisibility: self.columnVisibilityBinding) {
            SettingsSidebarView(settings: self.settings, store: self.store, selection: self.$selection.pane)
                .frame(
                    minWidth: SettingsPane.sidebarMinWidth,
                    idealWidth: SettingsPane.sidebarWidth,
                    maxWidth: SettingsPane.sidebarWidth)
                .navigationSplitViewColumnWidth(
                    min: SettingsPane.sidebarMinWidth,
                    ideal: SettingsPane.sidebarWidth,
                    max: SettingsPane.sidebarWidth)
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
            self.columnVisibility = .doubleColumn
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

    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { self.columnVisibility },
            set: { self.columnVisibility = Self.visibleColumnVisibility(for: $0) })
    }

    static func visibleColumnVisibility(for _: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        .doubleColumn
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

        self.enforceSidebarWidth(in: window)
    }

    private static func enforceSidebarWidth(in window: NSWindow) {
        // SwiftUI's split-view identifier is private and has changed across macOS releases.
        // The Settings navigation split is the widest vertical two-pane split in this window.
        guard let splitView = window.contentView?.descendantSplitViews
            .filter({ $0.isVertical && $0.subviews.count == 2 })
            .max(by: { $0.bounds.width < $1.bounds.width })
        else {
            return
        }

        let sidebar = splitView.subviews[0]
        guard sidebar.frame.width < SettingsPane.sidebarWidth else { return }
        splitView.setPosition(SettingsPane.sidebarWidth, ofDividerAt: 0)
        splitView.adjustSubviews()
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

extension NSView {
    fileprivate var descendantSplitViews: [NSSplitView] {
        let current = (self as? NSSplitView).map { [$0] } ?? []
        return current + self.subviews.flatMap(\.descendantSplitViews)
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
