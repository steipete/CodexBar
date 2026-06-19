import AppKit
import CodexBarCore
import SwiftUI

enum PreferencesTab: String, CaseIterable, Hashable {
    case general
    case providers
    case display
    case advanced
    case about
    case debug

    static let defaultWidth: CGFloat = 546
    static let providersWidth: CGFloat = 792
    static let windowHeight: CGFloat = 662

    var title: String {
        switch self {
        case .general: L("tab_general")
        case .providers: L("tab_providers")
        case .display: L("tab_display")
        case .advanced: L("tab_advanced")
        case .about: L("tab_about")
        case .debug: L("tab_debug")
        }
    }

    var preferredWidth: CGFloat {
        self == .providers ? PreferencesTab.providersWidth : PreferencesTab.defaultWidth
    }

    var preferredHeight: CGFloat {
        PreferencesTab.windowHeight
    }
}

struct PreferencesTabLayoutCoordinator {
    private(set) var bindingHandledTab: PreferencesTab?

    mutating func beginBindingSelection(from current: PreferencesTab, to requested: PreferencesTab) -> Bool {
        guard current != requested else { return false }
        self.bindingHandledTab = requested
        return true
    }

    mutating func layoutForObservedSelection(
        _ observed: PreferencesTab,
        current: PreferencesTab) -> PreferencesTab?
    {
        guard observed == current else { return nil }
        defer { self.bindingHandledTab = nil }
        return self.bindingHandledTab == observed ? nil : observed
    }

    func layoutForDeferredSelection(_ requested: PreferencesTab, current: PreferencesTab) -> PreferencesTab? {
        current == requested ? requested : nil
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
    @State private var contentWidth: CGFloat = PreferencesTab.general.preferredWidth
    @State private var contentHeight: CGFloat = PreferencesTab.general.preferredHeight
    @State private var tabLayoutCoordinator = PreferencesTabLayoutCoordinator()

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
        TabView(selection: self.tabSelectionBinding) {
            GeneralPane(settings: self.settings, store: self.store)
                .tabItem { Label(L("tab_general"), systemImage: "gearshape") }
                .tag(PreferencesTab.general)

            ProvidersPane(
                settings: self.settings,
                store: self.store,
                managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
                codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
                runProviderLoginFlow: self.runProviderLoginFlow)
                .tabItem { Label(L("tab_providers"), systemImage: "square.grid.2x2") }
                .tag(PreferencesTab.providers)

            DisplayPane(settings: self.settings, store: self.store)
                .tabItem { Label(L("tab_display"), systemImage: "eye") }
                .tag(PreferencesTab.display)

            AdvancedPane(settings: self.settings)
                .tabItem { Label(L("tab_advanced"), systemImage: "slider.horizontal.3") }
                .tag(PreferencesTab.advanced)

            AboutPane(updater: self.updater)
                .tabItem { Label(L("tab_about"), systemImage: "info.circle") }
                .tag(PreferencesTab.about)

            if self.settings.debugMenuEnabled {
                DebugPane(settings: self.settings, store: self.store)
                    .tabItem { Label(L("tab_debug"), systemImage: "ladybug") }
                    .tag(PreferencesTab.debug)
            }
        }
        .id(self.settings.appLanguage)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: self.contentWidth, height: self.contentHeight)
        .background {
            SettingsWindowAppearanceBridge(colorScheme: self.colorScheme)
                .allowsHitTesting(false)
        }
        .onAppear {
            self.updateLayout(for: self.selection.tab, animate: false)
            self.ensureValidTabSelection()
        }
        .onChange(of: self.selection.tab) { _, newValue in
            guard let tab = self.tabLayoutCoordinator.layoutForObservedSelection(
                newValue,
                current: self.selection.tab)
            else { return }
            self.updateLayout(for: tab, animate: true)
        }
        .onChange(of: self.settings.debugMenuEnabled) { _, _ in
            self.ensureValidTabSelection()
        }
    }

    private var tabSelectionBinding: Binding<PreferencesTab> {
        Binding(
            get: { self.selection.tab },
            set: { newValue in
                let oldValue = self.selection.tab
                guard self.tabLayoutCoordinator.beginBindingSelection(from: oldValue, to: newValue) else { return }
                self.selection.tab = newValue
                Task { @MainActor in
                    guard let tab = self.tabLayoutCoordinator.layoutForDeferredSelection(
                        newValue,
                        current: self.selection.tab)
                    else { return }
                    self.updateLayout(for: tab, animate: true)
                }
            })
    }

    private func updateLayout(for tab: PreferencesTab, animate: Bool) {
        let change = {
            self.contentWidth = tab.preferredWidth
            self.contentHeight = tab.preferredHeight
        }
        if animate {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { change() }
        } else {
            change()
        }
        Self.resizeSettingsWindow(width: tab.preferredWidth, height: tab.preferredHeight, animate: animate)
    }

    private static let settingsWindowIdentifier = "com_apple_SwiftUI_Settings_window"
    private static let knownTabTitles = Set(PreferencesTab.allCases.map(\.title))

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first(where: {
            $0.identifier?.rawValue == self.settingsWindowIdentifier
                || self.knownTabTitles.contains($0.title)
        })
    }

    private static func resizeSettingsWindow(width: CGFloat, height: CGFloat, animate: Bool) {
        guard let window = settingsWindow() else { return }
        let toolbarHeight = window.frame.height - window.contentLayoutRect.height
        guard toolbarHeight > 0 else { return }
        let newSize = NSSize(width: width, height: height + toolbarHeight)
        var frame = window.frame
        frame.origin.y += frame.size.height - newSize.height
        frame.size = newSize
        window.setFrame(frame, display: true, animate: animate)
    }

    private func ensureValidTabSelection() {
        if !self.settings.debugMenuEnabled, self.selection.tab == .debug {
            self.selection.tab = .general
            self.updateLayout(for: .general, animate: true)
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
