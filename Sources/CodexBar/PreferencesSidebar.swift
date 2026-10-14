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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SettingsSidebarSearchField(searchText: self.$searchText)
                SettingsSidebarSortToggle(
                    isOn: self.$settings.providersSortedAlphabetically,
                    enabledOnly: self.$settings.providersEnabledOnly,
                    onRestore: self.restoreProviderOrder)
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
        .padding(.horizontal, 8)
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
    @Binding var enabledOnly: Bool
    let onRestore: () -> Void

    var body: some View {
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
            .buttonStyle(.plain)
            .help(self.isOn
                ? L("Sorted alphabetically (enabled first) — click to use your custom order")
                : L("Sort providers alphabetically (enabled first)"))
            .accessibilityLabel(L("Sort providers alphabetically"))
            .accessibilityAddTraits(self.isOn ? .isSelected : [])

            Menu {
                Toggle(L("Only enabled providers"), isOn: self.$enabledOnly)
                Divider()
                Button(L("Restore default order"), action: self.onRestore)
                    .help(L("Also restores the provider order in the menu bar. Can be undone."))
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(self.enabledOnly ? Color.accentColor : Color.secondary)
                    .frame(width: 14, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Provider sorting"))
            .accessibilityLabel(L("Provider sorting"))
        }
    }
}
