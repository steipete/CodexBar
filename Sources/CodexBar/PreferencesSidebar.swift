import AppKit
import CodexBarCore
import SwiftUI

/// System Settings-style sidebar: fixed app panes on top, one row per provider below.
@MainActor
struct SettingsSidebarView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @Binding var selection: SettingsPane
    @State private var searchText = ""
    /// Keeps the selected row in the accent color instead of the unfocused grey.
    @FocusState private var isListFocused: Bool

    private static let searchBarTopPadding: CGFloat = 4
    private static let searchBarBottomPadding: CGFloat = 8

    private static var searchRowHeight: CGFloat {
        self.searchBarTopPadding + SettingsSidebarSortToggle.diameter + self.searchBarBottomPadding
    }

    var body: some View {
        ZStack(alignment: .top) {
            List(selection: self.selectionBinding) {
                self.appPanesSection
                self.providersSection
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focused(self.$isListFocused)
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: Self.searchRowHeight)
            }
            .modifier(SettingsSidebarScrollEdgeEffect())
            .padding(.horizontal, 8)

            // A background, so `ignoresSafeArea` stretches the band up through the titlebar instead of shifting it.
            Color.clear
                .frame(height: Self.searchBarTopPadding + SettingsSidebarSortToggle.diameter)
                .background {
                    SettingsSidebarScrollGlass(fadeHeight: SettingsSidebarSortToggle.diameter / 2)
                        .ignoresSafeArea(edges: .top)
                }
                .allowsHitTesting(false)

            SettingsSidebarGlassContainer {
                HStack(spacing: 6) {
                    SettingsSidebarSearchField(searchText: self.$searchText)
                    SettingsSidebarSortToggle(isOn: self.$settings.providersSortedAlphabetically)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, Self.searchBarTopPadding)
        }
        .onAppear {
            // Defer past AppKit's initial first responder, which is the search field.
            DispatchQueue.main.async {
                self.isListFocused = true
            }
        }
        .onChange(of: self.selection) { _, _ in
            self.isListFocused = true
        }
    }

    private var appPanesSection: some View {
        Section {
            SettingsSidebarPaneRow(pane: .general, systemImage: "gearshape.fill", color: .gray)
            SettingsSidebarPaneRow(pane: .iCloudSync, systemImage: "icloud.fill", color: .blue)
            SettingsSidebarPaneRow(pane: .usageSpend, systemImage: "chart.bar.fill", color: .green)
            SettingsSidebarPaneRow(pane: .notifications, systemImage: "bell.badge.fill", color: .red)
            SettingsSidebarPaneRow(pane: .menuBar, systemImage: "menubar.rectangle", color: .blue)
            SettingsSidebarPaneRow(pane: .menu, systemImage: "filemenu.and.selection", color: .teal)
            SettingsSidebarPaneRow(pane: .advanced, systemImage: "slider.horizontal.3", color: .purple)
            SettingsSidebarPaneRow(pane: .hooks, systemImage: "bolt.horizontal.circle.fill", color: .orange)
            SettingsSidebarPaneRow(pane: .plugins, systemImage: "puzzlepiece.extension.fill", color: .indigo)
            SettingsSidebarAboutRow()
            if self.settings.debugMenuEnabled {
                SettingsSidebarPaneRow(pane: .debug, systemImage: "ladybug.fill", color: .red)
            }
        }
    }

    private var providersSection: some View {
        Section {
            ForEach(self.filteredProviders, id: \.self) { provider in
                SettingsSidebarProviderRow(
                    provider: provider,
                    store: self.store,
                    isEnabled: self.enabledBinding(for: provider))
                    .tag(SettingsPane.provider(provider.instanceID))
                    .moveDisabled(!self.canReorderProviders)
            }
            .onMove { fromOffsets, toOffset in
                guard self.canReorderProviders else { return }
                self.settings.moveProvider(fromOffsets: fromOffsets, toOffset: toOffset)
            }

            if self.filteredProviders.isEmpty {
                Text(L("No matching providers"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 4) {
                Text(L("tab_providers"))
                Spacer()
                Text(String(format: L("providers_on_count"), self.enabledProviderCount))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .padding(.trailing, 10)
            }
        }
    }

    private var selectionBinding: Binding<SettingsPane?> {
        Binding(
            get: { self.selection },
            set: { newValue in
                if let newValue {
                    self.selection = newValue
                }
            })
    }

    private var orderedProviders: [UsageProvider] {
        guard self.settings.providersSortedAlphabetically else {
            return self.settings.orderedProviders().compactMap(\.firstPartyProvider)
        }
        return CodexBarConfig.alphabeticalProviderOrder(enablement: { provider in
            self.settings.isProviderEnabled(provider: provider, metadata: self.store.metadata(for: provider))
        })
    }

    private var filteredProviders: [UsageProvider] {
        ProvidersPane.filteredProviders(
            self.orderedProviders,
            query: self.searchText,
            displayName: { provider in self.store.metadata(for: provider).displayName })
    }

    private var enabledProviderCount: Int {
        self.orderedProviders.count(where: { provider in
            self.settings.isProviderEnabled(provider: provider, metadata: self.store.metadata(for: provider))
        })
    }

    private var canReorderProviders: Bool {
        !self.settings.providersSortedAlphabetically
            && self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func enabledBinding(for provider: UsageProvider) -> Binding<Bool> {
        let meta = self.store.metadata(for: provider)
        return Binding(
            get: { self.settings.isProviderEnabled(provider: provider, metadata: meta) },
            set: { newValue in
                self.settings.setProviderEnabled(provider: provider, metadata: meta, enabled: newValue)
            })
    }
}

@MainActor
private struct SettingsSidebarPaneRow: View {
    let pane: SettingsPane
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            SettingsIconChip(systemImage: self.systemImage, color: self.color)
            Text(self.pane.title)
        }
        .tag(self.pane)
    }
}

@MainActor
private struct SettingsSidebarAboutRow: View {
    var body: some View {
        HStack(spacing: 8) {
            if let icon = NSApplication.shared.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: SettingsIconChip.side, height: SettingsIconChip.side)
                    .accessibilityHidden(true)
            } else {
                SettingsIconChip(systemImage: "info.circle.fill", color: .green)
            }
            Text(SettingsPane.about.title)
        }
        .tag(SettingsPane.about)
    }
}

@MainActor
struct SettingsSidebarProviderRow: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let brand = ProviderBrandIcon.image(for: self.provider) {
                    Image(nsImage: brand)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "circle.dotted")
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(width: 16, height: 16)
            .foregroundStyle(self.isEnabled ? .primary : .secondary)
            .accessibilityHidden(true)

            Text(self.store.metadata(for: self.provider).displayName)
                .foregroundStyle(self.isEnabled ? .primary : .secondary)

            Spacer(minLength: 4)

            if self.store.refreshingProviders.contains(self.provider.instanceID) {
                ProgressView()
                    .controlSize(.mini)
            }

            if self.isEnabled, self.store.statusChecksEnabled {
                Circle()
                    .fill(Self.statusColor(for: self.store.status(for: self.provider)?.indicator))
                    .frame(width: 6, height: 6)
                    .help(Self.statusDescription(for: self.store.status(for: self.provider)?.indicator))
                    .accessibilityHidden(true)
            }
        }
        .opacity(self.isEnabled ? 1 : 0.62)
        .contextMenu {
            Button(self.isEnabled ? L("Disable") : L("Enable")) {
                self.isEnabled.toggle()
            }
        }
        .accessibilityLabel(self.accessibilityLabel)
    }

    private var accessibilityLabel: String {
        Self.accessibilityLabel(
            name: self.store.metadata(for: self.provider).displayName,
            isEnabled: self.isEnabled,
            statusChecksEnabled: self.store.statusChecksEnabled,
            indicator: self.store.status(for: self.provider)?.indicator)
    }

    nonisolated static func accessibilityLabel(
        name: String,
        isEnabled: Bool,
        statusChecksEnabled: Bool,
        indicator: ProviderStatusIndicator?) -> String
    {
        guard isEnabled else { return "\(name) — \(L("Disabled"))" }
        guard statusChecksEnabled else { return name }
        return "\(name) — \(self.statusDescription(for: indicator))"
    }

    nonisolated static func statusDescription(for indicator: ProviderStatusIndicator?) -> String {
        L("Provider service status: %@", (indicator ?? .unknown).label)
    }

    nonisolated static func statusColor(for indicator: ProviderStatusIndicator?) -> Color {
        switch indicator ?? .unknown {
        case .none: .green
        case .minor: .yellow
        case .major: .orange
        case .critical: .red
        case .maintenance, .unknown: .gray
        }
    }
}

private struct SettingsSidebarSearchField: View {
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(L("Search providers"), text: self.$searchText)
                .textFieldStyle(.plain)

            if !self.searchText.isEmpty {
                Button {
                    self.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L("Clear"))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.body)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .modifier(SettingsSidebarSearchFieldBackground())
    }
}

private struct SettingsSidebarGlassContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                self.content
            }
        } else {
            self.content
        }
    }
}

/// The system edge effect draws an opaque box over the sidebar material; `SettingsSidebarScrollGlass` replaces it.
private struct SettingsSidebarScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// Blurs rows scrolled under the search row while keeping the sidebar's color. The glass is oversized so its edge
/// highlights fall outside the mask, which fades it out over the bottom `fadeHeight` points.
private struct SettingsSidebarScrollGlass: View {
    let fadeHeight: CGFloat
    private static let edgeOverhang: CGFloat = 40

    var body: some View {
        Color.clear
            .overlay {
                self.glass
                    .padding(.horizontal, -Self.edgeOverhang)
                    .padding(.top, -Self.edgeOverhang)
            }
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: self.fadeHeight)
                }
            }
    }

    @ViewBuilder
    private var glass: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

private struct SettingsSidebarSortToggleBackground: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if self.isOn {
                // A glass tint washes out to grey in dark mode.
                content
                    .background(Circle().fill(Color.accentColor))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
            } else {
                content.glassEffect(.regular, in: Circle())
            }
        } else {
            content
                .background(Circle().fill(self.isOn ? Color.accentColor : Color.primary.opacity(0.08)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

private struct SettingsSidebarSearchFieldBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(Color(nsColor: .controlBackgroundColor).opacity(0.4)), in: .capsule)
        } else {
            content
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}

private struct SettingsSidebarSortToggle: View {
    /// Matches the search field height.
    static let diameter: CGFloat = 28

    @Binding var isOn: Bool

    var body: some View {
        Button {
            self.isOn.toggle()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(self.isOn ? Color.white : Color.secondary)
                .frame(width: Self.diameter, height: Self.diameter)
                .modifier(SettingsSidebarSortToggleBackground(isOn: self.isOn))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(self.isOn
            ? L("Sorted alphabetically (enabled first) — click to use your custom order")
            : L("Sort providers alphabetically (enabled first)"))
        .accessibilityLabel(L("Sort providers alphabetically"))
        .accessibilityAddTraits(self.isOn ? .isSelected : [])
    }
}
