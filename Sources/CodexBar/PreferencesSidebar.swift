import AppKit
import CodexBarCore
import SwiftUI

/// System Settings-style sidebar: fixed app panes on top, one row per provider below.
@MainActor
struct SettingsSidebarView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @Binding var selection: SettingsPane
    var onSelectAbout: () -> Void = {}
    @State private var searchText = ""
    @Environment(\.undoManager) private var undoManager
    /// Keeps the selected row in the accent color instead of the unfocused grey.
    @FocusState private var isListFocused: Bool

    private static let searchBarTopPadding: CGFloat = 4
    private static let searchBarBottomPadding: CGFloat = 8

    private static var searchRowHeight: CGFloat {
        self.searchBarTopPadding + SettingsSidebarSortToggle.diameter + self.searchBarBottomPadding
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            self.glassBody
        } else {
            self.classicBody
        }
    }

    /// macOS 14/15: the search row sits above the list in standard controls.
    private var classicBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SettingsSidebarSearchField(searchText: self.$searchText)
                self.sortToggle
            }
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 8)

            self.list

            self.undoBanner
        }
        .padding(.horizontal, 8)
    }

    /// macOS 26: a Liquid Glass search row floats over the list, which scrolls under it.
    @available(macOS 26.0, *)
    private var glassBody: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                self.list
                    .focused(self.$isListFocused)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        Color.clear.frame(height: Self.searchRowHeight)
                    }
                    // The system edge effect draws an opaque box over the sidebar material;
                    // `SettingsSidebarScrollGlass` replaces it.
                    .scrollEdgeEffectHidden(true, for: .top)
                    .padding(.horizontal, 8)

                // A background, so `ignoresSafeArea` stretches the band up through the titlebar instead of shifting it.
                Color.clear
                    .frame(height: Self.searchBarTopPadding + SettingsSidebarSortToggle.diameter)
                    .background {
                        SettingsSidebarScrollGlass(fadeHeight: SettingsSidebarSortToggle.diameter / 2)
                            .ignoresSafeArea(edges: .top)
                    }
                    .allowsHitTesting(false)

                GlassEffectContainer(spacing: 0) {
                    HStack(spacing: 6) {
                        SettingsSidebarSearchField(searchText: self.$searchText)
                        self.sortToggle
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, Self.searchBarTopPadding)
            }

            self.undoBanner
                .padding(.horizontal, 8)
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

    private var list: some View {
        List(selection: self.selectionBinding) {
            self.appPanesSection
            self.providersSection
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var sortToggle: some View {
        SettingsSidebarSortToggle(
            isOn: self.$settings.providersSortedAlphabetically,
            enabledOnly: self.$settings.providersEnabledOnly,
            onRestore: self.restoreProviderOrder)
    }

    @ViewBuilder
    private var undoBanner: some View {
        if self.settings.canUndoProviderOrderChange {
            HStack {
                Text(L("Provider order updated"))
                Spacer(minLength: 4)
                Button(L("Undo")) { self.settings.undoProviderOrderChange() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            .padding(8)
            .accessibilityElement(children: .contain)
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
            SettingsSidebarAboutRow(onSelect: self.onSelectAbout)
            if self.settings.debugMenuEnabled {
                SettingsSidebarPaneRow(pane: .debug, systemImage: "ladybug.fill", color: .red)
            }
        }
    }

    private var providersSection: some View {
        let visibleProviders = self.filteredProviders
        return Section {
            ForEach(visibleProviders, id: \.self) { provider in
                self.providerRow(provider)
            }
            .onMove { fromOffsets, toOffset in
                guard self.canReorderProviders else { return }
                if self.settings.moveVisibleProviders(
                    visibleProviders.map(\.instanceID), fromOffsets: fromOffsets, toOffset: toOffset)
                {
                    self.registerOrderUndo()
                }
            }

            if visibleProviders.isEmpty {
                Text(L("No matching providers"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(L("Clear filters")) {
                    self.searchText = ""
                    self.settings.providersEnabledOnly = false
                }
                .buttonStyle(.plain)
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

    private func providerRow(_ provider: UsageProvider) -> some View {
        SettingsSidebarProviderRow(
            provider: provider,
            store: self.store,
            isEnabled: self.enabledBinding(for: provider))
            .tag(SettingsPane.provider(provider.instanceID))
            .moveDisabled(!self.canReorderProviders)
    }

    private func restoreProviderOrder() {
        if self.settings.restoreDefaultProviderOrder() { self.registerOrderUndo() }
    }

    private func registerOrderUndo() {
        self.settings.registerProviderOrderUndo(in: self.undoManager)
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
        let providers = self.orderedProviders.filter { provider in
            !self.settings.providersEnabledOnly
                || self.settings.isProviderEnabled(provider: provider, metadata: self.store.metadata(for: provider))
        }
        return ProvidersPane.filteredProviders(
            providers,
            query: self.searchText,
            displayName: { self.store.metadata(for: $0).displayName })
    }

    private var enabledProviderCount: Int {
        self.orderedProviders.count(where: { provider in
            self.settings.isProviderEnabled(provider: provider, metadata: self.store.metadata(for: provider))
        })
    }

    private var canReorderProviders: Bool {
        !self.settings.providersSortedAlphabetically && !self.settings.providersEnabledOnly
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
    let onSelect: () -> Void

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // List selection ignores clicks on the already-selected row; this also returns a pushed subpage to About.
        .simultaneousGesture(TapGesture().onEnded { self.onSelect() })
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
        if #available(macOS 26.0, *) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                self.fieldAndClear
            }
            .font(.body)
            .padding(.horizontal, 10)
            .frame(height: SettingsSidebarSortToggle.diameter)
            .glassEffect(.regular.tint(Color(nsColor: .controlBackgroundColor).opacity(0.4)), in: .capsule)
        } else {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                self.fieldAndClear
            }
            .font(.callout)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
        }
    }

    @ViewBuilder
    private var fieldAndClear: some View {
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
}

/// Blurs rows scrolled under the search row while keeping the sidebar's color. The glass is oversized so its edge
/// highlights fall outside the mask, which fades it out over the bottom `fadeHeight` points.
@available(macOS 26.0, *)
private struct SettingsSidebarScrollGlass: View {
    let fadeHeight: CGFloat
    private static let edgeOverhang: CGFloat = 40

    var body: some View {
        Color.clear
            .overlay {
                Color.clear.glassEffect(.regular, in: Rectangle())
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
}

/// On macOS 26, a glass capsule whose sort circle fills with the accent color when on, next to the sorting menu.
private struct SettingsSidebarSortToggle: View {
    /// Matches the glass search field height.
    static let diameter: CGFloat = 28

    @Binding var isOn: Bool
    @Binding var enabledOnly: Bool
    let onRestore: () -> Void

    var body: some View {
        if #available(macOS 26.0, *) {
            HStack(spacing: 0) {
                Button {
                    self.isOn.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(self.isOn ? Color.white : Color.secondary)
                        .frame(width: Self.diameter, height: Self.diameter)
                        .background {
                            // A glass tint washes out to grey in dark mode.
                            if self.isOn {
                                Circle().fill(Color.accentColor)
                            }
                        }
                        .contentShape(Circle())
                }
                .modifier(SortButtonTraits(isOn: self.isOn))

                self.menu(
                    chevron: Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)),
                    size: CGSize(width: 18, height: Self.diameter))
            }
            .padding(.trailing, 3)
            .glassEffect(.regular, in: .capsule)
        } else {
            HStack(spacing: 0) {
                Button {
                    self.isOn.toggle()
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.callout)
                        .foregroundStyle(self.isOn ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .modifier(SortButtonTraits(isOn: self.isOn))

                self.menu(
                    chevron: Image(systemName: "chevron.down").font(.caption2),
                    size: CGSize(width: 14, height: 24))
            }
        }
    }

    private func menu(chevron: some View, size: CGSize) -> some View {
        Menu {
            Toggle(L("Only enabled providers"), isOn: self.$enabledOnly)
            Divider()
            Button(L("Restore default order"), action: self.onRestore)
                .help(L("Also restores the provider order in the menu bar. Can be undone."))
        } label: {
            chevron
                .foregroundStyle(self.enabledOnly ? Color.accentColor : Color.secondary)
                .frame(width: size.width, height: size.height)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Provider sorting"))
        .accessibilityLabel(L("Provider sorting"))
    }
}

private struct SortButtonTraits: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content
            .buttonStyle(.plain)
            .help(self.isOn
                ? L("Sorted alphabetically (enabled first) — click to use your custom order")
                : L("Sort providers alphabetically (enabled first)"))
            .accessibilityLabel(L("Sort providers alphabetically"))
            .accessibilityAddTraits(self.isOn ? .isSelected : [])
    }
}
