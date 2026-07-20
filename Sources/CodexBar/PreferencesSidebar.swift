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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SettingsSidebarSearchField(searchText: self.$searchText)
                SettingsSidebarSortToggle(isOn: self.sortAlphabeticallyBinding)
            }
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 8)

            List(selection: self.selectionBinding) {
                self.appPanesSection
                self.providersSection
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 8)
    }

    private var appPanesSection: some View {
        Section {
            SettingsSidebarPaneRow(pane: .general, systemImage: "gearshape.fill", color: .gray)
            SettingsSidebarPaneRow(pane: .usageSpend, systemImage: "chart.bar.fill", color: .green)
            SettingsSidebarPaneRow(pane: .notifications, systemImage: "bell.badge.fill", color: .red)
            SettingsSidebarPaneRow(pane: .menuBar, systemImage: "menubar.rectangle", color: .blue)
            SettingsSidebarPaneRow(pane: .menu, systemImage: "filemenu.and.selection", color: .teal)
            SettingsSidebarPaneRow(pane: .advanced, systemImage: "slider.horizontal.3", color: .purple)
            SettingsSidebarPaneRow(pane: .hooks, systemImage: "bolt.horizontal.circle.fill", color: .orange)
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
                    .tag(SettingsPane.provider(provider))
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

    private var sortAlphabeticallyBinding: Binding<Bool> {
        Binding(
            get: { self.settings.providersSortedAlphabetically },
            set: { self.settings.providersSortedAlphabetically = $0 })
    }

    private var orderedProviders: [UsageProvider] {
        guard self.settings.providersSortedAlphabetically else {
            return self.settings.orderedProviders()
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
private struct SettingsSidebarProviderRow: View {
    let provider: UsageProvider
    @Bindable var store: UsageStore
    @Binding var isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            SettingsSidebarBrandIcon(provider: self.provider, isEnabled: self.isEnabled)

            Text(self.store.metadata(for: self.provider).displayName)
                .foregroundStyle(self.isEnabled ? .primary : .secondary)

            Spacer(minLength: 4)

            if self.store.refreshingProviders.contains(self.provider) {
                ProgressView()
                    .controlSize(.mini)
            }

            if self.isEnabled, self.store.statusChecksEnabled {
                SettingsSidebarStatusDot(indicator: self.store.statusIndicator(for: self.provider))
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
        let name = self.store.metadata(for: self.provider).displayName
        return self.isEnabled ? name : "\(name) — \(L("Disabled"))"
    }
}

@MainActor
private struct SettingsSidebarBrandIcon: View {
    let provider: UsageProvider
    let isEnabled: Bool

    var body: some View {
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
    }
}

private struct SettingsSidebarStatusDot: View {
    let indicator: ProviderStatusIndicator

    var body: some View {
        Circle()
            .fill(self.statusColor)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        switch self.indicator {
        case .none: .green
        case .minor: .yellow
        case .major: .orange
        case .critical: .red
        case .maintenance: .gray
        case .unknown: .gray
        }
    }
}

private struct SettingsSidebarSearchField: View {
    @Binding var searchText: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
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

private struct SettingsSidebarSortToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            self.isOn.toggle()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.callout)
                .foregroundStyle(self.isOn ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(self.isOn
            ? L("Sorted alphabetically (enabled first) — click to use your custom order")
            : L("Sort providers alphabetically (enabled first)"))
        .accessibilityLabel(L("Sort providers alphabetically"))
        .accessibilityAddTraits(self.isOn ? .isSelected : [])
    }
}
