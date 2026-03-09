import AppKit
import SwiftUI

enum PreferencesTab: String, Hashable {
    case general
    case providers
    case display
    case advanced
    case about
    case debug

    static let defaultWidth: CGFloat = 496
    static let providersWidth: CGFloat = 720
    static let windowHeight: CGFloat = 580

    var preferredWidth: CGFloat {
        self == .providers ? PreferencesTab.providersWidth : PreferencesTab.defaultWidth
    }

    var preferredHeight: CGFloat {
        PreferencesTab.windowHeight
    }
}

@MainActor
struct PreferencesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    let updater: UpdaterProviding
    @Bindable var selection: PreferencesSelection
    @State private var contentWidth: CGFloat = PreferencesTab.general.preferredWidth
    @State private var contentHeight: CGFloat = PreferencesTab.general.preferredHeight

    var body: some View {
        TabView(selection: self.$selection.tab) {
            GeneralPane(settings: self.settings, store: self.store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(PreferencesTab.general)

            ProvidersPane(settings: self.settings, store: self.store)
                .tabItem { Label("Providers", systemImage: "square.grid.2x2") }
                .tag(PreferencesTab.providers)

            DisplayPane(settings: self.settings, store: self.store)
                .tabItem { Label("Display", systemImage: "eye") }
                .tag(PreferencesTab.display)

            AdvancedPane(settings: self.settings)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(PreferencesTab.advanced)

            AboutPane(updater: self.updater)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(PreferencesTab.about)

            if self.settings.debugMenuEnabled {
                DebugPane(settings: self.settings, store: self.store)
                    .tabItem { Label("Debug", systemImage: "ladybug") }
                    .tag(PreferencesTab.debug)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(width: self.contentWidth, height: self.contentHeight)
        .onAppear {
            self.updateLayout(for: self.selection.tab, animate: false)
            self.ensureValidTabSelection()
        }
        .onChange(of: self.selection.tab) { _, newValue in
            self.updateLayout(for: newValue, animate: true)
        }
        .onChange(of: self.settings.debugMenuEnabled) { _, _ in
            self.ensureValidTabSelection()
        }
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
    }

    private func ensureValidTabSelection() {
        if !self.settings.debugMenuEnabled, self.selection.tab == .debug {
            self.selection.tab = .general
            self.updateLayout(for: .general, animate: true)
        }
    }
}
